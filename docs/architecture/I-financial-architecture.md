# I. Financial Calculation Architecture

The product's whole promise is "understand the financial position and expected profitability of
every project". That promise is only kept if the arithmetic is exact, reproducible, and never
contradicted by what a browser sent.

---

## 1. Principles

| # | Principle | Consequence |
|---|---|---|
| 1 | Exact decimal arithmetic everywhere | `numeric` in PostgreSQL, `Decimal` in Python; **no** float/`real`/`double` in the financial path — enforced by a CI schema lint |
| 2 | Derive, do not trust | Every total, cumulative, retention, VAT and profitability figure is computed server-side |
| 3 | Freeze what you certify | Certified documents keep their inputs (rate, %, previous cumulative) as snapshots |
| 4 | Documented rounding | One rounding rule, applied at one scale, in one place (`app.round_money`) |
| 5 | One writer per number | Each figure has a single authoritative source (ledger, lines, or snapshot) and every cache is reconcilable |
| 6 | Transactions and locks for money | Certification, posting, reversal and allocations run in explicit transactions with row/advisory locks |
| 7 | Reversible, not editable | Corrections are reversal + re-issue, preserving history |

---

## 2. Money representation and rounding policy

| Item | Decision |
|---|---|
| Storage | `numeric(20,4)` for monetary amounts, `numeric(18,6)` for quantities, `numeric(18,4)` for unit rates, `numeric(9,4)` for percentages, `integer` basis points for tax |
| Scale used in business documents | 2 decimal places (SAR minor unit = halala) |
| Why 4 stored decimals | Unit-rate division and re-measurement produce sub-halala values; storing 4 dp avoids compounding rounding error while presenting 2 dp |
| Rounding mode | **Half away from zero** (`round(x, n)` on `numeric`) — deterministic, matches common commercial practice, and is applied only at defined points |
| Where rounding happens | (a) line amounts: `round(quantity × unit_rate, 2)`; (b) header aggregates: sum of the already-rounded line amounts; (c) percentages applied to a rounded base; (d) VAT on the defined base |
| Where rounding must NOT happen | Never inside a chain of intermediate calculations; never "round then multiply then round again" |
| Float ban | No `float`/`double` columns; no `float()` casts; JSON money is transmitted as **strings** |
| Currency on every document | `currency_code` (V1: SAR only, structure ready for FX later) |

**Worked example that motivates the policy** (`3.333333 × 12.3456`): exact decimal gives
`41.1520` at 4 dp; IEEE-754 double gives `41.1519958848` → a half-halala discrepancy on a single
line, multiplied across thousands of lines and years of certificates. Verified in Phase 0.

