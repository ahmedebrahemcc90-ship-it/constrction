# E. Proposed PostgreSQL Entities and Relationships

**Companion artifacts:** the normative schema specification is in [`db/`](db) (plain SQL, PostgreSQL
16). Those files are a *specification for Phase 1 migrations*, not migrations to run blindly, and
they are the source of truth for column names, types, constraints and indexes.

---

## 1. Modelling conventions

| Topic | Convention | Rationale |
|---|---|---|
| Primary keys | `uuid` (UUIDv7 generated app-side, `gen_random_uuid()` fallback) | Non-enumerable in URLs (anti-IDOR), globally unique for merges/exports, index-friendly with v7 |
| Tenant key | `company_id uuid NOT NULL` on **every** tenant-owned table | RLS anchor, composite FK anchor, index prefix |
| Tenant integrity | All parent references use **composite FKs** `(company_id, parent_id) → parent(company_id, id)` | A cross-tenant reference becomes *impossible*, not merely rejected |
| Uniqueness with tenant | Unique constraints are always `(company_id, …)` | Codes/numbers repeat across tenants |
| Money | `numeric(20,4)`, exposed as `numeric(20,2)` on document-facing columns where the business rounds to 2 dp | Exact decimal arithmetic; 4 dp headroom for unit-rate division (see [I §2](I-financial-architecture.md)) |
| Quantity | `numeric(18,6)` | BOQ units (m³, kg, ton) need precision |
| Rate | `numeric(18,4)` | Rate precision is commercially sensitive |
| Percentage | `numeric(9,4)` + `CHECK (… BETWEEN 0 AND 100)` | |
| VAT | `vat_rate_bp integer` (basis points) snapshotted per line/document | Historical VAT reproducibility, no float |
| Timestamps | `created_at/updated_at timestamptz NOT NULL DEFAULT now()`; business events also carry `*_at` timestamptz | UTC in DB, `Asia/Riyadh` at display |
| Business dates | `date` | Ledger/report period semantics |
| Soft delete | `deleted_at timestamptz NULL` + partial unique indexes (`WHERE deleted_at IS NULL`) | Master data is archived, never destroyed while referenced |
| Enumerations | `text` + `CHECK (col IN (…))` for states we control tightly; lookup tables for extensible lists | Enum states must never silently change; `CHECK` documents them in the schema |
| Free-form metadata | `jsonb` (never for money; validated by schema) | Extensibility without schema churn |
| Optimistic locking | `version integer NOT NULL DEFAULT 1` on mutable documents | Prevents lost updates ([I §6](I-financial-architecture.md)) |
| Audit columns | `created_by`, `updated_by` → `users(id)`; plus `certified_by`, `approved_by`, `posted_by` where meaningful | Stable global actor identity |
| Naming | `snake_case`, plural tables, `fk_`, `ck_`, `uq_`, `idx_`, `trg_` prefixes; index names ≤ 63 chars | Operability |
| Schemas | `public` for tenant data; `app` for helper functions/procedures; `reporting` for views/MVs; `archive` for pruned audit partitions | Simpler grants, clearer blast radius |
| Comment discipline | Every table and non-obvious column carries `COMMENT ON` | The DB is the durable documentation |

---

## 2. Entity inventory by domain

### 2.1 Core & tenancy
`schema_version` · `companies` · `company_settings` · `branches` · `number_series` · `tax_rates` ·
`currencies` · `units_of_measure` · `regions` · `cities` · `audit_checkpoints`

### 2.2 Identity & access
`users` · `user_credentials` · `user_mfa_totp` · `user_mfa_recovery_codes` · `sessions` ·
`login_attempts` · `password_reset_tokens` · `invitations` · `memberships` ·
`membership_invitations` · `roles` · `permissions` · `role_permissions` · `membership_roles` ·
`project_members` · `project_member_permissions` · `user_branch_scopes` · `access_delegations`

