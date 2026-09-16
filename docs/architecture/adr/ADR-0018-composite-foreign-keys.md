# ADR-0018 — Composite tenant-aware foreign keys `(company_id, parent_id)` instead of single-column FKs

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Database Architect, Security Engineer, Owner
- **Related:** [E §6](../E-database-design.md), [F §2](../F-tenant-isolation.md),
  [ADR-0001](ADR-0001-multi-tenancy-shared-schema-rls.md),
  [ADR-0019](ADR-0019-project-scoped-composite-foreign-keys.md), every file in db/

## Context

With a shared-schema design ([ADR-0001](ADR-0001-multi-tenancy-shared-schema-rls.md)), the schema is
the last place where a cross-tenant mistake can be stopped. The dangerous pattern is obvious once
stated: a normalised foreign key such as `contracts.client_id → clients(id)` permits a contract
belonging to Company A to reference a client belonging to Company B. Nothing about the *reference*
looks wrong; it becomes a cross-tenant data path as soon as a report joins them, and a joined report
happily shows another company's client name, VAT number and contact details.

Application-level checks ("validate that the client belongs to the calling company") are necessary but
insufficient: they exist in many code paths (API, import, job, admin screen, data fix), and one
missed path is a breach. Phase 0 demonstrated the failure at the database level too — an
application-level guard that relied on project state could not see what a plain FK would have to.

## Decision

**Every reference between tenant-owned entities is a composite foreign key that carries the tenant,
and every tenant table exposes a unique key on `(company_id, id)` to be a valid parent.**

1. Children store `company_id` and reference the parent with `FOREIGN KEY (company_id, parent_id)
   REFERENCES parent (company_id, id)`.
2. Every tenant table has a redundant-but-required `UNIQUE (company_id, id)` constraint so it can act
   as a composite parent (the primary key alone is not sufficient for a composite FK).
3. Unique constraints on business keys are tenant-qualified: `(company_id, code)`,
   `(company_id, contract_id, vo_number)`.
4. Deep hierarchies extend the pattern: a project-owned child references
   `(company_id, project_id, id)` ([ADR-0019](ADR-0019-project-scoped-composite-foreign-keys.md)).
5. The application *still* validates tenant and project scope before writing and uses tenant-filtered
   lookups (404 for foreign ids) — the composite FK is the backstop, not the user-facing behaviour.
6. Polymorphic relationships ("this link points to a document, an IPC, or an expense") are modelled as
   **one nullable typed FK column per possible parent**, each with a real composite FK, plus
   `CHECK (num_nonnulls(...) = 1)` and a stored discriminator — never as a single id column, which
   would have no enforceable referential integrity.

## Consequences

**Positive**

* A cross-tenant reference is **impossible by construction**: the row cannot be inserted, whatever the
  code path. This was verified in Phase 0: a Company A contract pointing at a Company B client was
  refused with an `fk_contracts_client` violation.
* The guarantee survives data fixes, imports, background jobs, SQL run by hand and future services —
  none of which need to remember a rule.
* The modelling is self-documenting: seeing `(company_id, x_id)` in a schema tells a reader that the
  entity is tenant-owned and tells the reviewer exactly what the integrity guarantee is.
* It also catches a class of *application* bug that is easy to miss in review: a service that
  resolves the wrong tenant for a lookup fails at write time instead of persisting a corrupt link.

**Negative / costs to manage**

* Every parent needs the extra `UNIQUE (company_id, id)` index — a modest storage and write cost, and
  it must be maintained whenever a new table becomes a parent (CI asserts it, see db/14 §8).
* Join predicates and generated SQL are slightly more verbose; the ORM needs explicit composite key
  definitions (or raw SQL for a few constraints), so Phase 1 must add a schema-conformance test to
  prevent drift.
* Composite FKs cannot express "the parent may live in another company" — by design. Shared reference
  data (currencies, units, permissions) is deliberately global and is not tenant-composed.
* Introducing a composite FK to an existing table requires a migration to add the parent's unique key
  first; the ordering must be respected in Phase 1 migrations.

**Follow-ups**

* CI lint: for every composite FK, assert the referenced unique key exists (implemented as a schema
  assertion in db/14 §8).
* Phase 1 migration generator must emit composite keys consistently; a template plus a test prevents
  a developer from adding a single-column FK to a tenant table.
* A short developer note in the coding standards: "if the table has `company_id`, the FK must carry
  it".

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Single-column FKs + application validation** | Works until one code path forgets; the failure is silent, cross-tenant, and only detectable by a test nobody may write. Not acceptable as the only control |
| **RLS alone** | RLS filters *reads* and constrains tenant ownership of a row's own `company_id`; it cannot prevent a row from *referencing* another tenant's row whose `company_id` is stored elsewhere. The composite FK closes exactly that hole |
| **Triggers that validate the referenced row's tenant** | Works in principle, but adds runtime work per write, is easy to forget on new tables, and cannot be verified as a structural property; a trigger was tried for cross-project coherence during Phase 0 and abandoned in favour of structural composite keys |
| **Row-level "tenant_id in every column of every index"** (over-engineering all indexes with tenant) | Added index bloat without closing a new hole once the FK carries the tenant and indexes lead with `company_id` |
| **Separate database/schema per tenant to make cross-tenant FKs impossible** | Rejected earlier for operational reasons ([ADR-0001](ADR-0001-multi-tenancy-shared-schema-rls.md)); this ADR achieves the same *structural* impossibility inside one schema |
| **Polymorphic single-column parent id (no FK)** | Referential integrity cannot be enforced at all — a link could point at a deleted or foreign row, and the orphan would be invisible until a report joined it |

## How this will be verified

1. **Phase 0 (done):** cross-tenant contract → client insert refused by the composite FK.
2. CI schema assertion: every table with `company_id` has `UNIQUE (company_id, id)` when it is
   referenced by a composite FK; every foreign key on a tenant table that points at a tenant table
   includes `company_id`.
3. Isolation test suite: attempting to create a child row with a foreign parent id fails at the
   database level even when the service layer is bypassed (tested with a raw insert as `app_rw`).
4. Migration review checklist: no new single-column FK between tenant tables.
