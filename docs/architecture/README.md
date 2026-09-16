# Phase 0 — Architecture & Technical Blueprint

**Product:** Multi-tenant SaaS for construction companies in Saudi Arabia.
**Primary objective:** manage projects commercially and understand the financial position and
expected profitability of every project.
**Mode:** DESIGN ONLY. No application code, no UI, no features beyond V1, no government
integrations, no Phase 1 work in this phase.

---

## 1. Executive summary

The system is a **multi-tenant, financially-sensitive commercial control platform** for
contractors. Its value depends entirely on two properties that drive every architectural choice:

1. **Numbers must be right and defensible.** Certified revenue, revised contract value, retention,
   advance recovery and cost position must be reproducible from authoritative historical records —
   never from client-supplied totals, never from floating point, never recomputed from *current*
   configuration when reading *historical* documents.
2. **Tenant and project isolation must hold.** Company A must never read or mutate Company B data,
   and a site engineer in Company A's Project 1 must not see Project 2's margin. This holds even
   when a bug exists in one layer.

### 1.1 Core architectural posture

| Concern | Decision (short form) | Detail |
|---|---|---|
| Tenancy | Single database, shared schema, `company_id` on every tenant row, **fail-closed PostgreSQL RLS** as the last line of defence | [F](F-tenant-isolation.md), [ADR-0001](adr/ADR-0001-multi-tenancy-shared-schema-rls.md) |
| Structural tenant integrity | **Composite FKs `(company_id, parent_id)`** so a cross-tenant reference is *impossible by schema*, not merely rejected by code | [E §6](E-database-design.md), [ADR-0018](adr/ADR-0018-composite-foreign-keys.md) |
| Authorization | Company-scoped permissions **and** project-scoped grants, resolved server-side per request at one choke point; UI visibility is never authorization | [G](G-authorization-rbac.md) |
| Money | `numeric(20,4)` + `Decimal`, fixed rounding policy, DB-generated line amounts, server-side recomputation of every total | [I](I-financial-architecture.md), [ADR-0004](adr/ADR-0004-money-representation-and-rounding.md) |
| Contract value | Append-only **contract value ledger**; only *approved* variations increase RCV | [K §3](K-boq-ipc-vo-design.md), [ADR-0005](adr/ADR-0005-contract-value-ledger.md) |
| IPC correctness | Cumulative/previous values read from certified DB history inside a locked transaction; client values discarded | [I §6](I-financial-architecture.md), [ADR-0007](adr/ADR-0007-ipc-derived-cumulative-and-locking.md) |
| History immutability | Certified/posted documents are immutable; corrections happen through reversal/adjustment, never in-place edits | [J](J-document-lifecycle.md), [ADR-0008](adr/ADR-0008-document-state-machines-and-immutability.md) |
| Files | Private S3-compatible object storage, per-tenant prefixes, authz **before** short-lived presigned URL, AV scan, checksums | [M](M-file-storage-security.md), [ADR-0010](adr/ADR-0010-private-object-storage.md) |
| Secrets | Docker secrets / root-only env files, per-role DB credentials, rotation policy, zero secrets in Git | [P §7](P-deployment-vps-docker.md) |
| Backups | pgBackRest PITR + client-side-encrypted off-site copies + **immutable** retention + tested restores | [O](O-backup-disaster-recovery.md), [ADR-0011](adr/ADR-0011-backup-and-pitr.md) |
| Audit | Append-only, hash-chained, partitioned, INSERT-only grants, off-site checkpoints, break-glass is audited | [L](L-audit-logging.md), [ADR-0009](adr/ADR-0009-append-only-hash-chained-audit.md) |

### 1.2 V1 domain boundary (in scope)

Companies/tenants · Branches · Users · Roles & permissions · Project-level access · Clients ·
Suppliers · Subcontractors · Projects · Contracts · BOQ · WBS · Cost codes · Budgets · Variation
orders · Client IPCs / progress certificates · Project expenses · Collections · Documents ·
Approval workflows · Audit logs · Financial dashboards · Reports.

### 1.3 Explicitly out of scope (V1)

Procurement (PR/RFQ/PO/GRN) · subcontracts & subcontractor IPCs · site daily reports · RFIs ·
submittals · inventory · equipment · HR/payroll · **any integration with ZATCA, Mudad, GOSI,
Etimad or any other Saudi government platform** (none is assumed to exist).

V1 nevertheless *stores* the identifiers (CR number, VAT number, National Address) required for
future e-invoicing work, and produces bilingual commercial documents that are **not** ZATCA
e-invoices.

---

## 2. How to review this blueprint

Read in this order:

1. [`D-domain-model.md`](D-domain-model.md) — the business language and the rules that must never break.
2. [`I-financial-architecture.md`](I-financial-architecture.md) + [`K-boq-ipc-vo-design.md`](K-boq-ipc-vo-design.md) — the money engine.
3. [`F-tenant-isolation.md`](F-tenant-isolation.md) + [`G-authorization-rbac.md`](G-authorization-rbac.md) — isolation & permissions.
4. [`E-database-design.md`](E-database-design.md) + [`db/`](db) — the schema that enforces (1)–(3) structurally.
5. [`J`](J-document-lifecycle.md), [`L`](L-audit-logging.md), [`M`](M-file-storage-security.md) — lifecycle, history, files.
6. [`O`](O-backup-disaster-recovery.md), [`P`](P-deployment-vps-docker.md), [`Q`](Q-observability.md) — run it safely on one VPS.
7. [`R-threat-model.md`](R-security-threat-model.md), [`security-checklist.md`](security-checklist.md) — what can go wrong.
8. [`S-testing-strategy.md`](S-testing-strategy.md), [`T-implementation-phases.md`](T-implementation-phases.md) — how we prove it and in what order we build.
9. [`open-decisions.md`](open-decisions.md) — **the only thing that blocks Phase 1.**

Deliverable index (A–T) and closing artifacts (ADR / ERD / checklist / risks / open decisions) are
mapped in the repository [`README.md`](../../README.md).

---

## 3. Phase gate (STOP condition)

Phase 0 ends here. Phase 1 (Foundation: repo, CI, Docker, tenancy, auth, audit) starts only when:

- [ ] The blueprint sections A–T are accepted (or accepted-with-changes recorded as ADR revisions).
- [ ] Every blocking item in [`open-decisions.md`](open-decisions.md) has an owner decision.
- [ ] High/critical items in [`risks.md`](risks.md) have an accepted owner or mitigation.
- [ ] The schema design in [`db/`](db) is accepted as the Phase 1 migration source of truth.

**No implementation code will be written until that approval is given.**
