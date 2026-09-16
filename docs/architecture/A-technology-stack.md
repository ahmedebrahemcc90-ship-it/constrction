# A. Recommended Technology Stack and Justification

Selection criteria, in priority order (this is a financial, multi-tenant, security-sensitive system
maintained by a small team and deployed to a single Linux VPS):

1. **Correct decimal semantics by default** — a language/library stack where `float` is *not* the
   convenient option.
2. **Security defaults that fail safe** — CSRF, session, password hashing and ORM parameter binding
   available in-framework rather than hand-rolled.
3. **Arabic support on the critical path** — RTL layout *and* correctly shaped Arabic PDFs.
4. **Heavy data import/export ergonomics** — Excel/CSV BOQ ingestion, large report generation.
5. **Explicit transaction and row-lock control** — IPC certification requires it.
6. **Testability** — integration tests against real PostgreSQL (RLS cannot be tested on SQLite).
7. **Operability on one VPS** — no exotic runtime, boring containers, easy on-call.
8. **Recruitable in the region** — the pool of available engineers in SA/Gulf/Jordan/Egypt.

---

## 1. Recommended stack

### 1.1 Backend

| Layer | Choice | Version (pin) |
|---|---|---|
| Language | Python | 3.12.x |
| Web framework | Django | 5.0.x (LTS 5.2 when available for the build window) |
| API layer | Django REST Framework | 3.15.x |
| DB driver | psycopg (v3) | 3.2.x |
| DB | PostgreSQL | 16.x |
| Cache / broker | Redis | 7.2.x |
| Background jobs | Celery + celery-beat (django-celery-beat for DB-backed schedules) | 5.4.x |
| Money | `decimal.Decimal` + internal `Money`/`Qty` helpers (no library magic in the financial core) | — |
| PDF | WeasyPrint (Pango/HarfBuzz shaping) primary; Gotenberg (headless Chromium) fallback | WeasyPrint 62.x |
| Excel/CSV | openpyxl (read-only mode, `defusedxml` XML parsing) + `csv` stdlib | 3.1.x |
| Password hashing | Argon2id via `argon2-cffi` as `PASSWORD_HASHERS[0]` | — |
| MFA | TOTP (`pyotp` + `qrcode`) | — |
| Object storage | S3-compatible API via `boto3` | — |
| HTTP client (outbound) | `httpx` with strict allowlist/EgressGuard wrapper | — |
| Styles | `ruff` (lint/format), `mypy` (types on financial + authz modules) | — |

### 1.2 Frontend

| Layer | Choice |
|---|---|
| Framework | React 18 + TypeScript 5 (Vite) |
| Routing/data | TanStack Router + TanStack Query |
| Tables/editing | TanStack Table; virtualized grids for BOQ/IPC line entry |
| Styling/i18n | Tailwind CSS with logical properties (`ms-*`/`me-*`), `i18next` + `react-i18next`, per-locale `dir` switching (`ar` → `rtl`, `en` → `ltr`) |
| Forms | React Hook Form + Zod schemas generated from the same contracts as the API |
| Auth transport | **Cookie session + CSRF header** (no token in `localStorage`) |
| Charts | Recharts/ECharts (LTR and RTL aware rendering) |

### 1.3 Infrastructure & operations

Docker Engine 26 + Docker Compose v2 · nginx (TLS termination, rate limiting, security headers) ·
Certbot/Let's Encrypt · MinIO (S3-compatible private object storage) · pgBackRest (PITR) ·
restic (encrypted off-site volumes/objects) · Prometheus + Grafana + Loki + Alertmanager +
node_exporter + postgres_exporter + cAdvisor + blackbox_exporter · Trivy/gitleaks/semgrep in CI ·
GitHub Actions → GHCR → SSH deploy.

---

## 2. Why Django + PostgreSQL + React (and not the alternatives)

### 2.1 Why Python/Django

- **Decimal is first class.** `decimal.Decimal` is a built-in type; psycopg maps `numeric` ↔
  `Decimal` losslessly with no adapter. The *default* accident is correct behaviour. In JS/Node,
  `number` is IEEE-754 and correctness requires constant discipline (`Prisma.Decimal`, no `+` on
  money) — an avoidable class of production incidents in a financial product.
