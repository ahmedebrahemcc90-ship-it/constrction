# ADR-0019 — Project-scoped composite keys `(company_id, project_id, id)` for project-owned children

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Database Architect, Commercial Domain Architect, Security Engineer
- **Related:** [E §6](../E-database-design.md), [K §6](../K-boq-ipc-vo-design.md),
  [G §5](../G-authorization-rbac.md), [ADR-0018](ADR-0018-composite-foreign-keys.md), db/03, db/04, db/07, db/08

## Context

[ADR-0018](ADR-0018-composite-foreign-keys.md) stops cross-*tenant* references. Inside one tenant,
a second and much more likely mistake remains: a cross-*project* reference. Real examples from this
domain, all of which look harmless in a schema review:

* An IPC line for **Project 1** pointing at a BOQ item belonging to **Project 2** — same company,
  different contract; certification then measures work against the wrong baseline.
* A budget line for Project A referencing a WBS node of Project B — cost attribution silently moves.
* An expense allocation charged to another project's cost code — the margin of two projects is
  misstated in opposite directions and nobody notices until the year-end review.
* A collection allocation against another project's certificate — receivables aging becomes wrong for
  both projects.

These are also **authorization-relevant**: a user with access to Project 1 and a bug that lets them
name Project 2's BOQ item has performed horizontal privilege escalation inside the tenant, which
requirement 6 (project-level permissions enforced server-side) forbids.

During Phase 0, an attempt was made to catch this class with a trigger
(`app.enforce_same_project_refs()`) that compared the project of a child with the project of its
parent. It was removed: it is runtime work per write, it must be maintained for every table, it cannot
be enumerated as a structural property, and it cannot be tested as reliably as a constraint that makes
the bad value unstorable.

## Decision

**Project-owned parents expose `UNIQUE (company_id, project_id, id)` and project-owned children
reference them with `FOREIGN KEY (company_id, project_id, parent_id) REFERENCES parent (company_id,
project_id, id)`.**

1. Applies to every project-scoped entity: contracts, BOQs, BOQ sections/items, WBS nodes,
   `project_cost_codes`, budgets/lines/transfers, variation orders/lines, IPCs/lines/deductions/
   additions/snapshots, expenses/allocations, collections/allocations, project milestones, project
   members, project documents/links, import batches/rows, and the approval targets that are
   project-scoped.
2. The child stores `project_id` (not merely navigating to it), so the constraint is enforceable and
   the project filter is available to every query, including RLS-adjacent scoping in the application.
3. Company-wide entities (clients, suppliers, cost codes, users) keep the tenant-only form of
   ADR-0018; they are intentionally shareable across projects within a company.
4. Project-scoped references to company-wide entities still carry `company_id` (a cost code from
   another tenant must be refused), and the application validates that the entity is *selected* for
   that project where selection is modelled (`project_cost_codes`).
5. The application continues to apply project scope on list **and** detail endpoints, returning 404
   for out-of-scope ids ([G §4](../G-authorization-rbac.md)); the composite key is the structural
   backstop.

## Consequences

**Positive**

* Cross-project contamination is impossible for every referenced entity: Phase 0 verified that an IPC
  line for Project 1 pointing at a Project 2 BOQ item is refused by `fk_ipc_lines_boq_item`.
* Commercial reporting is trustworthy by construction: "revenue and cost of Project X" can never
  include a row that belongs to Project Y, so margins cannot be silently redistributed between
  projects.
* Project-level authorization gains a database-level ally: even with a service bug, no project can be
  made to reference another project's commercial baseline.
* The pattern is uniform, so reviewers can check it mechanically (a CI assertion that project-owned
  tables expose `UNIQUE (company_id, project_id, id)` and that their children carry all three columns).

**Negative / costs to manage**

* One more column and one more unique index per project-owned table; slightly longer child rows and
  marginally more storage — negligible against the failure mode it removes.
* Composite keys are verbose in migrations and ORM relations; Phase 1 must define them explicitly and
  a conformance test must catch drift.
* Some legitimate cross-project relationships exist in reality (a shared temporary facility, a single
  supplier invoice split across two projects). They are modelled as **two allocations**, one per
  project, each with its own project-scoped row — which is also the correct accounting treatment, so
  the constraint pushes the model in the right direction rather than blocking a valid need.
* A row cannot be re-assigned from one project to another in place; the documented correction path is
  reversal + re-creation, consistent with the immutability rules
  ([ADR-0008](ADR-0008-document-state-machines-and-immutability.md)).

**Follow-ups**

* CI assertion for the key shape (db/14 §8) and a migration-review checklist item.
* Documentation of the "split it into two project-scoped rows" pattern for cross-project costs in the
  domain guide (Phase 1 coding standards).
* The removed trigger approach is recorded here so it is not reinvented: structural keys, not
  behavioural triggers, are the mechanism of choice for cross-entity coherence.

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Trigger-based coherence (`app.enforce_same_project_refs`)** | Attempted and discarded during Phase 0: per-write runtime cost, per-table maintenance, not expressible as a checkable structural property, and it fired at a point where error messages were less clear than a plain FK violation |
| **Application-only validation of project scope** | The most common real bug in multi-project systems; one missed path corrupts two projects' financials. Also insufficient for authorization integrity |
| **Put everything in one project "bucket" per company** | Destroys the commercial model (contracts, BOQs and certificates are per project by definition) |
| **Let cross-project references exist but flag them** | A flag does not stop wrong margin, wrong certificates or wrong aging; detection is weaker than prevention for a structural problem |
| **Tenant-only composite keys (ADR-0018 only)** | Leaves the intra-tenant cross-project hole open, which is the more probable failure in practice |
| **Separate database per project** | Absurd operational cost; projects share partners, cost codes and users, and company-level reporting must join them |

## How this will be verified

1. **Phase 0 (done):** an IPC line referencing another project's BOQ item was refused by
   `fk_ipc_lines_boq_item`; project-scoped parent keys were added where missing during validation
   (`ipcs` and `collections` needed `(company_id, project_id, id)` before allocations could be
   constrained).
2. CI schema assertion: project-owned parents expose the composite unique key and their children carry
   `company_id` + `project_id`; the build fails otherwise.
3. Integration tests: for each project-scoped child, a raw insert naming another project's parent is
   refused by the database; API-level attempts return 404 with no row created.
4. Financial tests: a two-project fixture certifies work on Project 1 while Project 2 contains a
   conflicting BOQ item, and asserts that Project 2's certified revenue and margin are unchanged.
