# Risk Register

Risk IDs (`R-01…`) are **separate from the threat vectors** (`TV-01…TV-46`) in
[R §4](R-security-threat-model.md): a threat vector is an attack path, a risk here is something that
can go wrong with the project — technical, operational, delivery or commercial. Scores are
likelihood × impact, before mitigation; the "residual" column is after the named controls.

| Scale | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| Likelihood | very unlikely | unlikely | possible | likely | almost certain |
| Impact | minor | moderate | serious | major | severe |

---

## 1. Domain and financial risks

| ID | Risk | L | I | Score | Mitigation (and residual) | Owner |
|---|---|---|---|---|---|---|
| **R-01** | **Wrong financial arithmetic** produces figures that do not match a client's signed certificate → disputes, loss of trust, manual reconciliation forever | 3 | 5 | **15** | Fixed-precision decimals, one rounding helper, DB-generated line amounts, server-side recomputation, snapshot-per-certificate, property-based + golden fixtures, concurrency tests ([I](I-financial-architecture.md), [S §5](S-testing-strategy.md)) → residual **low** | Architect |
| **R-02** | **Wrong contract value** because a variation is counted twice, or counted before approval | 2 | 5 | **10** | Append-only ledger, idempotent posting by unique source key, derived RCV, nightly ledger-vs-cache reconciliation, `VO_FROZEN` ([ADR-0005](adr/ADR-0005-contract-value-ledger.md)) → residual **very low** (verified in Phase 0) | Architect |
| **R-03** | **Client-supplied totals or previous values** corrupt a certificate | 2 | 5 | **10** | Derived fields excluded from write DTOs, DB identity CHECKs, previous values re-derived from certified history under lock ([ADR-0007](adr/ADR-0007-ipc-derived-cumulative-and-locking.md)) → residual **very low** (verified) | Architect |
| **R-04** | **Concurrent operations double-post money** (two certifications, two approvals, parallel allocations) | 3 | 5 | **15** | Per-contract advisory lock + `FOR UPDATE`, EXCLUDE on overlapping periods, allocation limit checks under lock, idempotency keys → residual **low**; the parallel test is a Phase 1 gate | Architect |
| **R-05** | **Definitional disagreement** with the customer about what "expected profitability", "certified revenue" or "committed cost" mean | 4 | 4 | **16** | Written KPI definitions with drill-down ([I §8](I-financial-architecture.md)); committed cost shown as 0 and labelled (procurement out of scope); dashboard labels state what is excluded | Owner |
| **R-06** | **Over-certification** or under-measurement is enabled by a permissive setting and quietly distorts revenue | 3 | 3 | 9 | Blocked by default; enabling it is an explicit owner-level setting and every affected certificate is flagged on the exception dashboard (open decision D-11) | Owner |
| **R-07** | A project's **cross-project contamination** (cost of one project landing on another) | 2 | 4 | 8 | Project-scoped composite keys make it unstorable; allocation is an explicit split ([ADR-0019](adr/ADR-0019-project-scoped-composite-foreign-keys.md)) → residual **very low** (verified) | Architect |

---

## 2. Security risks

