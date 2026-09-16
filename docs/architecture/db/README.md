# Database Schema Specification (PostgreSQL 16)

This directory is the **normative schema specification** for Phase 1 migrations. The files are
plain SQL, ordered by dependency, and are the source of truth for table names, columns, types,
constraints, indexes, triggers, policies and grants.

> **These files are a specification, not a migration.** They are not wired into Django's migration
> graph, they contain no seed/business data, and they must not be executed against production as-is.
> Phase 1 converts them into migrations (Django `RunSQL` for the parts Django's ORM cannot express:
> RLS, triggers, generated columns, EXCLUDE constraints, partitions, materialized views).

## Files

| # | File | Contents |
|---|---|---|
| 00 | `00_extensions_and_helpers.sql` | extensions, `app`/`reporting`/`archive` schemas, tenant-context helpers, trigger helpers (tenant guard, immutability, no-delete, tree cycles), safe document numbering, audit hash helper, money rounding |
| 01 | `01_core_identity_access.sql` | reference data (currencies, units, regions, cities), companies, branches, numbering, tax rates, users/credentials/MFA, memberships, invitations, roles & permissions, sessions, login attempts, delegations |
| 02 | `02_partners_projects.sql` | clients/suppliers/subcontractors, contacts, projects, settings, project parties, milestones, status history, project members & project-scoped permissions |
| 03 | `03_contracts_boq.sql` | contracts, contract value ledger (append-only), BOQ, sections, items, item versions, revisions |
| 04 | `04_wbs_costcodes_budget.sql` | WBS nodes, cost codes, project cost-code selection, budgets, budget lines, budget transfers |
| 05 | `05_boq_import.sql` | transactional Excel import: batches, staged rows, validation issues, column-mapping templates |
| 06 | `06_variations.sql` | variation orders, lines, approval evidence, contract-value posting function |
| 07 | `07_ipc.sql` | IPCs, lines, deductions, additions, certification snapshots, certificates, status history |
| 08 | `08_costs_collections.sql` | expenses, allocations, cost commitments (schema-only), collections, allocations, receivables maintenance |
| 09 | `09_documents_approvals.sql` | documents, versions, upload sessions, links, approval workflows/steps/requests/actions, deferred FKs |
| 10 | `10_audit.sql` | partitioned append-only audit log, hash chain, checkpoints, verification function |
| 11 | `11_reporting_views.sql` | certified-position view, contract summary, forecast overrides, project financial position MV, cost-by-cost-code MV, aging, registers |
| 12 | `12_jobs_and_notifications.sql` | transactional outbox, job claiming, idempotency keys, notifications, preferences |
| 13 | `13_tenant_isolation_rls.sql` | RLS enable + **force** + policies for every tenant table, tenant-context helpers, `app.my_companies()` |
| 14 | `14_roles_and_grants.sql` | database roles, least-privilege grants, append-only enforcement, connection settings, CI lint assertions |

## Validation status (Phase 0 evidence)

The whole specification was executed against a real **PostgreSQL 16.2** instance during Phase 0:

