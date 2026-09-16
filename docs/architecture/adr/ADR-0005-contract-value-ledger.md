# ADR-0005 — Append-only contract value ledger; only approved variations change contract value

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Database Architect, Commercial Domain Architect
- **Related:** [K §3](../K-boq-ipc-vo-design.md), [I §4.1](../I-financial-architecture.md),
  [J §3](../J-document-lifecycle.md), [ADR-0004](ADR-0004-money-representation-and-rounding.md), db/03, db/06

## Context

Requirement: **Revised Contract Value = Original Contract Value + Approved Variation Orders only.**
Submitted, under-review and rejected variations must never increase contract value.

Construction reality behind the requirement:

* Original contract values are amended many times over a project's life (additions, omissions,
  re-measurement, scope transfers, dayworks), often with a client instruction that arrives long before
  the formal VO is signed.
* Commercial directors track a "pipeline" of pending variations that is *not* money in the contract;
  mixing the two inflates revenue, distorts margin and produces certificates the client will reject.
* Disputes are usually about **when** a variation became contractual, not about its amount.
* A single field `contracts.current_value` mutated in place loses the entire history of how the number
  came to be, and cannot answer "who approved what, when, and against which instruction".

## Decision

**The contract's value is the sum of an append-only ledger, and only an approved variation may write
to that ledger.**

1. `contract_value_ledger` is **append-only**: one row per value-affecting event
   (`original_contract`, `variation_approved`, `omission_approved`, `amendment`, `reinstatement`,
   `correction`), carrying `amount_delta`, the effective date, the source document
   (`source_type`, `source_id`) and the actor. `UPDATE`/`DELETE` are revoked from every application
   role and blocked by a trigger.
2. **Idempotency is structural:** a unique key on `(company_id, source_type, source_id, entry_type)`
   (`uq_cvl_source_once`) means a retried approval, a double-clicked button or a replayed job cannot
   post a variation twice. The posting function `app.post_vo_to_contract_value()` returns the existing
   `ledger_entry_id` when the entry already exists — Phase 0 verified that calling it twice yields the
   same ledger id and no second row.
3. **Only the approved state posts.** The transition `submitted|under_review → approved` posts the
   ledger entry in the same transaction as the approval decision; `rejected` and `cancelled` post
   nothing; `draft` and pending states are reported separately as
   "pending variations (excluded from RCV)".
4. **Derived, not incremented:** `contracts.current_value` is a cached convenience column;
   `revised_contract_value = original_value + Σ ledger.amount_delta` is authoritative, always
   recomputed from the ledger, and a nightly reconciliation job reports any drift (`0` is the only
   acceptable result).
5. **Variation totals come from the database**, derived from `variation_order_lines` by
   `app.recalculate_vo_totals()`, so a header amount that disagrees with its lines cannot exist.
6. **Approved variations are frozen** (`app.enforce_vo_freeze`): corrections are `supersede` + a new
   variation (which posts a compensating ledger entry), never an edit of an approved VO or its entry.
7. Omission lines reduce value with their own entry type, so "additions" and "omissions" are never netted
   invisibly.

## Consequences

**Positive**

* The number the owner sees is explainable down to individual approved variations, with dates and
  actors — the exact form a dispute or a client query needs.
* Pending variations can never leak into revenue, margin or the forecast, because there is no code
  path that adds them.
* Double-posting is impossible by construction rather than by application care (verified in Phase 0:
  the ledger entry id was identical on the second call and the row count stayed at one).
* Historical contract value at any date can be reconstructed from the ledger's effective dates —
  useful for as-of reporting and for explaining why a certificate's limits changed.
* The same ledger pattern can later absorb amendments, reinstatements and approved claims without a
  schema change (V1 restricts which types the services will create).

**Negative / costs to manage**

* One extra insert and one extra read for value changes; the reconciliation job exists because the
  cached column can drift (it never drifts *authoritatively*, which is the point).
* Superseding instead of editing means more documents in the register; correctly reflects reality.
* Developers must not treat `contracts.current_value` as the source of truth — enforced by a code
  review rule and by the ledger-vs-cache drift metric being a monitored invariant ([Q §3](../Q-observability.md)).

**Follow-ups**

* The ledger is audited at row level (before/after JSON) in addition to the semantic approval event.
* `reporting.v_contract_value_summary` exposes both the ledger-derived RCV and the pending-variation
  total, so no report has to choose between them.
* The reconciliation metric is alerted if non-zero after a run.

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Mutate `contracts.current_value` on approval** | Loses history, cannot answer "why is it this number?", cannot support as-of reporting, and any bug is unrecoverable because the previous value is gone |
| **Store approved variation totals as a denormalized column only** | Same history loss, plus it makes double-posting possible (increment twice = wrong total, silently) |
| **Allow pending variations to raise contract value, flagged** | Directly contradicts the requirement and, in practice, inflates revenue in dashboards that busy people read; flags do not survive a screenshot |
| **A generic "adjustments" table with editable rows** | Editable = unauditable; also mixes contract terms with journal-like corrections |
| **Post variations into the general ledger of an external accounting system** | An accounting/GL integration is explicitly out of V1 scope; the contract value ledger is a *commercial* record, not an accounting journal |
| **Recompute "approved variation total" by querying approved VOs on the fly everywhere** | Simple, but it re-derives money at every read, cannot represent amendments/reinstatements, and cannot give a stable identifier for a posted value (needed for idempotency and for audit) |

## How this will be verified

1. **Phase 0 (done):** a VO of 250 × 450.5 produced a header addition of `112,625.00`; posting returned
   the same ledger id twice (idempotent); RCV moved `1,000,000.00 → 1,112,625.00`; renaming an approved
   VO raised `VO_FROZEN`.
2. Integration tests: a submitted/under-review/rejected VO changes RCV by exactly `0`; approval posts
   exactly one entry; a retried approval posts none; the reconciliation job reports zero drift.
3. Concurrency test: two parallel approvals of the same VO produce exactly one ledger entry.
4. Privilege test: `app_rw` cannot `UPDATE` or `DELETE` `contract_value_ledger` (verified in Phase 0 as
   `permission denied for table contract_value_ledger`).