### 2.3 Partners
`clients` · `suppliers` · `subcontractors` · `party_contacts` · `project_parties`
(unified `parties` view for search)

### 2.4 Projects
`projects` · `project_settings` · `project_status_history` · `project_milestones`

### 2.5 Contracts
`contracts` · `contract_lines` · `contract_milestones` · `contract_value_ledger` ·
`contract_advance_terms` · `contract_retention_terms`

### 2.6 BOQ
`boqs` · `boq_sections` · `boq_items` · `boq_item_versions` (revision history) · `boq_revisions`

### 2.7 WBS / Cost codes / Budget
`wbs_nodes` · `cost_codes` · `project_cost_codes` · `budgets` · `budget_lines` ·
`budget_transfers` · `budget_versions`

### 2.8 Import pipeline
`import_batches` · `import_rows` · `import_validation_issues` · `import_column_mappings`

### 2.9 Variations
`variation_orders` · `variation_order_lines` · `variation_order_approvals`

### 2.10 IPC
`ipcs` · `ipc_lines` · `ipc_deductions` · `ipc_additions` · `ipc_snapshots` · `ipc_certificates`
(generated PDF descriptors) · `ipc_status_history`

### 2.11 Cost & billing
`expenses` · `expense_allocations` · `expense_status_history` · `cost_commitments` (V1
schema-ready, module not implemented) · `collections` · `collection_allocations`

### 2.12 Files, approvals, audit, jobs
`documents` · `document_versions` · `document_links` · `document_upload_sessions` ·
`approval_workflows` · `approval_workflow_steps` · `approval_requests` · `approval_actions` ·
`audit_logs` · `audit_log_partitions` · `job_outbox` · `job_idempotency_keys` ·
`notification_preferences` · `notifications`

### 2.13 Reporting
Materialized views: `mv_project_financial_position` · `mv_boq_item_certified` ·
`mv_project_cost_by_costcode` · `mv_contract_value_summary` · `mv_project_cashflow` ·
`mv_company_dashboard`; plain views for drill-down: `v_ipc_receivable_aging`,
`v_expense_detail`, `v_variation_register`, `v_boq_vs_budget`.

---

## 3. Core relationship specification (the requested explicit map)