**Aggregation identity:** a header total is *defined* as the sum of its rounded lines
(`${"Σ round(qtyᵢ × rateᵢ, 2)"}$), never as `round(Σ qtyᵢ × rateᵢ, 2)`. Where a header must also
carry a rounded whole-document figure (e.g. a lump sum), the difference is materialised in an
explicit reconciliation field so the document always balances.

---

## 3. The four cost concepts (never conflated)

| Concept | Definition | Source in this design |
|---|---|---|
| **Budget** | Approved plan (intent) | `budgets` + `budget_lines`, exactly one `approved` version per project |
| **Committed Cost** | Legally encumbered but not yet incurred (PO, subcontract award) | `cost_commitments` — **V1 writes nothing here** (procurement is out of scope); dashboards read it, so V1 honestly shows 0 instead of an unknown |
| **Actual Cost** | Incurred cost | `expenses` in `posted`/`paid` status (net of VAT; VAT is not a cost) |
| **Forecast Cost** | Expected final cost | Explicit override in `project_forecast_overrides`, otherwise `actual + (remaining value × budget cost ratio)` |

Progress on the revenue side is measured by **certified work value** (IPC), not by expenditure — a
contractor can spend heavily before certifying, and conflating the two is how projects look healthy
until the end.

---

## 4. Calculation catalogue (all server-side)

### 4.1 Contract value

```
revised_contract_value (RCV) = original_value + Σ contract_value_ledger.amount_delta
```
* Only `approved` variation orders post to the ledger (`variation_approved` / `omission_approved`);
  `submitted`, `under_review`, `rejected` and `cancelled` VOs contribute **zero**.
* Posting is idempotent by a unique key on `(company_id, source_type, source_id, entry_type)`.
* `contracts.current_value` is only a cache for dashboards; the ledger is authoritative and a
  nightly job reconciles the two (`cache_needs_reconcile` is exposed in `v_contract_value_summary`).
* Pending VOs are shown **separately**, never inside RCV.

### 4.2 BOQ

```
boq_item.amount = round(quantity × unit_rate, 2)      -- generated column
boq.total_amount = Σ boq_item.amount                   -- trigger-maintained cache
revised_item_quantity = boq_quantity + Σ approved VO quantity deltas for that item
```

### 4.3 IPC (interim payment certificate)

The header is the classic **previous / cumulative / current** triple, computed as:

```
current_value      = Σ round(current_quantity × certified_rate, 2)          (per line, snapshotted rate)
cumulative_value   = previous_value + current_value
previous_value     = certified cumulative value of the contract's prior certificate   ← from history
retention_current  = cumulative_retention − previous_retention
                     cumulative_retention = min(round(cumulative_value × retention_pct / 100, 2),
                                               round(retention_cap_pct/100 × RCV, 2))
advance_current    = cumulative_advance_recovered − previous_advance_recovered
                     cumulative_advance_recovered = min(advance_amount,
                                                        previous_recovered + round(current_value × recovery_pct / 100, 2))
net_payable_current = current_value + current_additions − retention_current
                      − advance_current − other_deductions_current
vat_amount          = round(vat_base_amount × vat_rate_bp / 10000, 2)
total_payable       = net_payable_current + vat_amount
outstanding         = total_payable − amount_received
```

Rules:

* `previous_*` values come **only** from the contract's certified history, read inside the
  certification transaction; the database re-validates the claim
  (`app.validate_ipc_previous_values`) and refuses certificates that disagree — verified in Phase 0.
* Retention and advance percentages are **snapshotted** onto the IPC at certification; a later
  contract amendment never rewrites history.
* Over-certification (`cumulative_quantity > boq_quantity + approved VO quantity`) is blocked by
  default (`INV-21`); a company may explicitly allow it, and then it is flagged on every report.
* VAT basis (before or after retention) is a company/project setting; the chosen basis is
  snapshotted per certificate so the number is reproducible.
* Retention releases and advance receipt/recovery are separate line items with their own types, never
  folded into "misc" adjustments.

### 4.4 Cash and receivables

```
collection.unallocated = amount − Σ allocations
ipc.amount_received    = Σ allocations from posted/reconciled collections
outstanding_ipc        = total_payable_incl_vat − amount_received
aging                  = today − (posted_at | certified_at)
```
Collections never modify certified work value or contract value (`INV-33`) — they only settle.

### 4.5 Profitability

```
margin_to_date          = certified_revenue_to_date − actual_cost_to_date
forecast_cost           = override? : actual_cost + (RCV − certified_revenue_to_date) × budget_cost_ratio
                          where budget_cost_ratio = approved_budget / RCV_as_known_at_budget_approval
expected_final_margin   = RCV − forecast_cost
expected_margin_pct     = expected_final_margin / RCV
```

Each number on the dashboard is drillable to its source rows: `certified_revenue` → the IPC lines;
`actual_cost` → the expense list; `forecast_cost` → the override (with author and reason) or the
formula inputs. "Expected profitability" that cannot be explained line by line is not usable in a
board meeting.

---

## 5. Server-side recomputation: the "never trust the client" contract

| Client input | Server behaviour |
|---|---|
| `quantity` on an IPC line | Accepted as *measurement data*, validated against BOQ + approved VO limits, project scope and duplicates |
| `unit_rate` | **Ignored** on certification; the snapshotted/certified rate is used |
| `amount` on any line | Never accepted — generated by the database from qty × rate |
| Header totals (`gross`, `net_payable`, `retention`, `vat`, `total`) | Never accepted — recomputed; the API contract does not even expose them as writable fields |
| `previous_cumulative_*` | Never accepted — read from certified history and re-validated by a database trigger |
| `cumulative_*` | Never accepted — derived |
| `status` transitions | Not a free-text field: only registered transitions, by permitted actors, with guards |
| `company_id`, `project_id` (as authority) | Never accepted as authorization evidence ([F §4](F-tenant-isolation.md)) |
| `vat_rate_bp` | Validated against the effective-dated company rate at the document date (a mismatch is a hard error, not a silent override) |
| Structural totals (`Σ` lines) | Re-checked in the certification transaction and asserted equal to the header |

Implementation consequences:

* DTOs/serializers **exclude** derived fields entirely, so "malicious input" is a 400/ignored rather
  than a subtle corruption.
* The database's generated columns and identity CHECKs make an inconsistent row impossible even if a
  service is wrong — verified in Phase 0 (a forged VAT figure is refused).
* Money is transmitted as strings to avoid any float parsing on either side of the wire.

---

## 6. Concurrency control

| Operation | Mechanism | Why |
|---|---|---|
| **IPC certification** | `pg_advisory_xact_lock('ipc_certify:' || contract_id)` **plus** `SELECT … FOR UPDATE` on the IPC, then read the prior certified certificate under the same lock | Two concurrent certifications would otherwise compute the same `previous` values and double-count revenue (`INV-28`) |
| Variation approval → ledger posting | `FOR UPDATE` on the VO row + unique `(company_id, source_type, source_id, entry_type)` | A VO can never post twice, even under retry ([ADR-0005](adr/ADR-0005-contract-value-ledger.md)) |
| Contract value cache update | Recompute `Σ ledger` inside the same transaction | Cache is derived from the authority, never incremented blindly |
| Collection allocation | `FOR UPDATE` on the collection and on the target IPC, checking `Σ allocations ≤ amount` and `≤ outstanding` | Prevents over-allocation and lost updates |
| Expense posting | Optimistic `version` check plus status guard | Prevents double posting from stale tabs |
| BOQ import commit | Advisory lock per target BOQ + re-validation inside the transaction | Prevents two imports racing on the same BOQ ([K §7](K-boq-ipc-vo-design.md)) |
| BOQ approval / revision | `SELECT … FOR UPDATE` on the BOQ + partial unique index (`one approved per contract`) | Exactly one measurement baseline at any time |
| Month-end bulk operations (retention release, MV refresh) | Advisory lock per company + idempotent job keys | Safe to retry |
| Idempotent API writes | `Idempotency-Key` + unique `(company_id, endpoint, key)` storing the original response | Replays never double-post money |

Isolation level: `READ COMMITTED` with explicit locking (the domain has well-defined lock points).
`SERIALIZABLE` is reserved for the few numeric aggregates where retry-on-conflict is acceptable and
cheaper than broader locking.

---

## 7. Snapshots and reproducibility (why a 2026 certificate still adds up in 2029)

Stored per certificate (`ipc_snapshots`): contract version and value at certification, original
value, approved VO total, BOQ id + revision + total, retention % and cap, advance amount and
recovery %, recovery mode, VAT rate in basis points, currency, the previous certificate id/period,
the calculation engine version, and a SHA-256 of the canonical payload.

For every line (`ipc_lines`): rate used, previous cumulative quantity and amount, BOQ revision
number, description/unit snapshots, and whether the line came from an approved variation.

Consequences:

1. Amending a contract, revising a BOQ, or changing the VAT rate **cannot** retroactively change a
   certified certificate.
2. A dispute can be resolved by recomputing from the snapshot — and the engine version tells us
   exactly which rules were in force.
3. The payload hash gives a tamper check independent of the audit chain for that specific document.

---

## 8. Dashboards and KPI definitions (with drill-down)

| KPI | Definition | Drill-down |
|---|---|---|
| Revised Contract Value | ledger-based RCV ([§4.1](#41-contract-value)) | contract value ledger entries |
| Certified Revenue to Date | Σ certified IPC cumulative work value | IPC list → IPC lines → measurement sheets |
| Certified vs RCV % | `certified / RCV` | BOQ item progress view |
| Outstanding Receivable | Σ (total payable incl VAT − received) on non-cancelled certificates | aging view → IPC → allocations |
| Retention Held | Σ cumulative retention of certified IPCs | certificate detail |
| Advance Outstanding | `advance_amount − Σ recovered` | certificate deductions |
| Actual Cost | Σ posted expenses (net of VAT) | expense list per cost code |
| Committed Cost | Σ open commitments (0 in V1) | cost-commitment table (empty in V1) |
| Forecast Cost | override or formula ([§4.5](#45-profitability)) | override record (author + reason) or formula inputs |
| Expected Final Margin / % | `RCV − forecast_cost` / ÷ RCV | both of the above |
| Pending Variations (not in RCV) | Σ submitted + under-review VO net amounts | variation register |
| Cash Collected | Σ posted collections | collection list → allocations |
| Project Loss Warning | `forecast_cost > RCV` | the project's cost and value detail |

Presentation rules: every dashboard shows its **as-of timestamp** (materialized view refresh), money
in SAR with the document's currency label, and a visible "pending variations excluded from RCV" line
so nobody mistakes the pipeline for the contract value.

---

## 9. Testing the arithmetic (summary; full plan in [S §6](S-testing-strategy.md))

Property-based tests (Hypothesis) over `Decimal` for: line-amount rounding, sum-of-rounded-lines
identity, retention cap behaviour, advance recovery never exceeding the advance, VAT identity, and
percentage boundaries. Golden-file regression fixtures for a full realistic project (multi-section
BOQ, three VOs, six IPCs, partial collections) whose expected output is frozen: any change to a
calculation requires an explicit, reviewed update to those files.
