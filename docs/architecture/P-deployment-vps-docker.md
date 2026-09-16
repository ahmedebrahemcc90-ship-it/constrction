# P. VPS / Docker / Reverse Proxy / HTTPS Architecture

One Linux VPS, Docker Compose, nginx terminating TLS, everything stateful private. The design below
is intentionally conservative: nothing exotic to operate at 03:00.

---

## 1. Host baseline

| Item | Decision |
|---|---|
| OS | Debian 12 / Ubuntu 24.04 LTS, unattended security upgrades, minimal packages |
| Provider | A reputable VPS provider with snapshots and a region close to Saudi Arabia (Bahrain/Dubai/Europe) for latency; data-residency preference is an owner decision (D-04) |
| Sizing (initial) | 8 vCPU / 16 GB RAM / 320 GB NVMe (or 4/8/160 as a start for a handful of tenants); separate volume or directory for Postgres WAL and object storage |
| Access | SSH keys only, no password login, non-root deploy user, `sudo` with MFA where available, optional bastion allow-list, fail2ban, UFW as a *secondary* control (see §5) |
| Time | NTP (`systemd-timesyncd`); all containers use UTC, UI/PDFs render `Asia/Riyadh` |
| Host hardening | Automatic security updates, auditd, journald limits, no compilers in the runtime containers, Docker rootless not required but `userns-remap`/restricted profiles evaluated |
| Snapshots | Provider-level disk snapshots daily as a coarse fallback (never the primary backup strategy) |

---

## 2. Container topology (Docker Compose)

| Service | Image | Networks | Published | Key notes |
|---|---|---|---|---|
| `proxy` | nginx (pinned digest) | edge, app, obs | 80, 443 | TLS termination, security headers, rate limits, static SPA bundle, ACME webroot |
| `web` | app image (Django + DRF) | app, data, egress | — | Gunicorn/uvicorn workers; `/healthz` (liveness) and `/readyz` (readiness: DB + Redis + migrations) |
| `worker` | app image (Celery) | app, data | — | Queues per [N §4](N-background-jobs.md); concurrency tuned to CPU |
| `scheduler` | app image (beat) | app, data | — | Single instance; DB-backed schedules |
| `pdf` | WeasyPrint image | app | — | Renders PDFs; no DB credentials, no outbound network, `read_only` root and `tmpfs` for `/tmp` |
| `db` | postgres:16 (pinned digest) | data | **none** | Volume-mounted data, `pgBackRest` sidecar or host agent for WAL archiving |
| `redis` | redis:7.2 (pinned) | data | none | `appendonly yes`, maxmemory policy `noeviction` for correctness of rate limits/orphan risk documented |
| `object` | minio (pinned) | data | none | Private buckets, versioning, lifecycle rules |
| `backup` | pgBackRest + restic image | data | — | Reads DB/WAL and object data; writes to local repo + off-site |
| `prometheus`, `grafana`, `loki`, `promtail`, `alertmanager`, exporters | standard images | obs, data (exporters only) | Grafana via proxy only, allow-listed | See [Q](Q-observability.md) |

Design rules: images pinned by digest; every service defines `restart: unless-stopped` and a
`healthcheck`; containers run as non-root with a read-only root filesystem where possible; no
container mounts the Docker socket; no service other than `proxy` publishes a port.

---

## 3. Reverse proxy responsibilities

| Concern | Configuration |
|---|---|
| TLS | TLS 1.2+ (1.3 preferred), modern cipher suites, OCSP stapling, HSTS with `includeSubDomains` and a long max-age after the domain is stable |
| Certificates | Let's Encrypt via Certbot (webroot or DNS-01), auto-renew, renewal monitored with an alert at 21 days remaining |
| Redirects | 80 → 443 permanent; a canonical host redirect (apex ↔ www) to prevent cookie/CSRF confusion across origins |
| Headers | `Content-Security-Policy` (self-only, no inline scripts), `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` minimal, `X-Frame-Options: DENY`/`frame-ancestors 'none'` |
| Rate limiting | Global per-IP (generous), strict on `/auth/*`, `/api/*/imports`, `/api/*/exports`, downloads; `limit_req` + `limit_conn` |
| Body/size limits | `client_max_body_size` above the app's own limits but bounded; request timeouts aligned with the worker design (long uploads go direct to object storage) |
| Proxying | `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Real-IP` set only by the proxy; the app trusts them only from the proxy address |
| Uploads path | `/api/…` only; large files bypass the proxy via presigned storage URLs |
| Static | SPA bundle served by nginx with long-lived hashed-asset caching and `index.html` no-store |
| Access control | Grafana/metrics paths restricted by IP allow-list or mTLS; no path exposes `/metrics` publicly |
| Logs | Access logs with a request-id correlation header, PII-scrubbed, rotated and shipped to Loki |

---

## 4. Environment and release process

