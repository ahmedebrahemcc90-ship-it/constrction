# ADR-0004 — Money as exact `numeric` with `Decimal` and one documented rounding rule

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Database Architect, Financial Domain Architect
- **Related:** [I §2](../I-financial-architecture.md), [E §1](../E-database-design.md),
  [K §8](../K-boq-ipc-vo-design.md), [S §5](../S-testing-strategy.md), db/00 (`app.round_money`)

## Context

The product exists to tell a contractor what a project is worth, what it has certified, what it has
spent and what margin to expect. Those figures:

* are multiplied and re-measured constantly (quantities × rates, percentages of cumulative values,
  retention caps, advance recovery), so rounding error accumulates;
* must reconcile with a client's signed certificate and with the company's accountants to the
  halala (SAR minor unit);
* are subject to dispute years later, which means the *same inputs must reproduce the same number*;
* are checked by humans with calculators and spreadsheets, so the arithmetic must match ordinary
  commercial practice rather than surprising them.

Requirement 11 is explicit: fixed-precision decimal or integer minor units, never floating point.

## Decision

1. **Storage:** `numeric(20,4)` for monetary amounts, `numeric(18,6)` for quantities,
   `numeric(18,4)` for unit rates, `numeric(9,4)` for percentages, `integer` basis points for tax
   rates. No `real`, no `double precision`, no `money` type.
2. **Application layer:** Python `Decimal` end-to-end (psycopg returns `Decimal` for `numeric`); a
   lint rule forbids `float(` in the financial modules; money is transmitted over the API and stored
   in JSON as **strings**, never as JSON numbers.
3. **One rounding helper:** `app.round_money(value)` = `round(value, 2)` on `numeric`, i.e. half away
   from zero. No other rounding call sites in the financial path.
4. **Defined rounding points** (and nowhere else):
   * line amount = `round(quantity × unit_rate, 2)`;
   * document aggregate = **sum of the already-rounded line amounts** (the sum-of-rounded-lines
     identity), never `round(Σ quantity × rate, 2)`;
   * a percentage is applied to an already-rounded base, then rounded (`round(base × pct / 100, 2)`);
   * VAT = `round(base × vat_rate_bp / 10000, 2)`.
5. **Line amounts are produced by the database** (generated columns / guarded triggers), so a value
   that contradicts its inputs cannot be stored even if a service is wrong.
6. **Four stored decimals, two displayed decimals**: sub-halala precision is retained for
   re-measurement and rate division without compounding error, while documents and reports present
   two decimals.
7. **Snapshots pin the arithmetic** for anything already certified: rates, percentages, VAT basis
   points and previous values are stored on the certificate ([ADR-0007](ADR-0007-ipc-derived-cumulative-and-locking.md)),
   so a later change to a contract, BOQ or tax setting cannot move a historical number.

## Consequences

**Positive**

* Exact reproducibility: the Phase 0 scenario (`1,000 m³ × 450.5000`, retention 5 %, advance recovery
  10 %, VAT 15 % on the net base) reproduces to the halala: `450,500.00 → 22,525.00 → 45,050.00 →
  382,925.00 → 57,438.75 → 440,363.75`.
* No dependence on IEEE-754 semantics, no platform-specific surprises, no "it differs in Excel".
* Auditors and accountants can reproduce every figure with a calculator.
* The sum-of-rounded-lines identity means the printed certificate's total is always the sum of the
  lines a human can see, which is the first thing a client checks.

**Negative / costs to manage**

* `numeric` is slower than `float8` and larger on disk; acceptable at this scale, and indexes on
  money columns are rare.
* Python `Decimal` needs discipline (mixing with `float` raises or silently coerces depending on the
  operation) → enforced by lint rules and by the ORM's `DecimalField` typing.
* Sum-of-rounded-lines means a document total can differ by a few halalas from
  `round(Σ qty × rate, 2)`; this is *intentional*, documented, and surfaced in the working-papers
  view so nobody "fixes" it later.
* JSON-string money requires the frontend to format rather than compute; the SPA displays
  server-provided strings and never does financial arithmetic of its own.

**Follow-ups**

* Golden regression fixtures freeze expected outputs for the reference scenario; changing a number
  requires a reviewed fixture change ([S §5](../S-testing-strategy.md)).
* Property-based tests (Hypothesis) assert the identities of §4 for randomized inputs.
* CI schema lint fails on `real`/`double precision` in financial tables.

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **`float8` / Python `float`** | Silent representation error that compounds across thousands of lines and years of certificates; a half-halala per line is real money in a dispute. Phase 0 demonstrated the divergence directly (`41.1520` exact vs `41.1519958848` binary) |
| **Integer minor units (halalas) everywhere** | Exact, but arithmetic is unreadable and error-prone (every rate and percentage becomes a scaled integer), unit-rate division needs a decided scale anyway, and the Odoo-school alternative of "always round early" produces aggregate drift |
| **`numeric(20,2)` only (no sub-halala precision)** | Forces rounding at every intermediate step; re-measured quantities and split rates then accumulate visible error and the sum-of-lines identity breaks more often |
| **`money` type** | Locale-dependent formatting semantics, no server-side precision control, and poor ORM support; offers nothing over `numeric` |
| **Store VAT as a percentage (`numeric(5,2)`)** | Percentages invite fractional-basis-point ambiguity and float habits; basis points are exact integers and match how tax authorities express rates |
| **Round only at the very end (round the grand total)** | Produces documents whose printed lines do not sum to the printed total — the fastest way to lose a client's trust in the system |

## How this will be verified

1. Unit/property tests over the rounding identities of §4 with randomized `Decimal` inputs.
2. Golden fixtures for the full reference project (multi-section BOQ, variations, six certificates,
   partial collections) frozen and reviewed.
3. CI schema assertion: no floating-point column on a financial table.
4. Cross-check report: for every certified IPC, `Σ ipc_lines.current_amount` equals the stored header
   work value to the halala (an operational integrity metric in [Q §3](../Q-observability.md)).
