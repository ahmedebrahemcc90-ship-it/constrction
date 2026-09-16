# ADR-0021 — Curated reports and fixed views in V1; no user-facing report or query builder

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Application Architect, Commercial Domain Architect
- **Related:** [A §5](../A-technology-stack.md), [C §7](../C-application-architecture.md),
  [I §8](../I-financial-architecture.md), db/11, [Q §6](../Q-observability.md)

## Context

The requirement is "financial dashboards and reports" that let a contractor understand each project's
position and expected profitability. Two very different products can satisfy that sentence:

* **A curated reporting layer**: a fixed set of reports and dashboards whose definitions are
  versioned in code, whose numbers are traceable to their source rows, and whose performance is
  predictable.
* **A user-facing report/query builder**: tenants assemble their own queries, joins and aggregations
  over the data.

The second is tempting (it looks like flexibility and it demos well) but it collides with almost every
principle in this project:

* a tenant-authored query can join any table it can reach — the perfect vector for a cross-tenant
  mistake if the tenant filter is ever omitted, and a sustained BOLA risk surface (requirement 7);
* an arbitrary query engine on the same database as live financial writes is a denial-of-service
  vector for every other tenant ([F §8](../F-tenant-isolation.md));
* financial definitions would leak into customer hands: two tenants would compute "expected margin"
  two different ways, and neither would match the audit trail when disputed;
* supporting "why does your report say X?" becomes impossible when the customer wrote the report;
* the domain's value is precisely that the *definitions* are correct (certified revenue, retention
  cap, advance recovery, forecast cost) — those definitions are the product.

## Decision

**V1 ships a curated reporting layer: a fixed catalogue of reports, dashboards and exports, defined in
code, executed against `reporting` views and materialized views, with every figure drillable to its
source rows. No user-facing report builder, no ad-hoc query interface, no user-supplied SQL, no
customer-defined formulas on money.**

1. **Catalogue over construction (V1):** project financial position; BOQ vs budget; certified vs
  revised contract value; variation register (approved vs pending, clearly separated); IPC register
  and receivables aging; retention and advance schedules; cost by cost code; cost by WBS; cash
  collected; company dashboard.
2. **Definitions live in `reporting`** ([db/11](../db/11_reporting_views.sql)) — views and materialized
  views where the arithmetic is written once and reviewed once, not re-derived per report.
3. **Tenant filtering is structural:** every reporting object is company-scoped and reads through the
   application's tenant-scoped connection (RLS applies), so a report cannot be composed in a way that
   crosses tenants.
4. **Every figure is drillable** to the rows that produced it (KPI → document → lines → source
   documents), which is how a number becomes trustworthy and how a dispute is settled.
5. **Extensibility without a builder:**
   * parameterised reports (date range, project, branch, cost code, status) cover the realistic
     variation requests;
   * saved views are stored parameters, never stored query text;
   * column selection and grouping are allowed on a **pre-defined, pre-aggregated** dataset;
   * a new report is a small, reviewed, tested addition to the catalogue.
6. **Exports** (XLSX/PDF, bilingual) are produced from the same definitions, so a downloaded file and
   the on-screen number cannot disagree; exports are permission-gated (`reports.export` /
   `financials.export`), step-up protected and audited ([L §3](../L-audit-logging.md)).
7. **Performance is bounded by design:** materialized views with a documented refresh strategy and an
   as-of timestamp, indexes led by `company_id`, and export work pushed to the `bulk` queue
   ([N §4](../N-background-jobs.md)). No report executes an unbounded query against live tables.

## Consequences

**Positive**

* Cross-tenant risk from reporting is structurally removed: there is no path where a tenant supplies
  query text.
* One definition per KPI means the dashboard, the report, the export and the reconciliation job all
  agree — the failure mode "finance disagrees with the system" is designed out.
* Performance is predictable, and one tenant's heavy report cannot degrade another's, because the
  query shapes are known and cached/materialized.
* Support and audit are tractable: "why is this number like this?" has an answer, and it is the same
  answer for everyone.
* The audit trail and the reporting layer share definitions, so an auditor can reproduce a figure from
  the same views the product uses.

**Negative / costs to manage**

* Customers will ask for custom columns/reports; the answer is a product decision (catalogue
  extension) rather than self-service, which requires a clear intake process and honest expectations —
  an explicit owner-facing trade-off.
* Real-world spreadsheet habits (using the export as a pivot source) are met by making exports richer
  and stable in shape, not by building a query tool.
* Materialized views introduce a staleness window; the UI must always display the as-of timestamp and
  offer a "refresh now" action for permitted users, so nobody mistakes a cached number for a live one.

**Follow-ups**

* A report request intake process and a definition catalogue document, both owner-approved.
* If self-service is later justified, it must be built as a **sandboxed, pre-aggregated semantic
  layer** (a curated star schema with row-level security and a query governor) — recorded here so the
  decision is deliberate, not a slide into raw SQL access.
* Golden fixtures for each catalogue report, so a definition change is always a visible, reviewed diff.

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Generic SQL/report builder (Metabase/Superset-style) exposed to tenants** | Raw or near-raw access to financial tables, no enforceable per-tenant row filter at the semantic level, unbounded query cost, and definitions that differ per customer — the opposite of an auditable financial system |
| **Per-tenant custom code for reports** | Untestable, unmaintainable, and every one of them becomes a security review burden; also impossible to reconcile consistently |
| **Customer-maintained formulas on money (spreadsheet formulas in the UI)** | Turns calculations into unvalidated user input; violates "server-side recomputation" in spirit and makes disputes unresolvable |
| **Direct database access for a customer's BI tool** | Handing over a data path we cannot authorize per project or per field; categorically refused |
| **Only exports, no in-app reporting** | Users would still need to open Excel to answer basic questions; the product's value is answering them correctly in place |
| **Build both (curated + builder)** | Doubles the surface, splits the definition of truth, and concentrates risk on the more dangerous half |

## How this will be verified

1. API surface review: no endpoint accepts query text, table names, join specifications or formulas.
2. Isolation tests over every reporting endpoint and export: Company A's output contains no Company B
   identifier (asserted at the generated-file level, not only in the query).
3. Consistency tests: dashboard, report and export for the same parameters produce identical figures.
4. Performance tests with realistic multi-tenant volumes ([S §9](../S-testing-strategy.md)), including a
   "noisy neighbour" case where one tenant runs the heaviest report while others use the system.
5. Definition drift test: golden fixtures per report; any change to a definition is a reviewed diff.