| ID | Risk | L | I | Score | Mitigation (and residual) | Owner |
|---|---|---|---|---|---|---|
| **R-08** | **Customers assume the product is ZATCA-compliant e-invoicing** (or that it submits to Etimad/GOSI/Mudad), because it produces "invoices" in Arabic → expectation gap, contractual and reputational exposure | 4 | 4 | **16** | Explicit positioning: documents are **commercial certificates/receipts, not e-invoices**; no integration is claimed in the product, the contract or the marketing; a documented "what this system is not" section for sales; the data model stores VAT/CR numbers as data only, with format checks and no government validation ([A §5](A-technology-stack.md), requirement 22) → residual **medium** (this is a communication risk, not a code risk) | Owner |
| **R-09** | **Cross-tenant data exposure** through a channel that skips the standard scoping (export, search, PDF metadata, cache key, log line) | 2 | 5 | **10** | Layered isolation: app scoping + composite FKs + forced RLS + tenant-prefixed storage/cache keys; isolation tests include content assertions on generated files; logs are tenant-tagged and scrubbed ([F](F-tenant-isolation.md), [S §4](S-testing-strategy.md)) → residual **low** | Security |
| **R-10** | **Insider fraud or sabotage** by an employee with legitimate access (falsified progress, hidden overspend, deleted evidence before leaving) | 3 | 4 | **12** | Segregation of duties, immutable certified/posted records, reversal-with-reason, append-only hash-chained audit, anomaly views (round-number/weekend expenses), prompt offboarding and access review → residual **medium** (collusion is a governance problem) | Owner |
| **R-11** | **Host compromise** (stolen SSH key, unpatched service) exposes live data and credentials | 2 | 5 | **10** | SSH keys only, no public DB/Redis/MinIO ports, non-root containers, least-privilege DB roles, patching cadence, Trivy/pip-audit, off-site immutable backups → residual **medium** (single VPS is one failure domain; exception E-1) | Owner |
| **R-12** | **Backup restores fail when needed** (or backups were never verifiable) | 2 | 5 | **10** | pgBackRest + immutable off-site repository, automatic verification, **monthly restore drills with integrity assertions**, measured RTO/RPO ([O §6](O-backup-disaster-recovery.md)) → residual **low** (drill failure is itself a P1 alert) | Owner |
| **R-13** | **Supply-chain compromise** (malicious/compromised dependency or base image) defeats application-level controls | 3 | 4 | **12** | Pinned digests, lockfiles, weekly dependency and image scanning, criticals patched ≤ 72 h, minimal images, no compilers at runtime → residual **medium** | Engineer |
| **R-14** | **Phishing/credential theft** of a privileged user leads to authorised-looking fraud | 4 | 4 | **16** | MFA mandatory for privileged roles, step-up AAL2 for money-moving operations, SoD prevents single-actor fraud, device/session listing with revocation, login anomaly alerting → residual **medium** | Owner |

---

## 3. Delivery and product risks

| ID | Risk | L | I | Score | Mitigation (and residual) | Owner |
|---|---|---|---|---|---|---|
| **R-15** | **Scope creep into Phase-2 modules** (procurement, subcontracts, HR, inventory) delays the money-critical core | 4 | 4 | **16** | The out-of-scope list is explicit in [T §4](T-implementation-phases.md); changes require an approved scope change **and** an ADR; the schema keeps room (`cost_commitments`) so the answer to "can we add it later?" is yes, without building it now | Owner |
| **R-16** | **Bilingual/PDF fidelity problems** (Arabic shaping, numeral direction, RTL layout in PDFs) surface late | 3 | 3 | 9 | WeasyPrint with bundled Noto Naskh Arabic, logical CSS properties in the SPA, Arabic PDF snapshots reviewed in the pre-release checklist, per-locale template tests → residual **low–medium** | Engineer |
| **R-17** | **Excel import reality** (inconsistent real-world BOQ spreadsheets, merged cells, formula totals) causes rework | 4 | 3 | **12** | Transactional staging with per-row preview, validation issues with bilingual messages, explicit confirmation, rollback, evidence retention; import is designed as a *review* workflow, not a magic button ([K §7](K-boq-ipc-vo-design.md)) → residual **medium** | Product |
| **R-18** | **Onboarding effort underestimated** (historic data comes as PDFs and spreadsheets; opening balances must reconcile) | 4 | 3 | **12** | First-tenant migration scoped as a project with reconciliation sign-off (open decision D-13); import pipelines reusable; "start fresh at the next certificate" is an accepted fallback | Owner |
| **R-19** | **Key-person dependency** (one architect/engineer holds the design) | 3 | 4 | **12** | Everything is written down (A–T, ADRs, runbooks, schema with comments), tests encode behaviour, runbooks exercised by someone other than their author, DR drill done by the owner's team | Owner |
| **R-20** | **Test definitions drift from financial definitions** (a test asserts the wrong number, so a real bug passes) | 2 | 5 | **10** | Golden fixtures derived from a real commercial scenario reviewed by the domain owner; identity/property tests that assert *relationships*, not only constants; drill-down reconciliation as an operational metric → residual **low** | Architect |
| **R-21** | **Performance degradation as tenants and audit partitions grow** (dashboards and imports slow; disk fills) | 3 | 3 | 9 | Materialized views with as-of timestamps, `company_id`-leading indexes, outbox + queue caps for heavy work, partitioning and archive strategy for audit, disk-growth alerts, capacity forecast each quarter → residual **low–medium** | Engineer |
| **R-22** | **Users keep working in spreadsheets** and the system becomes a reporting burden instead of the source of truth | 3 | 4 | **12** | Excel import/export is a first-class path (not a side feature), dashboards answer the daily questions, and the app is designed to be *faster* than the spreadsheet for the questions it owns; adoption is measured (active projects with certificates) → residual **medium** | Owner |

