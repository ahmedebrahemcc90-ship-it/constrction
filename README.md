# Construction Management SaaS (Saudi Arabia)

Multi-tenant SaaS platform that lets a construction company manage projects commercially and
understand the **financial position and expected profitability of every project**.

| | |
|---|---|
| Phase | **PHASE 0 — Architecture & Technical Blueprint (DESIGN ONLY)** |
| Status | Awaiting owner approval — no implementation code, no UI, no migrations yet |
| Deployment target | Linux VPS + Docker + PostgreSQL + reverse proxy + HTTPS + custom domain |
| Localization | Arabic (RTL) + English (LTR) · SAR default · `Asia/Riyadh` · configurable VAT |
| Blueprint entry point | [`docs/architecture/README.md`](docs/architecture/README.md) |

## Phase 0 rule

**No application code exists in this repository.** The only artifacts are design documents and a
normative PostgreSQL schema design (plain SQL, used as the specification for Phase 1 migrations).
Phase 1 must not start until the Phase 0 blueprint is explicitly approved and the open decisions in
[`docs/architecture/open-decisions.md`](docs/architecture/open-decisions.md) are resolved.

## Document map

| Deliverable | File |
|---|---|
| Index, executive summary, approval gate | [`docs/architecture/README.md`](docs/architecture/README.md) |
| A. Technology stack | [`A-technology-stack.md`](docs/architecture/A-technology-stack.md) |
| B. Infrastructure architecture | [`B-infrastructure-architecture.md`](docs/architecture/B-infrastructure-architecture.md) |
| C. Application / module architecture | [`C-application-architecture.md`](docs/architecture/C-application-architecture.md) |
| D. V1 domain model | [`D-domain-model.md`](docs/architecture/D-domain-model.md) |
| E. PostgreSQL entities & relationships | [`E-database-design.md`](docs/architecture/E-database-design.md) + [`db/`](docs/architecture/db) |
| F. Tenant isolation | [`F-tenant-isolation.md`](docs/architecture/F-tenant-isolation.md) |
| G. RBAC + project-scoped authorization | [`G-authorization-rbac.md`](docs/architecture/G-authorization-rbac.md) |
| H. Authentication / sessions | [`H-authentication-sessions.md`](docs/architecture/H-authentication-sessions.md) |
| I. Financial calculation architecture | [`I-financial-architecture.md`](docs/architecture/I-financial-architecture.md) |
| J. Document lifecycle / state machines | [`J-document-lifecycle.md`](docs/architecture/J-document-lifecycle.md) |
| K. BOQ / IPC / VO relationship design | [`K-boq-ipc-vo-design.md`](docs/architecture/K-boq-ipc-vo-design.md) |
| L. Audit-log architecture | [`L-audit-logging.md`](docs/architecture/L-audit-logging.md) |
| M. File-storage security | [`M-file-storage-security.md`](docs/architecture/M-file-storage-security.md) |
| N. Background jobs / queues | [`N-background-jobs.md`](docs/architecture/N-background-jobs.md) |
| O. Backup & disaster recovery | [`O-backup-disaster-recovery.md`](docs/architecture/O-backup-disaster-recovery.md) |
| P. VPS / Docker / reverse proxy / HTTPS | [`P-deployment-vps-docker.md`](docs/architecture/P-deployment-vps-docker.md) |
| Q. Observability | [`Q-observability.md`](docs/architecture/Q-observability.md) |
| R. Security threat model | [`R-security-threat-model.md`](docs/architecture/R-security-threat-model.md) |
| S. Testing strategy | [`S-testing-strategy.md`](docs/architecture/S-testing-strategy.md) |
| T. Implementation phases | [`T-implementation-phases.md`](docs/architecture/T-implementation-phases.md) |
| 1. Architecture Decision Records | [`adr/`](docs/architecture/adr) |
| 2. ERD / diagrams (Mermaid) | [`ERD.md`](docs/architecture/ERD.md) |
| 3. Security checklist | [`security-checklist.md`](docs/architecture/security-checklist.md) |
| 4. Identified risks | [`risks.md`](docs/architecture/risks.md) |
| 5. Open decisions for owner approval | [`open-decisions.md`](docs/architecture/open-decisions.md) |