| # | From → To | Cardinality | FK columns (composite unless noted) | Delete rule |
|---|---|---|---|---|
| 1 | `branches` → `companies` | n:1 | `(company_id) → companies(id)` | RESTRICT |
| 2 | `memberships` → `companies` | n:1 | `(company_id)` | RESTRICT |
| 3 | `memberships` → `users` | n:1 | `user_id → users(id)` (global) | RESTRICT |
| 4 | `membership_roles` → `memberships` | n:1 | `(company_id, membership_id)` | CASCADE |
| 5 | `membership_roles` → `roles` | n:1 | `(company_id, role_id)` | RESTRICT |
| 6 | `role_permissions` → `roles` | n:1 | `(company_id, role_id)` | CASCADE |
| 7 | `role_permissions` → `permissions` | n:1 | `permission_code → permissions(code)` (global) | RESTRICT |
| 8 | `user_branch_scopes` → `memberships` | n:1 | `(company_id, membership_id)` | CASCADE |
| 9 | `user_branch_scopes` → `branches` | n:1 | `(company_id, branch_id)` | CASCADE |
| 10 | `projects` → `companies` | n:1 | `(company_id)` | RESTRICT |
| 11 | `projects` → `branches` | n:1 (nullable) | `(company_id, branch_id)` | RESTRICT |
| 12 | `project_members` → `projects` | n:1 | `(company_id, project_id)` | CASCADE |
| 13 | `project_members` → `memberships` | n:1 | `(company_id, membership_id)` | CASCADE |
| 14 | `project_member_permissions` → `project_members` | n:1 | `(company_id, project_member_id)` | CASCADE |
| 15 | `clients` / `suppliers` / `subcontractors` → `companies` | n:1 | `(company_id)` | RESTRICT |
| 16 | `project_parties` → `projects` + party | n:1 | `(company_id, project_id)`, `(company_id, client_id/supplier_id/subcontractor_id)` | CASCADE |
| 17 | `contracts` → `projects` | n:1 | `(company_id, project_id)` | RESTRICT |
| 18 | `contracts` → `clients` | n:1 | `(company_id, client_id)` | RESTRICT |
| 19 | `boqs` → `contracts` | n:1 | `(company_id, contract_id)` | RESTRICT |
| 20 | `boq_sections` → `boqs` | n:1 | `(company_id, boq_id)` | CASCADE (draft only) |
| 21 | `boq_sections` → `boq_sections` (parent) | n:1 | `(company_id, parent_section_id)` | RESTRICT |
| 22 | `boq_items` → `boq_sections` | n:1 | `(company_id, boq_section_id)` | RESTRICT |
| 23 | `boq_items` → `boq_items` (parent/roll-up) | n:1 (nullable) | `(company_id, parent_item_id)` | RESTRICT |
| 24 | `boq_item_versions` → `boq_items` | n:1 | `(company_id, boq_item_id)` | CASCADE (history) |
| 25 | `wbs_nodes` → `projects` | n:1 | `(company_id, project_id)` | RESTRICT |
| 26 | `wbs_nodes` → `wbs_nodes` (parent) | n:1 | `(company_id, parent_id)` | RESTRICT |
| 27 | `cost_codes` → `companies` | n:1 | `(company_id)` | RESTRICT |
| 28 | `cost_codes` → `cost_codes` (parent) | n:1 | `(company_id, parent_id)` | RESTRICT |
| 29 | `budgets` → `projects` | n:1 | `(company_id, project_id)` | RESTRICT |
| 30 | `budget_lines` → `budgets` | n:1 | `(company_id, budget_id)` | CASCADE (draft only) |
| 31 | `budget_lines` → `cost_codes` | n:1 | `(company_id, cost_code_id)` | RESTRICT |
| 32 | `budget_lines` → `wbs_nodes` | n:1 (nullable) | `(company_id, wbs_node_id)` | RESTRICT |
| 33 | `budget_lines` → `boq_items` | n:1 (nullable) | `(company_id, boq_item_id)` | RESTRICT |
| 34 | `variation_orders` → `contracts` | n:1 | `(company_id, contract_id)` | RESTRICT |
| 35 | `variation_order_lines` → `variation_orders` | n:1 | `(company_id, variation_order_id)` | CASCADE (draft only) |
| 36 | `variation_order_lines` → `boq_items` | n:1 (nullable) | `(company_id, boq_item_id)` | RESTRICT |
| 37 | `variation_order_approvals` → `variation_orders` | n:1 | `(company_id, variation_order_id)` | RESTRICT (immutable) |
| 38 | `contract_value_ledger` → `contracts` | n:1 | `(company_id, contract_id)` | RESTRICT |
| 39 | `contract_value_ledger` → source (`variation_orders`/`contracts`) | n:1 | `(company_id, source_id)` unique per source+type | RESTRICT |
| 40 | `ipcs` → `contracts` | n:1 | `(company_id, contract_id)` | RESTRICT |
| 41 | `ipc_lines` → `ipcs` | n:1 | `(company_id, ipc_id)` | CASCADE (draft only) |
| 42 | `ipc_lines` → `boq_items` | n:1 | `(company_id, boq_item_id)` | RESTRICT |
| 43 | `ipc_deductions` / `ipc_additions` → `ipcs` | n:1 | `(company_id, ipc_id)` | CASCADE (draft only) |
| 44 | `ipc_snapshots` → `ipcs` | 1:1 | `(company_id, ipc_id)` unique | RESTRICT (immutable) |
| 45 | `expenses` → `projects` | n:1 | `(company_id, project_id)` | RESTRICT |
| 46 | `expenses` → `cost_codes` | n:1 | `(company_id, cost_code_id)` | RESTRICT |
| 47 | `expenses` → `wbs_nodes` / `boq_items` (nullable) | n:1 | composite | RESTRICT |
| 48 | `expenses` → `suppliers`/`subcontractors` (nullable) | n:1 | composite | RESTRICT |
| 49 | `expense_allocations` → `expenses` | n:1 | `(company_id, expense_id)` | CASCADE (draft only) |
| 50 | `collections` → `contracts` | n:1 | `(company_id, contract_id)` | RESTRICT |
| 51 | `collections` → `clients` | n:1 | `(company_id, client_id)` | RESTRICT |
| 52 | `collection_allocations` → `collections` | n:1 | `(company_id, collection_id)` | CASCADE (draft only) |
| 53 | `collection_allocations` → `ipcs` (nullable, advance/unapplied) | n:1 | `(company_id, ipc_id)` | RESTRICT |
| 54 | `documents` → `companies` | n:1 | `(company_id)` | RESTRICT |
| 55 | `document_versions` → `documents` | n:1 | `(company_id, document_id)` | CASCADE (file retained per policy) |
| 56 | `document_links` → `documents` + typed entity | n:1 each | `(company_id, document_id)` + exactly one `(company_id, <entity>_id)` | CASCADE on document delete |
| 57 | `approval_requests` → `approval_workflows` | n:1 | `(company_id, approval_workflow_id)` | RESTRICT |
| 58 | `approval_requests` → document (typed) | n:1 | `(company_id, <entity>_id)` exactly one | RESTRICT |
| 59 | `approval_actions` → `approval_requests` | n:1 | `(company_id, approval_request_id)` | RESTRICT (immutable) |
| 60 | `audit_logs` → `companies` | n:1 | `(company_id)` | RESTRICT (append-only) |
| 61 | `audit_logs` → `users` | n:1 (nullable) | `actor_user_id` | SET NULL not permitted — actor retained as `uuid` without FK to preserve history if a user row is ever anonymised (see [L §6](L-audit-logging.md)) |

