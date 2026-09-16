# Q. Observability: Logs, Metrics, Health Checks, Alerts

You cannot prove a financial number is right, or notice a tenant crossing another tenant's data, if
you cannot see the system. Observability here is built around four questions: **Is it up? Is it
correct? Is it secure? Is it fast?**

---

## 1. Pillars and tooling

| Pillar | Tooling | Why |
|---|---|---|
| Structured logs | Django structured JSON logging → Promtail → **Loki** (retention 30 days hot) | Correlate by `request_id`/`company_id` without a heavyweight stack |
| Metrics | `django-prometheus`, postgres_exporter, redis_exporter, node_exporter, caddy/nginx exporter → **Prometheus** → **Grafana** | Standard, well-understood, cheap to run on one VPS |
| Traces | OpenTelemetry instrumentation with **sampling** inside the app (export to Tempo optional, off by default on a 1-VPS setup) | Trace the expensive paths (contract financials, IPC certification, imports) without paying full-trace cost |
| Alerts | **Alertmanager** → email + Telegram/Slack webhook; PagerDuty-class escalation is an owner decision (D-09) | Must reach a human quickly with actionable context |
| Errors | Sentry (self-hosted-compatible or SaaS), PII scrubbing on | Grouped exception visibility with release tracking |
| Audit | In-database audit trail ([L](L-audit-logging.md)) | Evidence, not monitoring — deliberately separate |

Logs are **not** the audit trail. Logs are operational, rotated and prunable; audit rows are
permanent, tamper-evident evidence.

---

## 2. Health and readiness

| Endpoint | Purpose | Checks | Exposure |
|---|---|---|---|
| `GET /healthz` | Liveness (container restart decision) | Process alive; no dependencies | Public, no data |
| `GET /readyz` | Readiness (load balancer routing) | DB `SELECT 1`, Redis `PING`, migrations applied up to the expected version, object storage reachable, required secrets loaded | Public, minimal detail (no versions/DSNs) |
| `GET /api/v1/system/status` | Operator detail (behind auth + `platform` role) | Build version, migration head, queue depths, last backup time, last MV refresh | Authenticated |

Rules: readiness **fails** when migrations are behind or Redis is unavailable (better to serve an
honest 503 than to accept writes that cannot be queued safely); health checks never touch tenant data;
Docker `HEALTHCHECK` uses `healthz`, Compose `depends_on: condition: service_healthy` sequences the
stack.

---

## 3. Metrics we actually act on

**Application**
- Request rate, error rate (4xx/5xx) and latency p50/p95/p99 **per route** (not just globally)
- Slow queries by route (`django.db.query_duration`), queries per request
- Business counters: IPC certified, VO approved, expense posted, collection posted, import
  committed/rolled back, PDF generated, report exported — per company
- Authorization denials (403) and cross-tenant attempts (404 on foreign ids) — a rising trend is a
  security signal
- Session/login: successes, failures, lockouts, step-up challenges

**Database**
- Connections vs `max_connections`, idle-in-transaction count (a hidden killer in this design),
  lock waits/deadlocks, replication/WAL archive lag, backup recency, table bloat, cache hit ratio,
  per-table size growth (audit partitions)

**Infrastructure**
- CPU, memory, disk usage **and disk growth rate** (WAL + audit + objects), IO wait, network, container
  restarts, container health, TLS certificate days-to-expiry

**Jobs**
- Queue depth and age per queue, task duration, failures/retries, dead-letter count, outbox lag
  (commit → publish), scheduled-job last-success timestamps ([N §6](N-background-jobs.md))

**Business integrity (the interesting ones)**
- Contract cache vs ledger drift (must stay 0)
- IPCs whose `Σ lines ≠ header` after certification (must stay 0)
- Collections over-allocated (must stay 0)
- Audit chain verification failures (must stay 0)
- Unlinked-cost ratio per project (informational, nudges data hygiene)

---

## 4. Logging standards

| Field | Source | Purpose |
|---|---|---|
| `ts`, `level`, `logger`, `msg` | framework | standard |
| `request_id` | generated per request, returned in `X-Request-Id` | end-to-end correlation with the audit row |
| `company_id`, `user_id`, `membership_id` | request context | tenant-scoped debugging without cross-tenant leakage |
| `route`, `method`, `status`, `duration_ms` | middleware | per-route performance and errors |
| `job_id`, `queue`, `attempt` | worker | job tracing |
| `error.type`, `error.stack_hash` | exception handler | grouping without dumping payloads |

