# N. Background Jobs and Queues

**Yes, a queue is required.** Three V1 workloads cannot run inside a request: Excel import
validation for thousands of rows, bilingual PDF rendering, and nightly consolidation of dashboards and
backups. Everything else stays synchronous — a queue used for trivial work is just latency with extra
failure modes.

---

## 1. Workloads that need a worker

| Job | Trigger | Typical duration | Retry policy | Failure handling |
|---|---|---|---|---|
| BOQ / budget / expense import: parse + validate | User action | 5–60 s (20k rows) | 2 retries | Batch marked `parse_failed`/`validation_failed` with issues retained; user can fix and retry |
| Import **commit** | Explicit user confirmation | 2–30 s | **no automatic retry** (financial write) | Runs synchronously in the API transaction; on error the batch stays retryable and nothing was written |
| IPC certificate PDF (AR/EN) | IPC certification | 1–5 s | 3 retries | Certificate missing → visible "regenerate" action; the IPC itself is already certified (the PDF is derived, never the source of truth) |
| BOQ / report export (XLSX/PDF) | User action | 3–60 s | 2 retries | Export marked `failed` with a reason; user retried manually |
| Antivirus scan + MIME sniff of an upload | Upload finalisation | 1–10 s | 3 retries | `scan_failed` keeps the file unservable (fail closed) |
| Notification dispatch (approval requested, IPC certified, import failed, SLA reminder) | Domain events | < 1 s each | 5 retries with backoff | Failures do not affect the business transaction |
| Materialized view refresh (`mv_project_financial_position`, `mv_project_cost_by_costcode`, `mv_company_dashboard`) | Nightly + debounced after certification/posting | 1–30 s | 2 retries | Dashboards keep serving the last good refresh with its timestamp |
| Outbox dispatch (publish committed jobs to the broker) | Continuous | < 1 s | infinite with backoff + dead-letter | A stalled dispatcher is alerted; unconfirmed jobs remain in the outbox |
| Audit checkpoint + chain verification | Nightly | seconds–minutes | 2 retries | Verification mismatch raises P1 |
| Audit partition pre-creation | Daily | < 1 s | 3 retries | Alert if partitions are < 30 days ahead |
| Session GC, expired upload-session GC, idempotency-key GC, old outbox pruning | Hourly/daily | < 1 s | 2 retries | Low severity |
| Backup verification restore test | Weekly | minutes | no retry | Drill failure is a P1/P2 alert ([O §6](O-backup-disaster-recovery.md)) |
| Forecast/period-close pre-computation | Optional, monthly | seconds | 2 retries | Non-critical |

---

## 2. Why Celery + Redis (and what we refuse to do with it)

* Celery has mature retry/routing/beat semantics, and Django integration is well understood by
  regional hiring pools.
* Redis is already present for cache/sessions; adding a broker costs no new operational surface.
  Durability caveat handled by the outbox (§3) and by `appendonly` in Redis against container restarts.
* **Refused:** performing financial writes straight from the broker message (the message is a
  *request*, the database transaction is the authority); using the queue as an event log; letting a
  worker run without tenant context; unbounded retries on money-touching jobs.

---

## 3. The outbox pattern (how a job is actually enqueued)

```
service (inside the business transaction)
   ├─ business writes (IPC certification, VO approval, import commit …)
   ├─ audit row
   └─ INSERT INTO job_outbox (job_type, payload, dedupe_key, project_id, actor, request_id)
COMMIT
dispatcher task (every few seconds)
   ├─ app.claim_outbox_jobs(worker_id)  → FOR UPDATE SKIP LOCKED (no double dispatch)
   ├─ publish to broker (Celery) with the outbox id
   └─ mark 'published' / retry with backoff / dead-letter after max attempts
worker task
   ├─ idempotency guard on the outbox id (already processed ⇒ no-op)
   ├─ open transaction, SET LOCAL tenant context from the envelope
   ├─ re-check authorization before acting
   ├─ do the work, write audit/outbox as needed
   └─ commit and mark completed
```

Guarantees: no job is lost on a crash between commit and publish; no job is processed twice because
of a duplicate publish; the queue never becomes the only record of a financial event.

---

## 4. Routing, priorities and limits

| Queue | Jobs | Concurrency |
|---|---|---|
| `interactive` | PDFs, exports, notification dispatch | 2–4 workers, high priority |
| `bulk` | imports (parse/validate), MV refresh, heavy exports | 1–2 workers, capped to protect the database |
| `maintenance` | audit checkpoints, partitions, GC, reconciliation | 1 worker (low priority, off-peak) |
| `scan` | AV/MIME scanning | 2 workers, isolated (no DB writes except the version row) |

* Per-tenant fairness: bulk jobs are chunked and rate-limited per company so one tenant's 20k-row
  import cannot starve others.
* Timeouts: hard task time limit (10 min for imports, 3 min for PDFs) + soft limit for logging.
* Memory: `max_tasks_per_child` set to recycle workers after N tasks (guards against leaks in
  Excel/PDF libraries).
* Concurrency safety: financial jobs are idempotent by design (unique source keys, status guards), so
  a duplicate delivery cannot double-post.

---

## 5. Scheduling (Celery beat, DB-backed schedule)

| Schedule | Job |
|---|---|
| Every 5 s | outbox dispatch |
| Every 5 min | notification dispatch, session GC sweep |
| Hourly | expired upload sessions, idempotency keys, outbox pruning |
| Nightly 01:00 Asia/Riyadh | MV refresh, contract-value cache reconciliation, receivable recomputation |
| Nightly 01:30 | audit partition pre-creation, audit checkpoint export + incremental verification |
| Weekly | full audit chain verification per company; **restore drill** |
| Monthly | retention pruning (audit partitions, old import rows), storage usage report, elevation review reminder |

Schedules live in the database (`django_celery_beat`) so a schedule change is a reviewable,
auditable change rather than a container restart.

---

## 6. Observability of jobs

* Every job carries `company_id`, `actor_user_id`, `request_id`, `correlation_id`; logs and traces
  are filterable by them.
* Metrics: queue depth, task duration histogram, failure/retry counters per task type, dead-letter
  count, outbox lag (time between commit and publish).
* Alerts: dead-letter > 0 (warning), outbox lag > 5 minutes (warning), any financial job failed
  (high), backup/verification job failed (critical) — see [Q](Q-observability.md).
* A "Jobs" screen for owners shows recent imports/exports with their status and failure reason, so the
  UI never silently loses a user's work.