**Explicit "Project" hub note:** `Project` is referenced by `ProjectMember`, `Contract`, `WBS`,
`Budget`, `Expense`, `Document` (via link), and indirectly (through `Contract`/`BOQ`) by
`VariationOrder`, `IPC`, `Collection`. Project scope is therefore *derivable* for every financial
document; the authorization layer must derive and enforce it rather than trusting a `project_id`
supplied by the client ([G §4](G-authorization-rbac.md)).

---

## 4. Index strategy

| Pattern | Index | Why |
|---|---|---|
| Tenant scans | `(company_id, created_at DESC)` on all document tables | Every list is tenant-filtered |
| Document lookups | `(company_id, number)` UNIQUE | Human document numbers |
| Project timelines | `(company_id, project_id, status, document_date DESC)` | Project dashboards |
| BOQ ordering | `(company_id, boq_id, sort_order)` and `(company_id, boq_section_id, sort_order)` | Tree rendering without client sorting |
| Roll-ups | `(company_id, contract_id, status)` on `ipcs`; `(company_id, project_id, cost_code_id)` on `expenses` | Aggregations |
| Certified history | `(company_id, contract_id, boq_item_id, period_to)` on certified `ipc_lines` | "Previous cumulative as of date" |
| Trees | `(company_id, parent_id)`, plus `lft/rgt` or `path` for WBS/cost-code depth queries | Cycle-safe traversal, subtree sums |
| Partial indexes | `WHERE deleted_at IS NULL`, `WHERE status IN ('submitted','under_review')` | Smaller hot indexes |
| Foreign keys | Index the FK columns; composite FK children get `(company_id, fk_col)` indexes | Lock contention and plan quality |
| Search | `pg_trgm` GIN on description/name columns (tenant-prefixed) | Fast partial text search |
| JSONB | GIN only where genuinely queried (metadata), never for financial values | Cost control |
| Uniqueness under soft delete | `UNIQUE (company_id, code) WHERE deleted_at IS NULL` | Codes reusable only after archive |