---

## 4. Operational and compliance risks

| ID | Risk | L | I | Score | Mitigation (and residual) | Owner |
|---|---|---|---|---|---|---|
| **R-23** | **Single-VPS outage** (disk, kernel, provider incident) stops certificate preparation and collections | 3 | 3 | 9 | Documented RTO ≤ 4 h, immutable off-site backups, rehearsed restore runbook, provider snapshots as a coarse fallback; warm-standby upgrade path documented ([P §9](P-deployment-vps-docker.md)) → residual **medium** (accepted in V1) | Owner |
| **R-24** | **Data-residency or PDPL obligations** are violated by hosting outside the Kingdom, or by retaining data too long | 3 | 4 | **12** | Region choice is an explicit owner decision (D-04); retention classes and legal-hold support; offboarding export-then-delete; privacy notice and DPAs (legal input, D-06) → residual **low–medium** | Owner |
| **R-25** | **Retention/legal hold mishandled** (evidence deleted, or data kept longer than allowed) | 2 | 4 | 8 | Retention classes per document/audit/log, `is_legal_hold` blocks deletion, deletions themselves audited, monthly pruning jobs with a report (D-06) | Owner |
| **R-26** | **Operator error during deploy or a data fix** damages production data | 3 | 4 | **12** | Pre-deploy backup + WAL marker, expand/contract migrations, staging rehearsal on restored data, no ad-hoc SQL without a review, PITR as the recovery path → residual **low–medium** | Engineer |
| **R-27** | **Alert fatigue**: nobody reads alerts, so a real incident is missed | 3 | 4 | **12** | Alerts must be actionable with a runbook link and a named owner; P1 limited to a small set; monthly alert review prunes noise; a synthetic alert is proven to reach a human before launch (D-09) | Owner |
| **R-28** | **Vendor/lock-in risk** in hosting, storage or monitoring choices | 2 | 3 | 6 | S3-compatible storage, standard Postgres, Docker Compose manifests, no proprietary managed services required; exit path documented per component | Architect |
| **R-29** | **Cost overrun** (storage growth, off-site egress, PDF rendering load) beyond expectations | 3 | 2 | 6 | Sizing basis documented, storage/egress monitored with alerts, lifecycle rules on exports and imports, capacity forecast each quarter | Owner |

---

## 5. Top risks to act on now (before Phase 1 or during it)

| Priority | Risk | Action required | By |
|---|---|---|---|
| 1 | **R-08** (positioning vs ZATCA expectations) | Written "what this system is not" statement for contracts and sales; review marketing language | Owner, before first customer conversation |
| 2 | **R-05** (definitional disagreement) | Sign off the KPI definitions in [I §8](I-financial-architecture.md) as the contractual meaning of the numbers | Owner, before P5 |
| 3 | **R-01/R-04** (arithmetic and concurrency) | Golden fixtures reviewed by the domain owner; parallel-certification test must pass before P5 exits | Architect, P5 gate |
| 4 | **R-12** (untested restores) | Complete one restore drill before the first real tenant's data is loaded | Engineer, P1 exit |
| 5 | **R-15** (scope creep) | Written scope-change rule (scope change + ADR) acknowledged by all stakeholders | Owner, before P3 |
| 6 | **R-10/R-14** (insider and credential risk) | Enable MFA for privileged accounts from day one; monthly access review calendar entry | Owner, P2 |
| 7 | **R-18** (onboarding effort) | Decide the first-tenant migration scope and reconciliation owner (D-13) | Owner, before P8 |
| 8 | **R-24/R-25** (residency and retention) | Decide hosting region and retention periods (D-04, D-06) | Owner, before launch |

---

## 6. Register maintenance

* Reviewed **quarterly** at minimum, and immediately after any incident, failed drill, or scope change.
* Every risk has a named owner; a risk without an owner is a wish.
* A risk whose score rises above 12 for two consecutive reviews requires a documented decision
  (accept with a compensating control, mitigate with scheduled work, or change scope) — not another
  meeting.
* Closed risks keep their ID; IDs are never reused, so downstream documents can cite them safely.