| Step | Detail |
|---|---|
| Build | CI builds one immutable image per commit, tags it, scans it (Trivy), signs it (cosign optional), pushes to GHCR |
| Deploy | SSH-based deploy of pinned digests via Compose; `docker compose pull && up -d` with a pre-deploy DB backup, migration step, then web/worker rolling restart |
| Migrations | Run as a dedicated one-shot container using `app_migrator` credentials (separate secret); forward-only with an expand/contract discipline for breaking changes; a restore point exists before any migration |
| Rollback | Previous image tag retained; migrations that are not backward-compatible are shipped in two steps so rollback never needs a DB revert |
| Staging | Same digests, synthetic data, `noindex`, IP allow-listed or Basic Auth; used for migration rehearsal and release verification |
| Feature flags | Database-backed flags to disable risky features without a deploy |
| Secrets | Docker secrets or root-only `env` files (`chmod 600`, `root:root`); no secret in an image layer, in Compose in Git, or in CI logs (gitleaks gate) |
| Backups before deploy | Pre-deploy backup + WAL marker recorded in the deployment log |

---

## 5. Network exposure: PostgreSQL must never be public

1. **No published port** in Compose for `db`/`redis`/`object`; they exist only on the internal
   `data` network (`internal: true`), so there is no host listener at all.
2. `pg_hba.conf` grants only: local socket for admin tasks, and `scram-sha-256` for the app network
   range. **No** `0.0.0.0/0` rules, ever.
3. `listen_addresses` restricted to the container network.
4. UFW is enabled and denies inbound by default — but it is treated as a **secondary** control,
   because Docker publishes ports by manipulating iptables ahead of UFW's chain. The primary control
   is "the port is never published".
5. Administrative access to the database is only via `docker compose exec` on the host over SSH, or
   through a temporary tunnel on loopback, and never through a publicly reachable port.
6. CI/CD never connects to production Postgres directly; it connects to a migration runner, or runs
   dev-only tooling against staging.
7. A monitoring probe from outside the host asserts that 5432 (and Redis 6379) are closed.

---

## 6. Domain, DNS and HTTPS

| Item | Decision |
|---|---|
| Domain | Customer-facing custom domain with a subdomain per environment (`app.example.sa`, `staging.example.sa`) |
| DNS | A/AAAA records at the registrar; low TTL during cutover; optional Cloudflare in front (proxy mode) for DDoS absorption and WAF — with the caveat that it terminates TLS and requires restoring the client IP header trust chain |
| `__Host-` cookies | Require HTTPS, no `Domain`, `Path=/` — hence HTTPS is mandatory, not optional |
| Subdomain-per-tenant | **Not** in V1 (cookie sprawl, wildcard certificates, more surface); tenant selection happens after login |
| Email | SPF/DKIM/DMARC configured for the transactional sending domain; bounces handled; sending is never done from the app containers directly without provider credentials |
| Certificate monitoring | Expiry alert at 21/14/7 days; automated renewal verification |

---

## 7. Secrets management

| Rule | Detail |
|---|---|
| Never in Git | `.env` files are git-ignored; a `.env.example` with placeholders is committed; gitleaks runs in CI and pre-commit |
| Never in images | Secrets are injected at runtime (Docker secrets or root-only env file), never `ARG`/`ENV` in a Dockerfile |
| Never in logs | A logging filter redacts keys matching `password|secret|token|key|authorization|cookie`; Sentry is configured with the same scrubbing plus `send_default_pii=False` |
| Per-component | `app_rw`, `app_ro`, `app_migrator`, `app_backup`, object-storage keys, mail keys, Grafana admin — each its own credential |
| Rotation | Documented schedule + immediate rotation on personnel change, on suspicion, and after any restore into a non-original environment |
| Access audit | Who read which secret is limited by host access control; secret access is included in the break-glass review |

---

## 8. Pre-launch checklist (production readiness)

- [ ] PostgreSQL, Redis, MinIO have **no** published ports; external port probe shows 5432/6379 closed
- [ ] TLS with a valid certificate, HTTPS redirect, HSTS, and security headers verified (A-grade scan)
- [ ] `manage.py check --deploy` passes with the production settings module
- [ ] All secrets sourced from secrets, none in Git/images/logs (gitleaks + manual review)
- [ ] Backups: local + off-site configured, verified, and a **restore drill completed successfully**
- [ ] Monitoring and alerting live; a synthetic test alert has been received by a human
- [ ] Rate limits active on auth, import, export and download paths
- [ ] RLS verified as the runtime role (isolation + fail-closed) on the production database
- [ ] Audit chain verification job scheduled and green
- [ ] Runbooks written: deploy, rollback, restore, incident, credential rotation, tenant offboarding
- [ ] Staging rehearsed the same release; migrations rehearsed on a restored copy of production data
- [ ] Legal/operational: retention policy, privacy notice, DPAs, and the "not a ZATCA e-invoice
      product" positioning confirmed in writing

---

## 9. Scaling path (so today's choices do not become tomorrow's rewrite)

| Stage | Trigger | Action |
|---|---|---|
| 1 (V1) | Current | Single VPS, Compose, vertical scaling |
| 2 | CPU/db contention | Split DB to a managed/separate host; keep the app VPS; add a replica for reporting |
| 3 | Availability requirement | Add a warm standby (streaming replica + promotion runbook), then a load balancer in front of two app nodes |
| 4 | Multi-region / contractual data residency | Per-tenant database routing; the schema already supports extraction by `company_id` ([F §9](F-tenant-isolation.md)) |

The application is stateless apart from the database, Redis, and object storage, and every manifest is
close to Kubernetes-ready, so each step is additive rather than a re-architecture.
