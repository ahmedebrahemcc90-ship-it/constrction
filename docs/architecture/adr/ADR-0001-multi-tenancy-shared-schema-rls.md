# ADR-0001 — Multi-tenancy: single database, shared schema, `company_id` + fail-closed row-level security

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Database Architect, Security Engineer
- **Related:** [F-tenant-isolation.md](../F-tenant-isolation.md), [E §6/§12](../E-database-design.md),
  [S §4](../S-testing-strategy.md), [ADR-0018](ADR-0018-composite-foreign-keys.md), db/13, db/14

## Context

The product is a multi-tenant SaaS for Saudi construction companies (realistically: tens to low
hundreds of tenants, each with a handful to a few dozen projects). Requirements demand:

* an absolute rule that Company A can never read or write Company B's data (security principle 2);
* tenant identity that is *not* trusted from the client (principle 3);
* project-level authorization inside a tenant (principle 6);
* a single small operations team on a single VPS, with migrations, backups and reporting that an
  operator can reason about at 03:00;
* commercial reporting that spans a company's projects, and occasionally cross-project analysis;
* the ability to onboard and offboard a tenant without touching other tenants' data.

## Decision

**One PostgreSQL database, one schema, `company_id` on every tenant-owned table, PostgreSQL
row-level security (RLS) enabled *and forced* as a database-level backstop, with the tenant resolved
server-side per request and injected as a transaction-local GUC.**

Specifically:

1. Every tenant-owned table carries `company_id uuid NOT NULL`, is indexed with `company_id` leading,
   and its uniqueness constraints are tenant-qualified.
2. RLS is `ENABLE`d **and `FORCE`d** on every tenant table with one policy
   `company_id = app.current_company_id()`; the helper returns `NULL` when the GUC is unset, so the
   predicate is `NULL` for every row and the system **fails closed** (no rows visible, no rows
   writable).
3. The transaction sets `SET LOCAL app.current_company_id = …`; `SET LOCAL` cannot leak to later
   transactions on the same pooled connection, and `app.reset_tenant_context()` runs on release as a
   second guard.
4. The runtime database role (`app_rw`) is `NOSUPERUSER NOBYPASSRLS NOCREATEROLE`, so the policy
   cannot be bypassed by the application's own credentials.
5. The application *also* filters by tenant on every query (`scope()`), because RLS is a backstop,
   not the primary authorization mechanism ([G](../G-authorization-rbac.md)); authentication,
   authorization and project scoping all happen in the application.
6. `companies` itself is protected by a self-policy, and the company switcher reads through
   `app.my_companies()` (SECURITY DEFINER, membership-joined, pinned `search_path`).

## Consequences

**Positive**

* Tenant isolation is enforced in three independent places (application scoping, composite FKs,
  RLS), so a single coding mistake does not become a data breach. This was **verified in Phase 0**:
  running as `app_rw`, tenant A saw exactly its own project, tenant B saw exactly its own project,
  no context returned zero rows, and inserting a foreign-tenant row raised an RLS violation.
* One migration path, one backup/restore path, one set of statistics; capacity planning and index
  maintenance stay tractable for a small team.
* Cross-project and cross-entity reporting inside a tenant is a plain SQL join.
* Early tenants can be provisioned in seconds.

**Negative / costs to manage**

* RLS adds a predicate to every tenant query (measured cost is modest; benchmarked in
  [S §9](../S-testing-strategy.md)) and makes `EXPLAIN` plans slightly harder to read.
* Noisy neighbours share one database: a runaway query or import in one tenant can affect others →
  mitigated by `statement_timeout`, `idle_in_transaction_session_timeout`, per-tenant job rate
  limiting, and connection pooling discipline.
* A physical restore is all-or-nothing (one tenant cannot be restored in isolation from a single
  backup) → mitigated by per-tenant logical exports, per-company audit checkpoints, and the
  documented extraction path in [F §9](../F-tenant-isolation.md).
* A bug in the tenant-context plumbing is a *systemic* risk → mitigated by `SET LOCAL` semantics,
  fail-closed defaults, a reset on connection release, and a blocking isolation test suite.

**Follow-ups**

* Add a CI assertion that every table with a `company_id` column has RLS enabled *and forced* plus at
  least one policy (implemented in db/14 §8).
* Add a scheduled job that verifies no connection is executing tenant queries without context
  (instrumented in [Q](../Q-observability.md)).
* Revisit if a customer contractually demands physical separation: the schema is already designed so
  a tenant can be extracted by `company_id` ([F §9](../F-tenant-isolation.md)).

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Database per tenant** | Strongest isolation, but N migration targets, N backup/restore paths, connection-pool fragmentation, and no cross-tenant operational view; the small ops team becomes the bottleneck. Retained as a future option for a contractual requirement, not for V1 |
| **Schema per tenant** | Similar operational cost to database-per-tenant with weaker separation guarantees (`search_path` mistakes are easy), while RLS would still be needed for shared reference data — paying both costs for one benefit |
| **Application-level filtering only** (no RLS) | A single forgotten `WHERE company_id = …` becomes a cross-tenant breach; after a leak, "we are careful" is not an answer the owner can give a customer. Rejected as the *sole* control; accepted as *one* of the layers |
| **Separate databases + a routing layer per request** | Adds a component whose failure mode is "route to the wrong database" — the same class of bug as a missing tenant filter but harder to test |
| **Tenant id in a JWT claim treated as authority** | Violates principle 3 (never trust client-provided tenant identity) and makes revocation hard; tenant comes from the session's server-side membership instead |

## How this will be verified

1. **Phase 0 (done):** two seeded tenants, runtime role `app_rw`, execution of the read/write/
   no-context isolation suite; confirmed zero rows without context, cross-tenant INSERT refused, and
   `app_rw` attributes `is_superuser=f`, `can_bypass_rls=f`.
2. Automated two-tenant isolation suite on every PR ([S §4](../S-testing-strategy.md)), executed as
   `app_rw` — never as a superuser, because a superuser would pass a broken suite.
3. CI schema lint (RLS + policy coverage; no role with `BYPASSRLS`).
4. Quarterly review of the RLS policy list against `information_schema.columns` for newly added
   tables.