**Index anti-pattern to avoid:** indexing `company_id` alone (already covered by composites) and
`ORDER BY` on unindexed `jsonb`.

---

## 5. Constraint inventory (what the database itself refuses to allow)

| Class | Examples |
|---|---|
| Positive-value guards | `CHECK (quantity > 0)`, `CHECK (unit_rate >= 0)`, `CHECK (amount >= 0)` where a negative must use an explicit credit document |
| Non-negative balances | `CHECK (outstanding_amount >= 0)`, `CHECK (recovered_amount <= advance_amount)` |
| Arithmetic identity | Generated columns for `line_amount`, `cumulative_quantity`, `cumulative_amount`; header totals validated by trigger/`CASE`-checked invariant or derived in views |
| Parental status coherence | `CHECK (status IN ('draft','submitted','under_review','approved','rejected','cancelled'))` + transition triggers |
| Cross-entity coherence | Composite FKs; project/company equality for WBS/CostCode/BOQ references (via composite FK to project-scoped tables and a trigger asserting `project_id` equality between sibling references) |
| Tree integrity | `CHECK (parent_id <> id)`, cycle prevention trigger with recursive CTE, `CHECK (path <> '')` |
| Period integrity | `CHECK (period_to > period_from)`; EXCLUDE constraint (GiST + `btree_gist`) preventing overlapping non-cancelled IPC periods per contract |
| Exactly-one relationships | `CHECK (num_nonnulls(a,b,c) = 1)` for polymorphic link/approval tables |
| Immutability | Triggers blocking updates to financial fields when status ∉ editable states; `REVOKE UPDATE` on audit tables |
| Snapshot completeness | `CHECK` that certification snapshot columns are non-null whenever `status ∈ ('certified','approved','posted',…)` |
| Money shape | `CHECK (currency_code ~ '^[A-Z]{3}$')`, `CHECK (vat_rate_bp BETWEEN 0 AND 10000)` |
| Identifiers | `CHECK (vat_number ~ '^3[0-9]{13}3$')` *(format-only sanity check, not a government validation)* |

---

## 6. Why composite foreign keys (the single most important schema decision)

With a plain `REFERENCES boq_items(id)`, a malicious or buggy request can set
`company_id = A` on an `ipc_line` while pointing `boq_item_id` at Company B's item. Application code
*may* catch it; the database *cannot* rely on that. With a composite FK the reference is only
valid when both `company_id` **and** the parent id match the parent's own row, so the row simply
cannot be written. This turns ~40 rules from "validated in code, hopefully" into "structurally
impossible". Cost: a redundant `UNIQUE (company_id, id)` per parent table (cheap, and it doubles as
a useful index). See [ADR-0018](adr/ADR-0018-composite-foreign-keys.md).

Pattern applied to hierarchical and cross-module references, including the self-referencing
(`parent_id`) and polymorphic (`document_links`, `approval_requests`) cases.

---

## 7. Immutability, snapshots and historical reproducibility

| Table | Immutable after | Snapshot columns kept |
|---|---|---|
| `boq_items` | BOQ status > `draft` (then via `boq_revisions`/`boq_item_versions`) | full prior row in `boq_item_versions` |
| `variation_orders` | `approved`/`rejected` | approval evidence, contract-value eligibility |
| `contract_value_ledger` | posting | source document reference, amount, effective date, entry type |
| `ipc_lines` | `certified` | `certified_rate`, `previous_cumulative_quantity`, `previous_cumulative_amount`, `boq_revision_id`, `retention_pct`, `vat_rate_bp` |
| `ipc_snapshots` | creation (1:1 with IPC) | contract terms in force at certification (retention %, caps, advance %/schedule, VAT, currency, BQ revision) |
| `expenses` | `posted` | allocation rows frozen |
| `collections` | `posted` | allocation rows frozen |
| `audit_logs` | always | before/after JSONB, hash chain |
| `approval_actions` | always | actor, role, comment, timestamp, IP, request id |

