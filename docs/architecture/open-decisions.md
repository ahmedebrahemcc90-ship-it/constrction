# Open Architecture Decisions Requiring Owner Approval

These are decisions that **must not be made silently by the architect**. Most are not blocking for
Phase 0 (this design), but several gate the start of Phase 1 or a specific phase of
[T](T-implementation-phases.md). Each item states the question, the realistic options, a
recommendation, the consequence of deferring, and who must decide.

**Status of this document:** Phase 0 ends with these items open by design. Phase 1 may begin on the
decisions marked *Non-blocking* using the recommended default, but **the Blocking items must have a
recorded answer before the phase named in the "needed by" column starts.**

| ID | Decision | Blocking? | Needed by |
|---|---|---|---|
| [D-01](#d-01-tenant-onboarding-model) | Tenant onboarding model (operator-provisioned vs self-service) | Non-blocking | P2 |
| [D-02](#d-02-front-end-rendering-strategy) | Front-end rendering strategy (SPA + API vs server-rendered + htmx) | **Blocking** | P1 |
| [D-03](#d-03-client-facing-certificate-presentation) | Client-facing certificate presentation and signature/legal form | Non-blocking | P5 |
| [D-04](#d-04-hosting-region-and-data-residency) | Hosting region and data residency | Non-blocking | P1 (host purchase) |
| [D-05](#d-05-field-level-encryption-of-commercially-sensitive-values) | Field-level encryption of commercially sensitive values | Non-blocking | P5 |
| [D-06](#d-06-retention-periods) | Retention periods per data class | Non-blocking | P8 |
| [D-07](#d-07-off-site-backup-provider-and-key-custody) | Off-site backup provider/region and encryption-key custody | Non-blocking | P1 (backup setup) |
| [D-08](#d-08-tenant-storage-and-export-quotas) | Tenant storage and export quotas | Non-blocking | P6 |
| [D-09](#d-09-alert-escalation-and-on-call) | Alert escalation channel and on-call expectation | Non-blocking | P1 |
| [D-10](#d-10-expense-cost-attribution-strictness) | Expense cost attribution strictness (cost code required; WBS optional?) | Non-blocking | P6 |
| [D-11](#d-11-over-certification-policy) | Over-certification policy default | Non-blocking | P5 |
| [D-12](#d-12-hijri-calendar-display) | Hijri calendar display | Non-blocking | P7 |
| [D-13](#d-13-first-tenant-opening-data-migration-scope) | First-tenant opening-data migration scope | Non-blocking | P8 |

---

## D-01 Tenant onboarding model

**Question.** Does a new company get provisioned by an operator (invitation-only, audited), or is
there a self-service signup that creates a tenant and its first owner?

**Options.**
1. **Operator-provisioned (recommended for V1).** A platform operator creates the company and invites
   the first owner; every provisioning is an audited action. Onboarding becomes a short kickoff call,
   which also captures the settings (VAT defaults, numbering, branches) that later cause support load.
2. Self-service signup with email verification, a trial, and rate limits. Lower friction, but opens
   abuse, spam tenants, and unconfigured tenants that generate support tickets.

**Recommendation.** Option 1 for V1; revisit self-service once at least a few tenants have onboarded and
the default settings are proven. It keeps the attack surface and the billing conversation deliberate.

**Impact if deferred.** The authentication/tenant-creation surface stays slightly wider and onboarding
support cost remains unknown; no schema change is needed either way (invitations and memberships
already exist).

**Owner.** Owner / Product.

---

## D-02 Front-end rendering strategy

**Question.** Is the UI a **SPA + JSON API** (Vite/React/TanStack, the stack assumed by C and G) or
**server-rendered Django templates + htmx** for the whole application (or a hybrid: SPA only for
dashboards and BOQ grids)?

**Options.**
1. **SPA + API (current assumption).** Best ergonomics for large editable grids (BOQ import preview,
   IPC line entry), dashboards and offline-ish drafting; costs an extra API surface and a second
   front-end toolchain, all of which must be authorized individually.
2. **Server-rendered + htmx throughout.** Smaller attack surface (no separate API tokens, fewer
   endpoints, less client-side state), faster to build for form-heavy flows; weaker for very large
   interactive grids and chart-heavy dashboards.
3. **Hybrid.** Server-rendered shell and CRUD forms, SPA islands for BOQ/IPC grids and dashboards.
   Highest productivity for the domain shape, at the cost of two paradigms in one codebase.

**Recommendation.** Option 1 as designed, **or** Option 3 if the team is small and the schedule is
tight — in which case the API must remain the single authorization choke point (the design already
requires this).

**Impact if deferred.** Phase 1 scaffolding (build pipeline, component library, session/CSRF
handling, i18n/RTL setup) cannot start cleanly. This is the one genuinely blocking item.

**Owner.** Owner / Product, with the architect.

---

## D-03 Client-facing certificate presentation

**Question.** What exactly does the client receive, and what makes it acceptable to a Saudi
contractor's client: a PDF with the contractor's letterhead, whose signature block, a wet-signature
place, a QR/reference code, an accompanying cover letter in Arabic, and does it need to reference any
client document numbering?

**Options.** (1) System-generated certificate with a configurable letterhead and a printed reference
code (recommended); (2) signed externally and stored in the system as a scan linked to the
certificate; (3) both — generate the working copy, store the countersigned scan as the legal artefact.

**Recommendation.** Option 3 in practice: generate a bilingual certificate with a verifiable reference
and payload hash, and allow the countersigned scan to be attached to the same certificate record.

**Impact if deferred.** The `ipc_certificates`/document linkage design is already in place; only
template content and workflow change. Low structural impact, high commercial impact — decide before
the first certificate is issued to a real client.

**Owner.** Owner / Commercial.

---

## D-04 Hosting region and data residency

**Question.** Where is the VPS hosted, and is there a residency requirement that data must remain
inside the Kingdom?

**Options.** (1) Region close to Saudi Arabia (Bahrain/Dubai) for latency, or a KSA-resident provider
for residency; (2) European region for cost/quality; (3) start regional and migrate later (the
extraction path in [F §9](F-tenant-isolation.md) makes this feasible).

**Recommendation.** Choose a provider/region with a **KSA or GCC footprint** if any customer
contracts (or expects) local residency; otherwise a nearby region (Bahrain/Dubai) is the best
latency/cost compromise. Document the choice and the off-site backup region together (D-07).

**Impact if deferred.** Host purchase and DNS/TLS setup (P1) are blocked; migration later is possible
but disruptive.

**Owner.** Owner, with legal input.

---

## D-05 Field-level encryption of commercially sensitive values

**Question.** Should the most sensitive numbers (BOQ unit rates, margins, forecast cost) be encrypted
at the field level, so that even a database administrator cannot read them without an application
key?

**Options.**
1. **No field-level encryption (recommended for V1).** Rely on disk encryption, least privilege, RLS
   and audit. Keeps sorting, aggregation, indexing, reporting and constraints intact — all of which
   the financial engine depends on.
2. **Selective encryption of a few columns** (e.g. `unit_rate`, forecast overrides) with an
   application-held key and encrypted-column indexes or blind tokens. Protects against a DBA reading
   a single figure, at the cost of losing `numeric` arithmetic, ordering, uniqueness and constraints
   on those columns, and of breaking the DB-level identities this design relies on.
3. **Full tenant-level encryption of a subset of tables.** Most protective, largest engineering and
   operational cost (key rotation, search, reporting, backups).

**Recommendation.** Option 1 for V1, with the exposure recorded as exception E-2 in
[security-checklist.md](security-checklist.md). Revisit if a customer contractually requires it; the
migration would be a new ADR, not a code change made quietly.

**Impact if deferred.** None structurally; the risk is carried knowingly and reviewed quarterly.

**Owner.** Owner / Security.

---

## D-06 Retention periods

**Question.** How long is each class of data kept: financial documents and their PDFs, audit log,
application logs, imported source workbooks, generated exports, and backups (local PITR window and
off-site monthly fulls)?

**Options.** Inputs needed from the owner/accountant: statutory retention for commercial records
(commonly 10 years in KSA for accounting records), dispute windows, and privacy expectations for
personal data (PDPL). Sensible starting defaults: financial documents and certificates **10 years**;
audit log **7 years** minimum (recommended 10 to match financial records); application logs **90 days**;
imports and evidence **10 years**; generated exports **7 days**; local PITR **35 days**; off-site
monthly fulls **12 months**.

**Recommendation.** Adopt the defaults above as *configurable* retention classes, confirmed in writing
by the owner and the accountant, and implement pruning as an audited job
([L §5](L-audit-logging.md), [O §1](O-backup-disaster-recovery.md)).

**Impact if deferred.** Storage grows (acceptable short-term) and the privacy/retention story stays
unfinished, which blocks P8 and any customer security questionnaire.

**Owner.** Owner, with the accountant and legal input.

---

## D-07 Off-site backup provider and key custody

**Question.** Which off-site destination holds the encrypted backups, in which region, and who holds
the encryption passphrase (escrow) if the primary holder is unavailable?

**Options.** (1) A different provider from the VPS provider, S3-compatible, with object-lock support
(recommended: it removes a single-vendor failure and enables immutability); (2) a second account with
the same provider (weaker isolation); (3) physical media rotation (cheap, slow, easy to forget —
not recommended alone).

**Recommendation.** Option 1, in a different region from the primary VPS where residency rules allow.
Key custody: an off-host secret store held by the owner **plus** a sealed physical copy in a safe,
with a documented custodian and a yearly rotation review.

**Impact if deferred.** Backup setup (P1) cannot be completed, and requirement 20 (encrypted, off-site,
restorable) stays unproven — a go-live blocker.

**Owner.** Owner / Engineer.

---

## D-08 Tenant storage and export quotas

**Question.** Are there per-tenant limits (storage volume, monthly export volume, number of projects or
users) that need technical enforcement, and what happens when a limit is reached?

**Options.** (1) No enforced limits in V1; monitor and bill/alert (simplest); (2) soft limits with
alerts and warnings, hard limits only on export rate (recommended); (3) hard quotas per plan with
blocking behaviour and an upgrade path.

**Recommendation.** Option 2: rate-limit and alert now, and design quota fields so Option 3 can be
added without a schema change. Hard-blocking a customer mid-month-end because of a storage quota is a
support disaster; warn early instead.

**Impact if deferred.** Low; the monitoring already planned ([Q §3](Q-observability.md)) surfaces the
data needed to decide.

**Owner.** Owner / Product.

---

## D-09 Alert escalation and on-call

**Question.** Where do alerts go, and who is expected to react at 02:00 to a P1 (service down, backup
failure, audit-chain mismatch)?

**Options.** (1) Email + messaging webhook to a small group (acceptable for a pilot, with a stated
"best effort, next business morning" expectation for non-P1); (2) a rotating on-call with an escalation
policy (PagerDuty-class) and an SLA; (3) a managed operations contract.

**Recommendation.** Option 1 during the pilot, with a **written** response expectation, and move to
Option 2 before the first production tenant that runs payroll or certificates on the system. At a
minimum, P1 alerts must reach a human who knows the runbook.

**Impact if deferred.** Alerts technically exist but nobody is accountable; a backup failure could go
unnoticed for days — which is how the worst outcomes happen.

**Owner.** Owner.

---

## D-10 Expense cost attribution strictness

**Question.** Must every expense carry a cost code **and** a WBS node, or is the WBS optional?

**Options.** (1) Cost code required, WBS optional, BOQ item optional (recommended) — mirrors how site
costs actually appear and keeps data entry fast, with "unlinked cost" reported explicitly;
(2) both cost code and WBS required — better cost control, slower entry, more fake WBS assignments;
(3) cost code only.

**Recommendation.** Option 1. The system already reports the unlinked/unattributed share rather than
hiding it, which lets the owner tighten the rule later if the data shows it matters.

**Impact if deferred.** Low; the schema supports all three (nullable WBS/BOQ links). The rule is
enforced in validation, so changing it is a policy change, not a migration.

**Owner.** Owner / Finance.

---

## D-11 Over-certification policy

**Question.** If a measured quantity exceeds `BOQ quantity + approved variation quantity`, does the
system refuse the certificate or allow it with a flag?

**Options.** (1) **Refuse by default** (recommended), with a company-level setting to allow;
(2) allow with a warning always; (3) allow only when an explicit approval step is included.

**Recommendation.** Option 1, with Option 3 available as the "allow" behaviour (flag + escalation
approval). Real projects do occasionally certify ahead of an approved variation, but that is a
deliberate commercial decision that should leave a trace, not a silent default.

**Impact if deferred.** Low technically; high commercially, because it defines whether the system can
ever say "no" to a site team. Decide before the first real certificate.

**Owner.** Owner / Commercial.

---

## D-12 Hijri calendar display

**Question.** Does the UI need Hijri dates (in addition to Gregorian) in V1?

**Options.** (1) **Not in V1** (recommended): store Gregorian (UTC) and display Gregorian; add Hijri as
a derived display string later; (2) display Hijri parallel to Gregorian in the UI and on documents
from day one (a display-layer addition, no schema change); (3) Hijri-primary for selected documents.

**Recommendation.** Option 1 for V1 with the door open to Option 2, because Hijri rendering
(`Intl`/ICU `islamic-umalqura` calendar) requires a conversion library decision, careful testing across
month boundaries, and font/format review in PDFs — value that can be added later without touching the
data model.

**Impact if deferred.** None structurally; a customer asking for Hijri on certificates before P5 would
force Option 2 earlier, so it is worth confirming with the first pilot tenant.

**Owner.** Owner / Product.

---

## D-13 First-tenant opening-data migration scope

**Question.** For the first real tenant, what historical data must be loaded, and to what standard of
reconciliation — contracts and BOQ only, or also historical certificates, expenses and collections?

**Options.** (1) **Forward-only from a chosen cut-off date** (recommended): load partners, projects,
contracts, BOQ and WBS; open each contract with an approved variation that reflects certified-to-date
and payments-to-date as opening balances, and start certifying from the next period;
(2) full historical backfill of every certificate, expense and collection (accurate history, high
migration effort and reconciliation risk);
(3) read-only archive of historical documents attached to projects, with no financial rows.

**Recommendation.** Option 1 with Option 3 for evidence (attach the old PDFs so nothing is lost),
because retro-fitting historical certificates invites exactly the reconciliation errors the product is
meant to prevent. The opening-balance approach must be documented and signed off by the accountant.

**Impact if deferred.** Affects P8 planning and the first tenant's onboarding timeline, not the schema.

**Owner.** Owner, with the accountant.

---

## Closed during Phase 0 (recorded so they are not reopened by accident)

| Topic | Decision | Where |
|---|---|---|
| Subdomain per tenant | Not in V1; tenant selection after login | [P §6](P-deployment-vps-docker.md) |
| Kubernetes / microservices | Not in V1; single deployable modular monolith | [C](C-application-architecture.md), [A §3](A-technology-stack.md) |
| Database-per-tenant | Not in V1; shared schema + RLS, with a documented extraction path | [ADR-0001](adr/ADR-0001-multi-tenancy-shared-schema-rls.md) |
| User-facing report/query builder | Not in V1; curated reports with drill-down | [ADR-0021](adr/ADR-0021-curated-reporting-not-query-builder.md) |
| Government platform integrations (ZATCA/Mudad/GOSI/Etimad) | Not built, not assumed, never claimed | requirement 22; risk R-08 |
| JWT/bearer tokens in the browser | Not used; opaque DB-backed cookie sessions | [H §3](H-authentication-sessions.md) |
| Committed cost in V1 | Schema present, no V1 writer; dashboards show 0 and label it | [C §5](C-application-architecture.md), [I §3](I-financial-architecture.md) |

---

## How to close a decision

1. The owner answers in the same structure: chosen option, any deviation, effective date.
2. If the answer changes a design, the change is made in the relevant document **and** recorded as an
   ADR (or an ADR update) — never as an undocumented code change.
3. The row is moved to "Closed during Phase 0" (or a new "Closed" table) with the deciding actor and
   date; the ID is retained forever so citations stay valid.