- **Security defaults on by default.** CSRF protection, clickjacking protection, secure/HttpOnly
  session cookies, password hashing, ORM-level parameter binding, `SECURE_*` settings, `check
  --deploy`, migration framework. ASVS controls are largely configuration, not construction.
- **Transactions and locks are explicit and readable.** `transaction.atomic()`,
  `select_for_update()`, `SET TRANSACTION ISOLATION LEVEL`, `pg_advisory_xact_lock` all compose
  naturally, which is exactly what IPC certification needs (see [I §6](I-financial-architecture.md)).
- **Arabic PDFs work.** WeasyPrint shapes Arabic through Pango/HarfBuzz, so "مستخلص رقم 3" renders
  connected and RTL-correct inside a bilingual certificate. (wkhtmltopdf does not; ReportLab needs
  manual reshaping/bidi; raw FPDF is unusable for Arabic.)
- **Heavy background work is idiomatic.** Celery + beat covers PDF generation, BOQ import,
  overnight MV refresh, backup verification and approval SLA escalation.
- **Test tooling is mature for this domain.** `pytest` + `pytest-django` + `factory_boy` +
  `testcontainers` gives real-PostgreSQL integration tests (mandatory: RLS behaves differently only
  against a real PG instance and only for a non-owner role), plus `hypothesis` for property-based
  tests of rounding invariants.

### 2.2 Why PostgreSQL 16 specifically

Row-Level Security with `FORCE` semantics, composite foreign keys, `GENERATED ALWAYS AS ... STORED`
columns (DB-computed `amount = qty × rate`), generated/expressional indexes, JSONB for flexible
metadata, range partitioning for audit tables, `pg_stat_statements`, `pgcrypto` for digest-based
hash chains, advisory locks, `SERIALIZABLE` isolation, and mature PITR tooling (pgBackRest).
Non-negotiable requirement: **never SQLite**, even in tests (see [S](S-testing-strategy.md)).

### 2.3 Why a React SPA as the front end

The V1 workflows that decide whether the product is usable are dense grids and live dashboards:
BOQ tree editing, IPC line entry with running cumulative checks, budget vs actual matrices,
profitability dashboards with drill-down, and full RTL/LTR bilingual presentation. These are a poor
fit for server-rendered pages with occasional progressive enhancement. The cost is an extra API
surface, which we pay for deliberately: cookie sessions + CSRF + a single authorization choke point
([G](G-authorization-rbac.md)) rather than bearer tokens in browser storage.

*Accepted alternative:* server-rendered Django templates + htmx for the whole app would shrink the
attack surface and the team's scope mid-build, at the price of weaker grid/dashboard ergonomics.
Recorded as an open decision ([`open-decisions.md`](open-decisions.md) D-02) because it is a
product-experience call, not only a technical one.

---

## 3. Alternatives considered

| Option | Why it was not selected |
|---|---|
| **ASP.NET Core 8 + EF Core** | Excellent typing, decimal, performance. Rejected only on team/velocity and Arabic-PDF library maturity: less regional hiring depth, WeasyPrint-class Arabic shaping has no direct equivalent. Viable runner-up if the team is .NET-first. |
| **Laravel (PHP 8.3)** | Strong regional talent pool, mature ecosystem, fast delivery; `mpdf`/`dompdf` Arabic support is workable but weaker than Pango shaping, and financial-decimal discipline relies on casts. Viable if PHP expertise is the dominant team skill. |
| **Node/NestJS + Prisma** | Great DX; money handling in JS is a permanent correctness tax in this domain, and long-running CPU work (PDF, Excel) needs separate workers anyway. |
| **Spring Boot (Java)** | Rock-solid transactions/security; heavier operational and development footprint than warranted for a single-VPS SaaS. |
| Schema-per-tenant or DB-per-tenant PostgreSQL | Real isolation benefits, but at hundreds of companies it means hundreds of migration targets, degraded connection pooling, cross-tenant reporting complexity, and backup/restore granularity we do not need yet. Chosen approach is shared-schema + RLS now, with a documented migration path if an enterprise customer contractually demands physical separation ([F §9](F-tenant-isolation.md)). |
| MongoDB / document DB | Financial documents, invariants, composite FKs, RLS, composite constraints — this is relational work. |
| Kubernetes | Not justified at one-VPS scale; adds a control plane to secure and operate. Docker Compose today, with a container/manifest design that is K8s-portable ([P §9](P-deployment-vps-docker.md)). |
| Serverless / managed PaaS | Row-Level Security with `SET LOCAL` semantics, private DB networking, and PITR control are simpler on a VPS; also keeps data-residency options open. |
| microservices | A single deployable modular monolith with hard internal module boundaries ([C](C-application-architecture.md)) is the correct granularity until a real scale or team-topology driver appears. |