**Correction path:** reverse (negating document, linked via `reverses_id`) → new corrected document.
No `certified`/`posted` row's financial columns are ever updated in place; the only allowed mutations
are lifecycle transitions (`status`, `*_at`, `*_by`).

---

## 8. Partitioning & retention

| Table | Strategy | Retention |
|---|---|---|
| `audit_logs` | RANGE by `created_at` month (declarative), partitions created ahead by a scheduler job | ≥ 7 years (owner confirm, D-06); archived partitions moved to `archive` schema and exported encrypted |
| `job_outbox` | RANGE by `created_at` week, prune after 30 days | Operational only |
| `import_rows` | kept per batch; prune batches > 12 months old after archival to object storage | 12 months |
| `login_attempts` | prune > 90 days | Operational/security |
| Everything else | not partitioned in V1 (sizing assumptions in [C §7](C-application-architecture.md)); candidate later: `expenses`, `ipc_lines` | Per policy |

---

## 9. Migration strategy

- Django migrations own DDL; **raw SQL is used only** for RLS policies, grants, triggers, functions,
  generated columns, EXCLUDE constraints, partitions and materialized views (`RunSQL`/`SeparateDatabaseAndState`).
- Every migration is reviewed against a checklist: *does it lock a hot table? does it rewrite a
  table (adding a default, changing type)? does it break RLS? does it need `CONCURRENTLY` outside a
  transaction? is there a forward-only path with a tested restore?*
- Data migrations for financial data are forbidden without an explicit ADR and a rehearsed
  restore-rollback; historical amounts are never recalculated by a migration.
- `SET lock_timeout` and `statement_timeout` are applied in migration sessions to prevent a
  deployment from blocking production traffic.
- A **schema lint test** in CI asserts: no `real`/`double precision` on financial tables, every
  tenant table has `company_id` + RLS enabled + FORCE, every tenant table has an RLS policy, and no
  tenant table is missing its `(company_id, id)` unique constraint when referenced by a composite FK.

---

## 10. Seed / reference data (V1)

`permissions` (the full catalogue in [G §3](G-authorization-rbac.md)) · system role templates
(Owner, Company Admin, Finance Manager, Project Manager, QS/Engineer, Accountant, Storekeeper,
Auditor, Viewer) · `currencies` (SAR + a small ISO set) · `units_of_measure` (bilingual) ·
`regions`/`cities` (Saudi) · default `approval_workflows` (VO, IPC, Budget, Expense) ·
`tax_rates` starting at 15% standard VAT effective-dated, editable by the owner (VAT is
**configurable**, and rate changes are additive/effective-dated, never applied retroactively).

---

## 11. Detailed DDL

