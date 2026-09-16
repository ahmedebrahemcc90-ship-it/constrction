# ERD — Domain and Database Diagram

Companion to [D](D-domain-model.md) (business language and invariants) and [E](E-database-design.md)
(types, constraints, indexes). This file is the **relationship map**: what connects to what, with which
cardinality, and what enforces it. The normative DDL is in [`db/`](db).

Reading rules for every diagram below:

* every tenant-owned entity carries `company_id`, and every reference between tenant entities is a
  **composite foreign key** carrying it ([ADR-0018](adr/ADR-0018-composite-foreign-keys.md));
* project-owned parents expose `(company_id, project_id, id)` and their children carry all three
  ([ADR-0019](adr/ADR-0019-project-scoped-composite-foreign-keys.md));
* `AuditLog` rows are written for every audited table (drawn as one dashed relationship per group to
  keep the picture readable, not as 60 separate lines);
* soft-deleted master data (`deleted_at`) is intentionally omitted from the diagrams.

---

## 1. Tenancy, identity and access

```mermaid
erDiagram
    COMPANY ||--o{ BRANCH : "has"
    COMPANY ||--|| COMPANY_SETTINGS : "configured by"
    COMPANY ||--o{ NUMBER_SERIES : "numbers per document type"
    COMPANY ||--o{ TAX_RATE : "VAT history"
    COMPANY ||--o{ MEMBERSHIP : "employs"
    USER ||--o{ MEMBERSHIP : "belongs to (one per company)"
    USER ||--|| USER_CREDENTIAL : "authenticates with"
    USER ||--o{ SESSION : "opens"
    BRANCH ||--o{ USER_BRANCH_SCOPE : "restricts"
    MEMBERSHIP ||--o{ USER_BRANCH_SCOPE : "scoped to"
    MEMBERSHIP ||--o{ MEMBERSHIP_ROLE : "granted"
    ROLE ||--o{ MEMBERSHIP_ROLE : "assigned via"
    ROLE ||--o{ ROLE_PERMISSION : "bundles"
    PERMISSION ||--o{ ROLE_PERMISSION : "included in"
    MEMBERSHIP ||--o{ ACCESS_DELEGATION : "delegates (bounded, time-boxed)"
    COMPANY ||--o{ PROJECT : "owns"
    PROJECT ||--o{ PROJECT_MEMBER : "staffed by"
    MEMBERSHIP ||--o{ PROJECT_MEMBER : "participates as"
    PROJECT_MEMBER ||--o{ PROJECT_MEMBER_PERMISSION : "project-scoped grants"

    COMPANY {
        uuid id PK
        text code "unique per deployment"
        text name_ar
        text name_en
    }
    BRANCH {
        uuid id PK
        uuid company_id FK
        text code
    }
    USER {
        uuid id PK "global identity, no company_id"
        citext email
    }
    MEMBERSHIP {
        uuid id PK
        uuid company_id FK
        uuid user_id FK
        text status "active/suspended/revoked"
    }
    ROLE {
        uuid id PK
        uuid company_id FK "tenant-owned copy of a template"
        text code
    }
    PERMISSION {
        text code PK "global catalogue"
    }
    PROJECT {
        uuid id PK
        uuid company_id FK
        uuid branch_id FK
        text code
        text status
    }
    PROJECT_MEMBER {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid membership_id FK
        date expires_at
    }
```

Key points:

| Relationship | Cardinality | Enforcement |
|---|---|---|
| Company → Membership | 1..n | `uq_memberships_company_user` (a user has at most one membership per company) |
| User → Membership | 1..n (one per company) | global `users` table deliberately has **no** `company_id`; tenancy enters through membership |
| Role → Permission | n..n via `role_permissions` | permissions are a **global catalogue**; tenants compose roles, they cannot invent permission codes |
| Project → ProjectMember | 1..n | `project_members` carries `(company_id, project_id)` so a member cannot be attached to another tenant's project |
| Membership → Branch scope | 1..n | empty scope = all branches; non-empty scope = explicit restriction |

---