---

## 4. Localization stack (Arabic RTL / English LTR / SAR / Asia/Riyadh)

| Concern | Decision |
|---|---|
| Canonical storage | Gregorian dates as `date`, instants as `timestamptz` (UTC in DB) |
| Display timezone | `Asia/Riyadh` (UTC+03:00, no DST) applied at the presentation edge, per user override |
| Currency | `SAR` default; ISO 4217 code stored on every financial document; `currency_code` + `fx_rate` columns exist from day one (V1 is SAR-only, no FX module) |
| Amount scale | `numeric(20,4)` for money, `numeric(18,6)` for quantities, `numeric(18,4)` for rates |
| VAT | Configurable per company **and effective-dated** (`tax_rates.effective_from`), snapshotted onto each document line as basis points (`vat_rate_bp`) so historical VAT is reproducible |
| Number formatting | ICU via `babel`/`Intl`; Western Arabic numerals (`1,234.56`) for financial figures in both locales — avoids ambiguity in reconciliation; Arabic-Indic digits are a per-tenant *display* preference, never a storage format |
| Bilingual documents | Every human-facing entity carries `*_ar` and `*_en` name/description fields; PDF templates are locale-parameterised with `dir=rtl`/`dir=ltr` and font fallback |
| Fonts | Bundle `Noto Naskh Arabic` (or Amiri) + Noto Sans in the PDF container image; no runtime font downloads |
| Hijri dates | Out of V1 data model; may be rendered as an additional display string later (open decision D-12) |
| Saudi regulatory identifiers | `cr_number`, `vat_number` (15 digits, `3…` pattern validated by format only), National Address components stored on company/parties. **Stored as data only — no validation against, or submission to, any government platform.** |
| Reference data | Seeded `units_of_measure` (Arabic + English labels), Saudi regions/cities, currencies — reference tables are read-only to tenants |

---

## 5. Explicit non-choices (and why)

- **No floating point anywhere in the financial path.** No `float`/`double`/`REAL` columns for money
  or quantity; enforced by a CI schema lint that fails the build if a `real`/`double precision`
  column appears in a financial table ([S §5](S-testing-strategy.md)).
- **No client-supplied totals.** Every document total is recomputed server-side; DTOs simply do not
  accept totals as input ([I §5](I-financial-architecture.md)).
- **No dynamic SQL reporting builder in V1.** Curated views/materialized views + parameterised
  filters only; a user-authored query/expression feature is a SQL-injection and resource-exhaustion
  surface we do not need yet ([ADR-0021](adr/ADR-0021-curated-reporting-not-query-builder.md)).
- **No ZATCA / Mudad / GOSI / Etimad / Absher integrations, no assumed APIs.** Also no e-invoice
  claim: V1 documents are commercial certificates, and customer expectations must be managed in
  writing ([risks.md](risks.md) R-08).
- **No JWT in browser storage.** Opaque, DB-backed sessions in `__Host-` cookies ([H](H-authentication-sessions.md)).
- **No public PostgreSQL port, ever.** Container-internal network only ([P §5](P-deployment-vps-docker.md)).
- **No secrets in Git, images, or CI logs.** Docker secrets + per-role credentials + gitleaks gate.

---

## 6. Version & dependency policy

- Python and Node base images pinned by **digest**; application dependencies pinned with hashes
  (`pip-compile --generate-hashes`, `npm ci` + lockfile committed).
- Renovate/Dependabot opens dependency PRs; **security patches are the only PRs allowed to bypass
  the normal weekly release train**.
- PostgreSQL, Redis and MinIO upgraded by *restore-from-backup into the new version* (or
  `pg_upgrade` with a verified restore point), never in place without a tested rollback.
- Every dependency addition in the financial, auth, or file-processing path requires a short ADR
  note (why, alternative, blast radius).