Rules: **never** log passwords, tokens, cookies, MFA secrets, full bank details, or document contents
(a filter enforces the pattern list); log the *identifier* of sensitive objects, never the values;
logs are tenant-tagged so a support session can be scoped to one company; log retention 30 days hot,
90 days cold, and logs are excluded from the DR critical path.

---

## 5. Alerting (severity, condition, first action)

| Severity | Alert | Condition (example) | First action |
|---|---|---|---|
| **P1** | Service down | `/readyz` failing for 2 min, or 5xx > 5% for 5 min | Check containers, then DB/Redis, then roll back the last deploy |
| **P1** | **No successful backup in 24 h** or WAL archive lag > 30 min | backup metric | Investigate backup container/storage immediately; do not deploy |
| **P1** | Audit chain verification failure | nightly job result | Treat as a security incident: preserve logs, export checkpoints, engage owner |
| **P1** | Restore drill failed | weekly/monthly job | Fix before any further change; document |
| **P2** | Dead-letter jobs > 0 for a financial job | queue metric | Inspect payload, replay or escalate; verify no partial write |
| **P2** | Outbox lag > 15 min | outbox metric | Worker/scheduler health |
| **P2** | Disk > 80% (or projected full < 7 days) | node metric | Prune WAL/objects, extend volume |
| **P2** | Deadlocks or lock waits sustained | pg metric | Identify the transaction pair; check for a missing lock order |
| **P2** | Login failures spike / lockouts spike | auth metric | Possible credential stuffing; tighten limits, notify affected |
| **P2** | TLS certificate < 14 days | cert metric | Renew/repair ACME |
| **P3** | p95 latency regression > 2× baseline | route metric | Profile the route |
| **P3** | Materialized view stale > 26 h | refresh metric | Check scheduler |
| **P3** | Cross-tenant 404s from one membership in volume | authz metric | Possible IDOR probing; review the actor's activity |
| **P3** | Storage growth anomaly | storage metric | Check for a runaway import/export loop |

Every alert names its **runbook link**; an alert nobody knows how to act on is a to-do, not an alert.
Alert rules are committed as code (`alertmanager.yml`, Grafana dashboards as JSON) and reviewed like
code.

---

## 6. Dashboards (Grafana, provisioned as code)

1. **Service overview** — availability, error rate, latency, saturation, deploy markers.
2. **Financial integrity** — the invariant counters of §3 (drift, imbalance, over-allocation, chain
   errors, backup recency); this is the dashboard that makes "is the data right?" a glance.
3. **Tenant operations** — per-company request volume, storage, jobs, users active; used to spot noisy
   neighbours and to size capacity.
4. **Database** — connections, locks, WAL, bloat, top queries, table sizes (audit growth trend).
5. **Jobs & queues** — depths, rates, failures, outbox lag, scheduler heartbeats.
6. **Security** — auth outcomes, lockouts, step-up challenges, authorization denials, break-glass
   elevations, downloads of sensitive documents.
7. **Backups & DR** — last success per layer, restore-drill history, verification results.

Dashboards use **only aggregate or metadata**; no tenant financial values appear in monitoring
(prevents the monitoring stack from becoming a data-leak channel).

---

## 7. Tracing and profiling (deliberate scope)

* Sample 10% of requests, 100% of imports/exports/certifications (bounded by size).
* Trace spans: HTTP → service → repository → DB, plus job spans with queue wait.
* Use tracing for latency work, not as an audit mechanism.
* `EXPLAIN (ANALYZE, BUFFERS)` is captured for queries slower than a threshold and attached to the log
  line for that query; a weekly review promotes frequent slow queries into index/query work.
* Frontend: browser RUM (errors + Web Vitals) with tenant tagging; consent-respecting.

---

## 8. Operational review rhythm

| Cadence | Activity |
|---|---|
| Daily | Alert triage; backup success verification; error budget glance |
| Weekly | Slow queries, authorization denials, storage growth, dead letters, restore drill result |
| Monthly | Access review (roles, memberships, break-glass elevations), dependency and image vulnerability scan, restore drill report, capacity forecast |
| Quarterly | Threat-model review ([R](R-security-threat-model.md)), permission matrix review, permission-of-least-privilege audit, DR exercise with the owner |

The monthly/quarterly items are the ones that keep the design honest after launch; they are written
here as recurring obligations, not aspirations.
