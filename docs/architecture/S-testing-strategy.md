# S. Testing Strategy

Test categories are chosen because **each one can catch a class of defect the others cannot**. A
green suite that only tests happy paths in one tenant with float arithmetic would prove nothing about
this product.

---

## 1. Test layers

| Layer | Scope | Tooling | Runs |
|---|---|---|---|
| Unit | Pure functions, validators, permission resolution, money helpers | pytest, Hypothesis | Every push (seconds) |
| Integration | Service + real PostgreSQL (no mocks of the DB) | pytest-django, `TransactionTestCase` where locks/triggers matter | Every push |
| Financial | Arithmetic, rounding, state transitions, idempotency, concurrency | pytest + golden fixtures + `threading`/`multiprocessing` | Every push |
| Authorization | Full permission matrix, project scope, SoD | pytest + DRF `APIClient` (no UI) | Every push |
| Tenant isolation | Two (and three) tenants, every endpoint | pytest + fixtures | Every push |
| Schema/conformance | RLS coverage, grants, invariants as SQL assertions | psql/pytest against a migrated DB | Every push |
| Security | ZAP baseline, header checks, upload abuse, dependency scan, SAST | OWASP ZAP (CI), Trivy, gitleaks, semgrep, pip-audit | Nightly + pre-release |
| End-to-end | A realistic project lifecycle through the API | pytest (API-level); Playwright for critical UI journeys | Nightly + pre-release |
| Performance | Import of 20k BOQ rows, dashboard under multi-tenant load | Locust/k6 with seeded data | Weekly + pre-release |
| Backup/restore | Restore from real backups, integrity assertions | Scripted drill (see [O §6](O-backup-disaster-recovery.md)) | Monthly + before major releases |
| Accessibility & i18n | AR/EN layout, RTL correctness, PDF rendering | axe-core + snapshot review of Arabic PDFs | Pre-release |

**Environment rule:** integration/authorization/isolation/financial tests run against a **real
PostgreSQL** (Testcontainers or a service container in CI) with the same roles, RLS and grants as
production. A test suite that runs as a superuser proves nothing about tenant isolation — this was
demonstrated literally during Phase 0, where the runtime role hit an RLS wall that a superuser never
would have seen.

---

## 2. Test topology and fixtures

```
tests/
  conftest.py                 # DB roles, tenant contexts, factories
  fixtures/tenants.py         # Company A + Company B, branches, users, projects
  fixtures/commercial.py      # contract, BOQ, VO, IPC, expense, collection builders
  fixtures/files.py           # real PDF/XLSX/PNG samples incl. malicious ones
  unit/                       # pure logic
  integration/                # services against the DB
  financial/                  # arithmetic + concurrency + golden files
  authorization/              # permission matrix
  isolation/                  # cross-tenant attempts
  schema/                     # SQL-level assertions (RLS, grants, no floats)
  security/                   # upload, headers, ZAP-driven
  e2e/                        # lifecycle journeys (API), Playwright for UI
  performance/                # locust/k6 scripts + seeded dataset generator
```

Two-tenant fixture (mandatory in every integration test module, autouse): Company A and Company B,
each with 2 branches, 4 users in different roles, 2 projects, a contract with BOQ, an approved VO, a
certified IPC, posted expenses, a collection, documents and approval workflows. Tests assert the
**negative** case first (B cannot see A), then the positive one.

---

## 3. Authorization tests (the matrix)

For each permission code and each role template, automated generation of:

| Caller | Endpoint | Expected |
|---|---|---|
| Holder of the permission, in scope | allowed operation | 2xx, effect persisted |
| Holder without the permission | same operation | 403, **no** state change |
| Holder in a *different project* | same operation | 404 on detail, empty list, no state change |
| Cross-tenant caller | same operation with another tenant's id | 404 (never 403), no state change |
| Unauthenticated | same operation | 401 |
| AAL1 session, sensitive operation | certify/post/export | 403 `auth.step_up_required`, no state change |
| Submitter | approve own document | 403 (SoD), no state change |
| Anyone | grant a permission they lack | 403 + audit row |

Plus: **route parity test** — introspect the URLconf and fail the build when any state-changing route
lacks an explicit permission declaration; **UI-independence test** — the same matrix runs against the
plain API, proving the SPA is not load-bearing.