| Check | Result |
|---|---|
| All 15 files execute with **zero errors** (in dependency order) | ✅ |
| Generated money columns (`amount = round(qty × rate, 2)`) | ✅ verified (`3.333333 × 12.3456` → `41.1520` vs float `41.1519958848`) |
| Composite tenant FKs reject cross-tenant references | ✅ `fk_contracts_client` refused a Company-B client on a Company-A contract |
| Tenant-context trigger refuses mismatched writes | ✅ `TENANT_MISMATCH` raised; `TENANT_CONTEXT_MISSING` raised with no context |
| **RLS as the runtime role** | ✅ A sees only A, B sees only B, **no context ⇒ 0 rows**, cross-tenant INSERT refused by `WITH CHECK` |
| Runtime role privileges | ✅ `app_rw` is not superuser, cannot bypass RLS, cannot create roles; UPDATE/DELETE denied on `audit_logs`, `contract_value_ledger`, `ipc_snapshots` |
| VO approval → contract value ledger | ✅ total derived from lines (`112,625.00`), posting idempotent (same ledger id twice), RCV `1,000,000 → 1,112,625` |
| Approved VO is frozen | ✅ `VO_FROZEN` |
| IPC previous/cumulative values cannot be client-supplied | ✅ `IPC_PREVIOUS_VALUES_INVALID` |
| Cross-project IPC line | ✅ refused by project-scoped FK `fk_ipc_lines_boq_item` |
| IPC arithmetic | ✅ gross 450,500.00 → retention 22,525.00 → advance 45,050.00 → net 382,925.00 → VAT 57,438.75 → total 440,363.75 |
| Forged VAT figure | ✅ refused by identity CHECK (`ck_ipcs_total_identity`) |
| Certified IPC header, lines and snapshot immutability | ✅ `IPC_FROZEN`, `IPC_LINES_FROZEN`, `IMMUTABLE_FIELD` |
| Tree-cycle prevention (WBS) | ✅ `TREE_CYCLE` |
| Deductions and additions frozen after certification | ✅ `IPC_LINES_FROZEN` on UPDATE, DELETE **and** INSERT after certification (three new guards added because the earlier version froze only the lines) |
| Partition-level tenant isolation | ✅ every partition of `audit_logs` carries its own enabled+forced policy, so a direct partition scan cannot cross tenants (`app.ensure_audit_partitions()` applies the same policy to future partitions) |
| **Executable CI schema lint** (6 assertions in file 14 §8) | ✅ passes on the migrated schema, and was **proved to fail** by sabotage (a temporary `GRANT UPDATE ON audit_logs TO app_rw` produced `SCHEMA_LINT_5: append-only table(s) writable by app_rw: audit_logs:UPDATE`) |
| Audit hash chain | ✅ 3 chained rows verify clean; a **silent superuser edit** of one row is detected (`row_hash mismatch`) |

Defects found and fixed *because* of this validation (they are the reason the specification is
trustworthy): a hard-coded parent-column name in the tree-cycle guard; `NEW` used on DELETE paths;
a cross-tenant polymorphic FK that was unsatisfiable; a generated column referencing another
generated column; two `PERFORM ... AS changed` freeze functions that could never fire; a missing
project-scoped parent key on `ipcs` and `collections`; a **vacuous immutability guard** caused by
PostgreSQL reporting `TG_ARGV` as `NULL` when a trigger has no arguments; an over-strict VO freeze
whitelist that blocked legitimate approvals; **`notifications` and `notification_preferences`
missing from the RLS list**; **`audit_logs` partitions without their own RLS policy** (PostgreSQL
does not inherit `ENABLE`/`FORCE` onto partitions); **three tables lacking a `company_id`-leading
index** (`access_delegations`, `budget_transfers`, `document_upload_sessions`); and **no freeze
guard on `ipc_deductions`/`ipc_additions`**, so retention or penalty lines could still be changed
after certification. Every one of those was found by executing the specification, not by reading it.

## Conventions that Phase 1 must preserve

1. `company_id` on every tenant table, composite FKs to `(company_id, id)` (or
   `(company_id, project_id, id)` for project-scoped parents). See [../E-database-design.md §6](../E-database-design.md).
2. Money is `numeric(20,4)`; the only rounding helper is `app.round_money`; **never** `real`/`double`.
3. Every mutable document is guarded by a freeze function; corrections are reversal + re-issue.
4. Every audited table is bound to `app.audit_row_change` in Phase 1; services additionally write
   semantic audit rows through `app.audit_append`.
5. `SET LOCAL` tenant context on every connection; `app.reset_tenant_context()` on pool release.
6. New tenant tables must be added to the RLS list in file 13 — the **executable** CI lint in
   file 14 §8 raises `SCHEMA_LINT_2` when a `company_id` table (or partition) has no enabled+forced
   RLS policy, `SCHEMA_LINT_6` when it has no `company_id`-leading index, `SCHEMA_LINT_3` when a
   composite FK has no matching unique key on its parent, and `SCHEMA_LINT_1` when a floating-point
   column appears on a financial table. Example:

   ```bash
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/14_roles_and_grants.sql   # last statement is the lint
   ```

## How to run it locally (developer convenience only)

```bash
# scratch database, spec only — never production
createdb spec_check
for f in docs/architecture/db/[0-9]*.sql; do psql -d spec_check -v ON_ERROR_STOP=1 -f "$f"; done
```

Contrib extensions are required: `citext`, `pg_trgm`, `btree_gist` (`pgcrypto` is **not** required).