See [`db/`](db) — split by domain, with the same ordering as [§2](#2-entity-inventory-by-domain):

| File | Contents |
|---|---|
| [`db/00_extensions_and_helpers.sql`](db/00_extensions_and_helpers.sql) | extensions, `app` schema, helper functions (tenant context, immutability, cycles, hash chain, numbering) |
| [`db/01_core_identity_access.sql`](db/01_core_identity_access.sql) | companies, branches, settings, numbering, tax, users, sessions, memberships, roles, permissions, project members |
| [`db/02_partners_projects.sql`](db/02_partners_projects.sql) | clients/suppliers/subcontractors, project parties, projects, milestones, status history |
| [`db/03_contracts_boq.sql`](db/03_contracts_boq.sql) | contracts + terms, contract value ledger, BOQ, sections, items, revisions/versions |
| [`db/04_wbs_costcodes_budget.sql`](db/04_wbs_costcodes_budget.sql) | WBS nodes, cost codes, project cost-code selection, budgets, lines, transfers |
| [`db/05_boq_import.sql`](db/05_boq_import.sql) | import batches, rows, issues, column mappings (transactional Excel import) |
| [`db/06_variations.sql`](db/06_variations.sql) | variation orders, lines, approval evidence |
| [`db/07_ipc.sql`](db/07_ipc.sql) | IPCs, lines, deductions/additions, certification snapshots, status history |
| [`db/08_costs_collections.sql`](db/08_costs_collections.sql) | expenses, allocations, commitments (schema-only), collections, allocations |
| [`db/09_documents_approvals.sql`](db/09_documents_approvals.sql) | documents, versions, links, upload sessions, approval workflows/requests/actions |
| [`db/10_audit.sql`](db/10_audit.sql) | audit_logs (partitioned), hash chain, checkpoints, verification |
| [`db/11_reporting_views.sql`](db/11_reporting_views.sql) | project financial position, cost by cost code, contract summary, aging, registers |
| [`db/12_jobs_and_notifications.sql`](db/12_jobs_and_notifications.sql) | transactional outbox, job claiming, idempotency keys, notifications, preferences |
| [`db/13_tenant_isolation_rls.sql`](db/13_tenant_isolation_rls.sql) | RLS enable/force + policies for every tenant table, context helpers, financial guard triggers |
| [`db/14_roles_and_grants.sql`](db/14_roles_and_grants.sql) | DB roles, least-privilege grants, append-only enforcement, connection settings, CI lint assertions |

---

## 12. Tenant-ownership classification (which tables are tenant-scoped and which are global)

This is the authoritative classification that [F §2](F-tenant-isolation.md), [D](D-domain-model.md)
and [security-checklist.md](security-checklist.md) §1.1 refer to. It is enforced mechanically: the
RLS installer in [`db/13_tenant_isolation_rls.sql`](db/13_tenant_isolation_rls.sql) carries the
tenant table list, and the executable lint in [`db/14_roles_and_grants.sql`](db/14_roles_and_grants.sql)
§8 fails the build if a table with a `company_id` column has no enabled+forced RLS policy, no policy,
or no `company_id`-leading index.

### 12.1 Tenant-owned tables (70) — every one carries `company_id`, RLS and composite FKs

| Group | Tables |
|---|---|
| Core & settings | `company_settings`, `branches`, `number_series`, `tax_rates` |
| Identity & access | `memberships`, `membership_invitations`, `roles`, `role_permissions`, `membership_roles`, `user_branch_scopes`, `project_members`, `project_member_permissions`, `access_delegations` |
| Partners | `clients`, `suppliers`, `subcontractors`, `party_contacts` |
| Projects | `projects`, `project_settings`, `project_parties`, `project_milestones`, `project_status_history` |
| Contracts & BOQ | `contracts`, `contract_value_ledger`, `boqs`, `boq_sections`, `boq_items`, `boq_item_versions`, `boq_revisions` |
| WBS / cost codes / budget | `wbs_nodes`, `cost_codes`, `project_cost_codes`, `budgets`, `budget_lines`, `budget_transfers` |
| Import pipeline | `import_batches`, `import_rows`, `import_validation_issues`, `import_column_mappings` |
| Variations | `variation_orders`, `variation_order_lines`, `variation_order_approvals` |
| IPC | `ipcs`, `ipc_lines`, `ipc_deductions`, `ipc_additions`, `ipc_snapshots`, `ipc_certificates`, `ipc_status_history` |
| Cost & cash | `expenses`, `expense_allocations`, `expense_status_history`, `cost_commitments`, `collections`, `collection_allocations`, `project_forecast_overrides` |
| Documents & approvals | `documents`, `document_versions`, `document_upload_sessions`, `document_links`, `approval_workflows`, `approval_workflow_steps`, `approval_requests`, `approval_actions` |
| Audit & jobs | `audit_logs`, `audit_checkpoints`, `job_outbox`, `job_idempotency_keys`, `notifications`, `notification_preferences` |

Treatments that differ from the simple "one policy on the table" rule, and why:

| Table | Treatment | Reason |
|---|---|---|
| `companies` (the tenant root) | self-policy `id = app.current_company_id()` plus a curated `app.my_companies()` SECURITY DEFINER reader | Membership resolution must be able to list a user's companies *before* a company context exists; the switcher must not be able to enumerate other companies |
| `audit_logs` + its monthly partitions | policy on the parent **and** on every partition (present and future) | PostgreSQL does not inherit `ENABLE`/`FORCE ROW LEVEL SECURITY` onto partitions, so a direct partition scan must carry its own policy. The partition helper applies the same policy when it creates a new month |
| `project_forecast_overrides` | tenant policy + project-scoped composite key | Written by a human with a reason; it changes a reported forecast, so it is treated as a financial row |
| `document_upload_sessions` | tenant policy + object-key uniqueness | Its row is the only evidence tying a staged object to a tenant before a `document_versions` row exists |
| `job_outbox`, `job_idempotency_keys` | tenant policy even though workers read them | A worker opens one transaction per company; the payload is tenant data and must obey the same rule as everything else |

### 12.2 Global tables (no `company_id`) — identity and reference data only

| Table | Why it is global | Access rule |
|---|---|---|
| `users` | A person may belong to several companies with the same login; the identity itself is not tenant-owned | Readable by the application for authentication; company data is reached only through `memberships` |
| `user_credentials`, `user_mfa_totp`, `user_mfa_recovery_codes` | Belong to the identity, not to a company | Never exposed through tenant APIs; never joined into tenant reports |
| `sessions`, `login_attempts`, `password_reset_tokens` | Authentication state tied to the identity; carrying `active_company_id` as a *value* is not ownership | Sessions are invalidated by membership changes; login attempts are retained for security evidence |
| `invitations` (company-scoped invitations live in `membership_invitations`) | The token is issued to an email address before any company context exists | Token stored only as a hash; single use |
| `permissions` | A **catalogue**, identical for every tenant, versioned with the application | Tenants compose `roles`; they cannot invent or alter permission codes |
| `currencies`, `units_of_measure`, `regions`, `cities` | Saudi/Arabic reference data that must be identical across tenants | Seeded read-only reference data |
| `schema_version` | Deployment metadata | Operator-visible only |

Rules that keep the global tables safe:

1. No global table stores tenant business data — a global table is either identity state or immutable
   reference data, and that is the reviewer's checklist item when a new "small" table is proposed.
2. A global table may never be the *parent* of a tenant-owned row through a single-column FK
   ([ADR-0018](adr/ADR-0018-composite-foreign-keys.md) applies to tenant-to-tenant references;
   identity references such as `*_by` columns are deliberately global and are never used to
   filter data).
3. `permissions` is read-only for tenants; changes ship with the application and appear in the
   permission-registry review ([G §3](G-authorization-rbac.md)).
4. Personal data in identity tables follows the retention and deletion rules of
   [M §6](M-file-storage-security.md) and the audit actor rule of [L §6](L-audit-logging.md): a
   financial history must still be able to say *who* approved something even if the account is later
   anonymised.

### 12.3 How to classify a new table

```
Does it hold data that belongs to one customer company?
  ├── yes → tenant-owned: add company_id, add it to the RLS list (db/13), give it a
  │         company_id-leading index, and make every parent reference composite.
  └── no  → is it identity state or shared immutable reference data?
            ├── yes → global: document why in the table COMMENT and keep it out of tenant APIs.
            └── no  → the design is wrong: either it is tenant data (see above) or it is a
                      cross-tenant aggregate that belongs in `reporting`, not in a base table.
```