---

## 4. Tenant-isolation tests (details in [F §7](F-tenant-isolation.md))

Automated, blocking, and run against the **application role**, not a superuser:

1. Read isolation across every list/detail endpoint (both directions).
2. Write isolation: creates/updates with foreign ids fail and change nothing.
3. Missing-context fail-closed: no `app.current_company_id` ⇒ zero rows, writes refused.
4. Context leakage across pooled connections: request A → request B on the same connection, assert no
   bleed; assert `reset_tenant_context()` ran.
5. Cache-key isolation: warm Company A's caches, then verify Company B never receives A's payloads.
6. Storage isolation: Company A cannot presign-URL Company B's object; Company A cannot guess a key.
7. Export/search isolation: an export generated by A contains no B rows (string-level assertion on
   the generated file, not just the query).
8. Job isolation: a job enqueued for A, executed under B's context, is refused.
9. **RLS coverage assertion**: any table with a `company_id` column without
   `relrowsecurity + relforcerowsecurity + policy` fails the build.
10. **Grant assertion**: an app role holding UPDATE/DELETE on an append-only table fails the build.

---

## 5. Financial tests

**Property-based (Hypothesis, `Decimal`):**
* `round(q × r, 2)` of the line equals the header's line sum (sum-of-rounded-lines identity).
* Retention never exceeds the cap and never decreases across certificates of the same contract.
* Advance recovery never exceeds the advance amount; after full recovery, recovery is exactly 0.
* VAT = `round(base × bp / 10000, 2)`; the identity holds for random bases/rates including 0 and 15%.
* Net payable identity: `current + additions − retention − advance − other = net` and
  `net + vat = total`; `total − received = outstanding`.
* Currency and scale: no value ever has more than 4 decimals; no float enters the pipeline.
* Monotonic cumulative: `cumulative_work_value` is non-decreasing across a contract's certificates
  unless an explicit reversal occurred.

**Golden regression (frozen expected output):** the worked example of
[K §8](K-boq-ipc-vo-design.md) — multi-section BOQ, three VOs of which one is rejected, six IPCs across
periods, partial collections, retention release, plus the Arabic PDF certificate snapshot. Changing a
number requires an explicit, reviewed update to the fixture (the test fails otherwise) — this is the
guard against Silent Rounding Changes.

**Concurrency (real threads/processes against real PostgreSQL):**
* Two parallel certifications of the same contract period ⇒ exactly one succeeds; the second is
  refused (`IPC_FROZEN`/period conflict/`IPC_PREVIOUS_VALUES_INVALID`), and revenue is counted once.
* Two parallel approvals of the same VO ⇒ exactly one ledger entry.
* Parallel collection allocations summing above the collection amount ⇒ the loser is refused; the
  total never exceeds the collection.
* Two parallel BOQ imports into the same BOQ ⇒ one commits, the other fails cleanly (no partial rows).
* Simultaneous "post expense" from two tabs ⇒ idempotent; one posted record.

**Negative/forgery tests (every one of these must fail closed):**
* Client-sent totals, VAT, net payable, previous cumulative values.
* Client-sent `unit_rate` on certification (ignored, snapshotted rate used).
* Forged `vat_rate_bp` (must error, not silently override).
* Over-certification beyond `BOQ + approved VO` quantity.
* Editing a certified IPC, an approved VO, an approved BOQ item, a posted expense, a posted collection.
* Deleting an audit row, a ledger entry, a snapshot.
* Reusing a document number or issuing a second certificate for the same period.

---

## 6. Schema and integrity conformance tests

Executed as SQL assertions against a freshly migrated database:

1. No `real`/`double precision` column on a financial table.
2. Every tenant table: `relrowsecurity` **and** `relforcerowsecurity` **and** ≥ 1 policy.
3. Every composite-FK parent has the exact unique key the child needs.
4. Every table with `company_id` has an index with `company_id` leading.
5. Append-only tables: the runtime role has no UPDATE/DELETE.
6. Application roles: no `SUPERUSER`, no `BYPASSRLS`, no `CREATEROLE`, no `CREATEDB`.
7. Immutability smoke tests: for each frozen document type, an UPDATE of a protected column raises the
   expected error (including the no-argument trigger case that was silently vacuous in Phase 0).
