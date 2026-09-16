# F. Tenant Isolation Architecture

**Requirement:** Company A must NEVER access Company B data — and this must hold even when a bug
exists in one layer. Isolation is therefore layered: schema, database, application, cache, storage,
and tests.

---

## 1. Model choice: shared schema, one database, `company_id` everywhere

| Option | Trade-off | Decision |
|---|---|---|
| Database per tenant | Strongest isolation, real per-tenant restore | Rejected for V1: N migration targets, connection-pool fragmentation, cross-tenant reporting impossible, and a restore of one company needs a full instance restore anyway |
| Schema per tenant | Good isolation, medium cost | Rejected for V1: hundreds of schemas make migrations and `pg_dump`-per-tenant operations heavy, and RLS still has to be right for shared reference tables |
| **Shared schema + `company_id` + RLS + composite FKs** | Lowest operational cost, strongest *code-level* guarantees if designed well | **Selected** ([ADR-0001](adr/ADR-0001-multi-tenancy-shared-schema-rls.md)) |

Physical separation remains available for an enterprise contract that demands it
(see [§9](#9-path-to-physical-separation-if-ever-required)).

---

## 2. Layer 1 — Schema: tenant ownership is explicit and structural

1. **Every tenant-owned table has `company_id uuid NOT NULL`** (`INV-01`). The full table inventory
   is in [E §12](E-database-design.md); global tables (`users`, `permissions`, reference data) are
   enumerated there too and are the *only* tables without it.
2. **Composite foreign keys carry the tenant**: children reference `(company_id, parent_id)`.
   A cross-tenant reference cannot be inserted, even by a buggy service
   ([ADR-0018](adr/ADR-0018-composite-foreign-keys.md)). Verified in Phase 0: a contract for
   Company A pointing at Company B's client is refused by `fk_contracts_client`.
3. **Project-scoped composite keys**: children of project-scoped parents reference
   `(company_id, project_id, id)`, so an IPC line cannot name another project's BOQ item even inside
   the same company ([ADR-0019](adr/ADR-0019-project-scoped-composite-foreign-keys.md)).
4. **Unique keys are always tenant-qualified** (`(company_id, code)`), never global.

---

## 3. Layer 2 — Database: Row-Level Security, fail-closed and forced

| Property | Implementation |
|---|---|
| Enabled **and forced** | `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY` on all tenant tables, so even the table owner is subject to policies |
| Predicate | `company_id = app.current_company_id()`, where the helper reads the transaction-local GUC and returns `NULL` when unset |
| Fail-closed | With no context, the predicate is `NULL` for every row ⇒ zero rows visible, zero rows writable. **Verified:** 0 rows with no context, and a cross-tenant INSERT is refused by `WITH CHECK` |
| Context setting | `SET LOCAL app.current_company_id = …` inside the request transaction; `SET LOCAL` guarantees the value cannot leak back into a pooled connection |
| Pool safety | `app.reset_tenant_context()` is executed on connection release as a second guard |
| Privileges | Runtime role `app_rw` is `NOSUPERUSER NOBYPASSRLS NOCREATEROLE`; **verified** in Phase 0 |
| Append-only tables | `REVOKE UPDATE, DELETE` on `audit_logs`, `contract_value_ledger`, `ipc_snapshots`, `approval_actions` and the approval/status history tables |
| `companies` itself | Its policy is keyed on the row's own `id`; the company switcher reads only through `app.my_companies()` (SECURITY DEFINER, pinned `search_path`, membership-joined) |

**What RLS does not do:** it cannot express project-level authorization (the database sees only the
GUCs we expose) and it does not defend against a compromised superuser or a stolen backup. Those are
covered by the application choke point ([G §4](G-authorization-rbac.md)) and by encryption/backups
([O](O-backup-disaster-recovery.md)).

---

## 4. Layer 3 — Application: one choke point, no ambient tenant

### 4.1 The only source of tenancy

```
HTTP request
  → session cookie (opaque id) → session row → user_id
  → membership resolution: (user_id, requested_company_id) must exist and be active
  → PrincipalContext.company_id  ← THE ONLY TENANT AUTHORITY FOR THIS REQUEST
  → tenant transaction with SET LOCAL app.current_company_id
```

Rules that are enforced by review and by tests:

1. **`company_id` from a request body, query string, path parameter or header is never used as
   authorization evidence** (`INV-02`, requirement 3). A path `company_id` is accepted only as a
   *selector* which is then re-validated against the caller's memberships on every request.
2. The `PrincipalContext` is passed **explicitly** into services; there is no thread-local or
   global "current company" that could leak between requests or between async tasks.
3. Queries against tenant tables are always built through `scope(queryset, ctx)`, which adds
   `company_id = ctx.company_id` **in addition to** RLS (defence in depth).
4. Object lookups are tenant-qualified: `get_object_or_404(Model, company_id=ctx.company_id, id=…)`.
   A cross-tenant id returns **404**, never 403 and never a validation error that reveals existence.
5. Foreign-key inputs from clients are validated against the tenant **and** the project scope
   before use, and the composite FKs remain the last line of defence.
6. Platform operators get no ambient access: tenant reads require an audited, reasoned, per-request
   elevation which is visible in the audit trail ([L §6](L-audit-logging.md)).

### 4.2 Workers and jobs

Jobs carry `{company_id, actor_user_id, request_id, project_id}` in their envelope. A worker task:

1. opens a transaction, sets the same `SET LOCAL` context, and therefore runs under RLS exactly like
   a web request;
2. re-verifies authorization for any action that has a business consequence (a stale job must not
   perform an action the actor lost rights to);
3. never iterates multiple companies inside a single transaction (one company = one transaction).

### 4.3 Caches, counters and derived data

| Store | Isolation rule |
|---|---|
| Redis cache | Every key is prefixed `c:{company_id}:`; project-level keys add `:{project_id}`. Permission caches are keyed `perm:{company_id}:{membership_id}` and invalidated on role change |
| Rate limiting | Keyed by `(company_id, user_id)` and by IP; a company cannot exhaust another company's login attempts budget |
| Materialized views | Company-scoped columns plus per-request filtering; no view exposes another tenant's rows |
| Exports / generated files | Stored under `tenants/{company_id}/…` in private object storage, served only through the authorizing download path ([M](M-file-storage-security.md)) |
| Search indexes | Tenant id is part of every index clause; search results are filtered by scope before ranking |

---

## 5. Layer 4 — Object storage

Per-tenant key prefixes (`tenants/<company_id>/<entity>/<yyyy>/<mm>/<uuid>.<ext>`),
per-tenant credentials scoped to its prefix for presigned operations, no anonymous access, no
bucket listing for tenants, and encryption at rest with a per-deployment key. Details and the
download authorization path: [M](M-file-storage-security.md).

---

## 6. Defence-in-depth summary

| # | Control | Bypassed if… | Consequence |
|---|---|---|---|
| 1 | Application scoping (`scope()`, tenant-qualified lookups) | a developer forgets | RLS still blocks |
| 2 | Composite FKs | never by data | cross-tenant rows cannot exist |
| 3 | RLS policies | a role has `BYPASSRLS` or policies are dropped | role model + CI lint + review |
| 4 | Tenant-context trigger on financial tables | never by data | writes without context are refused |
| 5 | Storage prefixes + authz-before-presign | URL sharing (short TTL, non-guessable keys) | object leakage is bounded to 5 minutes and is auditable |
| 6 | Tenant-isolation test suite (CI, on every PR) | never (fails the build) | regressions cannot merge |

---

## 7. Test strategy for isolation (mandatory, automated)

Implemented per [S §4](S-testing-strategy.md). Every PR must pass:

1. **Two-tenant fixture** seeded in every integration test session (Company A and Company B, each
   with branches, users, projects, contracts, BOQ, IPC, expenses, documents).
2. **Read isolation**: for every list/detail endpoint, authenticate as A and assert no id belonging
   to B is ever returned; then the mirror test.
3. **Write isolation**: attempt creates/updates with B's ids while authenticated as A; expect
   404/403 and assert **no row was created or modified**.
4. **Context-leak test**: run request A, then request B on the same pooled connection, and assert
   that no query in B's request observed A's context; additionally assert `reset_tenant_context()`
   ran.
5. **Missing-context test**: call each tenant-scoped selector without opening a tenant transaction
   and assert it raises/returns nothing — the fail-closed contract must be executable, not aspirational.
6. **RLS policy coverage test**: introspect `pg_class`/`pg_policy` and fail the build if any table
   with a `company_id` column lacks `relrowsecurity` + `relforcerowsecurity` or a policy.
7. **Job isolation test**: enqueue work for A, run the worker with B's context, assert the job is
   refused.

---

## 8. Failure modes we explicitly design for

| Scenario | Behaviour |
|---|---|
| Developer writes a raw query without a tenant filter | RLS returns nothing (fail-closed) rather than everything |
| Bug passes another tenant's UUID as a foreign key | Composite FK refuses the write |
| Session fixes the company once and never re-checks the membership | Membership revocation invalidates sessions/permission caches within the freshness window ([H §6](H-authentication-sessions.md)) and every request re-validates membership status |
| Cached permission object survives a role change | Cache keys are membership-scoped and explicitly invalidated on role/permission change; the authorization result is never cached across tenants |
| A worker processes jobs for many tenants | One transaction per tenant, context set per transaction, asserted by test |
| Support engineer "just checks" a customer's data | Break-glass requires an audited reason, is alerted to the owner, and cannot be enabled silently |

---

## 9. Path to physical separation (if ever required)

If a customer contractually requires isolation beyond logical separation, the migration path is
already prepared by the current design:

1. Every tenant's rows are reachable by `company_id`, with composite FKs and per-tenant object
   prefixes → a tenant can be extracted with a filtered `pg_dump`/logical replication plus an
   object-storage prefix copy.
2. Because the application never assumes "one database = one deployment shape", the extract can be
   loaded into a dedicated instance and the tenant's routing switched at the resolver level.
3. Audit chain continuity is preserved because checkpoints are per-company and exported off-site.

This is **not** a V1 deliverable; it is recorded so today's schema choices do not block it.