## 2. Commercial core: partners → project → contract → BOQ

```mermaid
erDiagram
    COMPANY ||--o{ CLIENT : "sells to"
    COMPANY ||--o{ SUPPLIER : "buys from"
    COMPANY ||--o{ SUBCONTRACTOR : "engages"
    PROJECT ||--o{ PROJECT_PARTY : "has roles"
    CLIENT ||--o{ PROJECT_PARTY : "as client"
    SUPPLIER ||--o{ PROJECT_PARTY : "as supplier"
    SUBCONTRACTOR ||--o{ PROJECT_PARTY : "as subcontractor"

    PROJECT ||--o{ CONTRACT : "has"
    CLIENT ||--o{ CONTRACT : "signs"
    CONTRACT ||--o{ CONTRACT_VALUE_LEDGER : "value changes (append-only)"
    CONTRACT ||--o{ BOQ : "measured by"
    BOQ ||--o{ BOQ_SECTION : "tree"
    BOQ_SECTION ||--o{ BOQ_SECTION : "parent_section_id (max depth guarded)"
    BOQ_SECTION ||--o{ BOQ_ITEM : "contains"
    BOQ ||--o{ BOQ_REVISION : "revisions"
    BOQ_ITEM ||--o{ BOQ_ITEM_VERSION : "history"

    PROJECT ||--o{ WBS_NODE : "execution tree"
    WBS_NODE ||--o{ WBS_NODE : "parent_node_id"
    COMPANY ||--o{ COST_CODE : "chart of cost types"
    PROJECT ||--o{ PROJECT_COST_CODE : "selects"
    COST_CODE ||--o{ PROJECT_COST_CODE : "enabled for"

    PROJECT ||--o{ BUDGET : "plans"
    BUDGET ||--o{ BUDGET_LINE : "cost plan"
    BUDGET_LINE }o--|| COST_CODE : "categorised by"
    BUDGET_LINE }o--o| WBS_NODE : "attributed to"
    BUDGET_LINE }o--o| BOQ_ITEM : "may map to sellable line"
    BUDGET ||--o{ BUDGET_TRANSFER : "post-approval movement"

    CONTRACT ||--o{ VARIATION_ORDER : "changed by"
    VARIATION_ORDER ||--o{ VARIATION_ORDER_LINE : "detail"
    VARIATION_ORDER_LINE }o--o| BOQ_ITEM : "extends existing item"
    CONTRACT_VALUE_LEDGER }o--|| VARIATION_ORDER : "source (idempotent)"

    CLIENT {
        uuid id PK
        uuid company_id FK
        text vat_number "format-checked only"
    }
    CONTRACT {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid client_id FK
        numeric original_value
        numeric current_value "cache of ledger sum"
    }
    CONTRACT_VALUE_LEDGER {
        uuid id PK
        uuid company_id FK
        uuid contract_id FK
        text entry_type
        numeric amount_delta
        uuid source_id "unique per type+source"
    }
    BOQ {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid contract_id FK
        text status "draft/approved"
        int revision_no
    }
    BOQ_SECTION {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid boq_id FK
        uuid parent_section_id FK "nullable"
    }
    BOQ_ITEM {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid boq_id FK
        uuid section_id FK
        uuid wbs_node_id FK "optional"
        uuid cost_code_id FK "optional"
        numeric quantity
        numeric unit_rate
        numeric amount "GENERATED round(qty*rate,2)"
    }
    WBS_NODE {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid parent_node_id FK "nullable"
        uuid cost_code_id FK "optional"
    }
    COST_CODE {
        uuid id PK
        uuid company_id FK
        uuid parent_id FK "nullable"
    }
    BUDGET_LINE {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid budget_id FK
        uuid cost_code_id FK
        uuid wbs_node_id FK "nullable"
        uuid boq_item_id FK "nullable"
        numeric amount
    }
    VARIATION_ORDER {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid contract_id FK
        text status
        numeric addition_amount "derived from lines"
        numeric omission_amount "derived from lines"
    }
```

Key points:

| Relationship | Cardinality | Enforcement / rule |
|---|---|---|
| Project → Contract | 1..n | contracts carry `(company_id, project_id)` → a contract cannot belong to another tenant's project |
| Contract → BOQ | 1..n (one approved at a time) | partial unique index: at most one `approved` BOQ per contract |
| BOQ → BOQSection → BOQItem | 1..n, 1..n | sections form a tree (`parent_section_id`, cycle-guarded trigger); items hang off sections, never off other items |
| BOQItem → VariationOrderLine | 1..n (optional) | an approved VO line **extends** the item's certifiable quantity ([K §4](K-boq-ipc-vo-design.md)) |
| VariationOrder → ContractValueLedger | 0..1 | unique `(company_id, source_type, source_id, entry_type)` makes posting idempotent |
| Budget ↔ WBS ↔ CostCode ↔ BOQItem | n..1 each | deliberately separate concepts; links are optional (except cost code) and every link is project-scoped |

---

## 3. Measurement and money: IPC ← VO/BOQ, then cost and cash

```mermaid
erDiagram
    CONTRACT ||--o{ IPC : "certified in periods"
    PROJECT ||--o{ IPC : "scoped to"
    IPC ||--o{ IPC_LINE : "measured work"
    IPC_LINE }o--|| BOQ_ITEM : "measures (project-scoped FK)"
    IPC_LINE }o--o| VARIATION_ORDER_LINE : "variation work"
    IPC ||--o{ IPC_ADDITION : "additions"
    IPC ||--o{ IPC_DEDUCTION : "retention / advance / penalty / other"
    IPC ||--|| IPC_SNAPSHOT : "frozen terms + payload hash"
    IPC ||--o{ IPC_CERTIFICATE : "generated PDF (via documents)"
    IPC ||--o{ IPC_STATUS_HISTORY : "lifecycle"

    PROJECT ||--o{ EXPENSE : "incurs"
    EXPENSE }o--|| COST_CODE : "categorised by"
    EXPENSE }o--o| WBS_NODE : "attributed to"
    EXPENSE }o--o| BOQ_ITEM : "may map to sellable line"
    EXPENSE ||--o{ EXPENSE_ALLOCATION : "split across projects/cost codes"
    PROJECT ||--o{ COST_COMMITMENT : "encumbered (schema-only in V1)"

    PROJECT ||--o{ COLLECTION : "receives"
    CLIENT ||--o{ COLLECTION : "pays"
    COLLECTION ||--o{ COLLECTION_ALLOCATION : "settles"
    COLLECTION_ALLOCATION }o--|| IPC : "against invoice/certificate"

    IPC {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid contract_id FK
        text ipc_number
        date period_from
        date period_to
        text status
        numeric previous_work_value "from certified history"
        numeric current_work_value
        numeric cumulative_work_value "stored + identity CHECK"
        numeric retention_pct
        numeric advance_recovery_pct
        int vat_rate_bp
        numeric vat_amount
        numeric total_payable_incl_vat
        numeric amount_received
        numeric outstanding_amount
    }
    IPC_LINE {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid ipc_id FK
        uuid boq_item_id FK "project-scoped"
        uuid variation_order_line_id FK "nullable"
        numeric previous_quantity
        numeric current_quantity
        numeric cumulative_quantity
        numeric certified_unit_rate "snapshot"
        numeric current_amount "derived, constrained"
    }
    EXPENSE {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid cost_code_id FK
        uuid party_source_type "supplier/subcontractor"
        numeric amount_net
        int vat_rate_bp
        numeric vat_amount
        text status
    }
    COLLECTION {
        uuid id PK
        uuid company_id FK
        uuid project_id FK
        uuid client_id FK
        numeric amount
        numeric unallocated_amount "derived"
        text status
    }
```

Key points:

| Relationship | Cardinality | Enforcement / rule |
|---|---|---|
| Contract → IPC | 1..n | non-overlapping, non-cancelled periods via an EXCLUDE constraint; sequential periods enforced in the certification service |
| IPC → IPCLine | 1..n | lines are frozen from certification; `Σ current_amount = header current_work_value` is an integrity metric |
| IPCLine → BOQItem | n..1 | composite FK `(company_id, project_id, boq_item_id)` → **another project's item is refused** (verified in Phase 0) |
| IPCLine → VariationOrderLine | n..1 (optional) | variation work is always traceable to the approved VO that authorised it |
| IPC → IPCSnapshot | 1..1 | written at certification; immutable; carries the payload hash and the terms used |
| CollectionAllocation → IPC | n..1 | `Σ allocations ≤ collection.amount` and `≤ IPC.outstanding_amount`, enforced under lock |
| Expense → WBS/CostCode | n..1 | cost code required; WBS and BOQ item optional → "unlinked cost" is reported, not hidden (open decision D-10) |

---

## 4. Documents, approvals and audit

```mermaid
erDiagram
    COMPANY ||--o{ DOCUMENT : "owns"
    PROJECT ||--o{ DOCUMENT : "scoped to (optional for company docs)"
    DOCUMENT ||--o{ DOCUMENT_VERSION : "append-only versions"
    DOCUMENT ||--o{ DOCUMENT_LINK : "linked to business entities"
    DOCUMENT ||--o{ DOCUMENT_UPLOAD_SESSION : "direct-to-storage upload"

    CONTRACT ||--o{ DOCUMENT_LINK : "attachments"
    IPC ||--o{ DOCUMENT_LINK : "measurement sheets, certificate PDF"
    VARIATION_ORDER ||--o{ DOCUMENT_LINK : "instruction, evidence"
    EXPENSE ||--o{ DOCUMENT_LINK : "invoice / receipt"

    COMPANY ||--o{ APPROVAL_WORKFLOW : "defines"
    APPROVAL_WORKFLOW ||--o{ APPROVAL_STEP : "ordered steps"
    APPROVAL_WORKFLOW ||--o{ APPROVAL_REQUEST : "instantiated per document"
    APPROVAL_REQUEST ||--o{ APPROVAL_ACTION : "immutable decisions"
    APPROVAL_REQUEST }o--|| VARIATION_ORDER : "target (typed FK)"
    APPROVAL_REQUEST }o--|| IPC : "target (typed FK)"
    APPROVAL_REQUEST }o--|| BUDGET : "target (typed FK)"
    APPROVAL_REQUEST }o--|| EXPENSE : "target (typed FK)"

    COMPANY ||--o{ AUDIT_LOG : "partitioned per month"
    AUDIT_LOG ||--|| AUDIT_CHECKPOINT : "off-site verified windows"

    DOCUMENT {
        uuid id PK
        uuid company_id FK
        uuid project_id FK "nullable for company-level"
        text entity_type "optional classification"
        text status "draft/active/quarantined/archived"
        timestamptz deleted_at "soft delete"
    }
    DOCUMENT_VERSION {
        uuid id PK
        uuid company_id FK
        uuid document_id FK
        text bucket
        text object_key "server-generated uuid path"
        bigint size_bytes
        text content_type
        char64 sha256
        text scan_status "pending/clean/infected/failed"
    }
    APPROVAL_REQUEST {
        uuid id PK
        uuid company_id FK
        uuid workflow_id FK
        jsonb workflow_snapshot "frozen at submit"
        text target_entity_type
        uuid target_variation_order_id FK "typed, nullable"
        uuid target_ipc_id FK "typed, nullable"
        uuid target_budget_id FK "typed, nullable"
        uuid target_expense_id FK "typed, nullable"
        text status
    }
    AUDIT_LOG {
        bigint chain_seq PK "per company, gap-free"
        uuid company_id FK
        uuid actor_user_id "no FK: survives anonymisation"
        text action
        text entity_type
        uuid entity_id
        jsonb before
        jsonb after
        char64 prev_hash
        char64 row_hash
        int hash_key_version
        timestamptz created_at "partition key"
    }
```

Key points:

| Relationship | Cardinality | Enforcement / rule |
|---|---|---|
| Document → DocumentVersion | 1..n | append-only; the file itself is private object storage; only metadata lives in the database |
| Document → DocumentLink | 1..n | polymorphic **typed nullable FKs**, one real composite FK per target plus `CHECK (num_nonnulls(...) = 1)` — the pattern used wherever one table can point at several entity types |
| ApprovalWorkflow → ApprovalRequest | 1..n | the workflow definition is **snapshotted** onto the request so later template edits cannot change an in-flight approval |
| ApprovalRequest → ApprovalAction | 1..n | INSERT-only; each row records actor, role, step, comment, IP and request id |
| ApprovalRequest → target | exactly one of the 4 typed FKs | one open request per target is enforced by a partial unique index |
| AuditLog → AuditCheckpoint | windows | checkpoints record covered range, count, head hash, exported off-site |
| Any audited table → AuditLog | 1..n (dashed in reality) | row-change triggers on every audited table plus semantic events from services |

---

## 5. Cross-cutting relationship rules (the invariants the diagrams encode)

| # | Rule | Where enforced | Verified |
|---|---|---|---|
| 1 | No reference crosses a tenant | composite FKs `(company_id, …)` | Phase 0: `fk_contracts_client` refused a foreign client |
| 2 | No reference crosses a project for project-owned entities | composite FKs `(company_id, project_id, …)` | Phase 0: `fk_ipc_lines_boq_item` refused a foreign BOQ item |
| 3 | A polymorphic link has exactly one real parent | nullable typed FK per type + `num_nonnulls(...) = 1` + stored `entity_type` | `party_contacts`, `project_parties`, `document_links`, `approval_requests` |
| 4 | Money never leaves the database unrounded or the client in charge | generated line amounts + identity CHECKs + server-side recomputation | Phase 0: forged VAT rejected by `ck_ipcs_total_identity` |
| 5 | Value changes are append-only and idempotent | `contract_value_ledger` + unique source key | Phase 0: same ledger id returned twice |
| 6 | Documents and audit tables are append-only | grants + freeze triggers | Phase 0: `IPC_FROZEN`, `VO_FROZEN`, `permission denied` on `audit_logs` |
| 7 | Every tenant table is RLS-protected and fail-closed | `ENABLE`+`FORCE`+policy, runtime role without `BYPASSRLS` | Phase 0: 0 rows with no context, cross-tenant INSERT refused |
| 8 | Trees cannot become cycles | `app.forbid_tree_cycle(parent_column)` bound per tree table | Phase 0: WBS move under its own descendant raised `TREE_CYCLE` |

## 6. Text alternative (for readers who cannot render Mermaid)

Relationships in words, grouped as the diagrams are:

* **Company** owns branches, settings, number series, tax rates, roles, clients, suppliers,
  subcontractors, cost codes, projects and documents. **Users** are global identities that become part
  of a company through a **Membership**; a membership holds **Roles**, which bundle **Permissions**;
  a membership may also have branch scopes and delegations. **Project access** is separate: a
  **ProjectMember** row (per membership per project) plus optional project-member permissions.
* A **Project** belongs to a company (and optionally a branch) and to a **Client**. It has
  **Contracts**, one approved **BOQ** per contract (with **BOQSections** and **BOQItems**), a **WBS**
  tree, selected **CostCodes** and **Budgets** with **BudgetLines**.
* **VariationOrders** (with lines) change contract value through the append-only
  **ContractValueLedger**; only approved VOs post, exactly once.
* **IPCs** certify measured work per period with **IPCLines** that reference BOQ items (and, for
  variation work, VO lines), plus additions and deductions and an immutable **IPCSnapshot**;
  certification reads previous/cumulative values from certified history under lock.
* **Expenses** capture cost against cost codes (optionally WBS/BOQ), **Collections** capture cash and
  are allocated to IPCs through **CollectionAllocations** under limit checks.
* **Documents** carry versions (private object storage) and can be linked to any business entity;
  **Approvals** are workflow definitions with steps and per-document requests with immutable actions.
* **AuditLog** is the partitioned, hash-chained record of every audited change and semantic event,
  with checkpoints proving the chain off-site.