8. RLS smoke test as the runtime role, including the fail-closed no-context case.
9. The audit chain verifies clean after a full test run, and detects a deliberate tamper.

---

## 7. Security tests

| Test | Method |
|---|---|
| Baseline DAST | OWASP ZAP baseline against staging on every release |
| Headers/CSP/cookies | Assertions on `Content-Security-Policy`, HSTS, `X-Content-Type-Options`, cookie flags (`HttpOnly`, `Secure`, `SameSite`, `__Host-` prefix) |
| Auth abuse | Rate-limit and lockout tests, generic error messages, no user enumeration |
| Session lifecycle | Fixation, revocation on password change, idle/absolute expiry, logout invalidates server-side |
| CSRF | Mutation without token rejected; cross-origin rejected |
| Upload abuse | Macro file, wrong magic bytes, oversized file, zip bomb, EICAR test file (quarantined, not served) |
| IDOR spray | Script enumerating ids across endpoints with a second tenant's data: zero successes |
| Dependency & image scanning | `pip-audit`, `npm audit`, Trivy on every image; fail on criticals above the agreed SLA |
| Secrets | gitleaks in pre-commit + CI; build fails on a finding |
| SAST | semgrep with Django/DRF and Python security rules |
| Error handling | No stack traces or SQL to clients in production mode; 500s carry a request id only |
| Log hygiene | Assert no password/token/document content appears in log output during a scripted flow |

---

## 8. Backup and restore verification (details in [O](O-backup-disaster-recovery.md))

* **Monthly automated drill**: restore the newest off-site backup into an isolated instance, run the
  integrity assertions of [O §4](O-backup-disaster-recovery.md) plus the tenant-isolation smoke suite,
  verify the audit chain, record the measured RTO/RPO, and archive the report.
* **PITR test**: restore to a timestamp *between* two known writes and assert exactly the expected
  state (proves the WAL chain, not just the base backup).
* **Object restore test**: restore a deleted document version from object versioning + the restic
  snapshot.
* **Failure-path tests**: backup storage unreachable (alert fires, backs off, resumes); corrupted
  backup file (verify catches it before it is trusted); expired credentials (job fails loudly).
* A drill is only "passed" when a human has confirmed the restored application can log in, read a
  project's financials and produce a correct report.

---

## 9. Performance and load

| Scenario | Target |
|---|---|
| BOQ import, 20k rows, 3 levels of sections | validate < 60 s; commit < 30 s; no partial state on failure |
| Project financial dashboard (warm MV) | p95 < 800 ms |
| Project list for a company with 200 projects | p95 < 500 ms |
| IPC certification (30 lines, snapshot + audit + PDF enqueue) | p95 < 1.5 s |
| Report export (XLSX, 10k rows) | < 20 s in a worker, progress visible |
| Concurrent load: 50 users across 10 tenants | error rate < 0.5%, p95 within SLO, no tenant starving another |
| Audit write overhead | < 10% on the transaction, verified by a benchmark |

Load tests run with **realistic multi-tenant data volumes** (a 20-tenant dataset generator) because
single-tenant benchmarks hide both RLS overhead and noisy-neighbour effects.

---

## 10. CI/CD gates (a merge is blocked by)

1. Lint/format + type checks (ruff/mypy on critical paths, ESLint/tsc).
2. `manage.py makemigrations --check --dry-run` — no missing or uncommitted model changes.
3. Schema conformance suite (§6) against the real DB.
4. Unit + integration + authorization + isolation + financial suites.
5. Coverage floor on the domain/authorization layers (target ≥ 85 %; the money and permission code
   must be near-total).
6. Security gates: gitleaks, semgrep, `pip-audit`, Trivy (critical), ZAP baseline on staging.
7. Migration rehearsal against a restored production-like copy for schema-changing releases.
8. A **manual release checklist** for anything touching money, permissions or the schema: reviewer
   sign-off, backup verified, rollback path named, staging rehearsed.

Test failures are never "retried until green". A flaky test is a defect in the test (usually an
unstated concurrency/locking assumption) and is fixed or quarantined with a linked issue and an expiry
date — never deleted silently.
