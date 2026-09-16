# ADR-0007 — IPC cumulative/previous values are derived from certified history under lock; derived IPC columns are stored with identity checks (not generated)

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Database Architect, Financial Architect
- **Related:** [I §4.3/§6/§7](../I-financial-architecture.md), [K §5](../K-boq-ipc-vo-design.md),
  [J §3](../J-document-lifecycle.md), db/07

## Context

An interim payment certificate (IPC) is inherently cumulative. Each certificate must state:

* what was certified **previously** for this contract,
* what is being certified **now** (this period's measured quantities),
* the **cumulative** position, and from it retention, advance recovery, VAT and the net payable.

The requirements say explicitly: *"IPC cumulative and previous values must come from authoritative
historical records and must never be accepted blindly from the frontend."* Two failure modes make
this the highest-risk arithmetic in the product:

1. **Client-supplied previous values** — a browser (or a hostile API caller) reporting
   `previous_work_value = 999,999` would inflate or deflate every downstream figure. Phase 0
   demonstrated that the database refuses such a claim with `IPC_PREVIOUS_VALUES_INVALID`.
2. **Concurrent certification** — two certificates for the same contract prepared at the same time
   would both read the same "previous" state and both certify the same delta, double-counting revenue
   while each individual document looks internally consistent.

A third, purely technical constraint surfaced during Phase 0 and must be recorded here:

> **PostgreSQL does not allow a stored generated column to reference another generated column.**
> The generation expression may only reference non-generated columns of the same row (and immutable
> functions). Therefore an IPC header whose `cumulative_*` is generated from `current_*`, where
> `current_*` is itself generated from `ipc_lines`, is not expressible as a chain of generated
> columns — the definition fails at `CREATE TABLE` time.

## Decision

### 1. Values come from certified history, read under lock

* The *previous* figures for a new certificate are read from the contract's **certified** history
  (`ipc_snapshots` / the prior certified IPC header), never from the request payload. The prior
  certificate is the one with the greatest `period_to < current.period_from`; a missing certificate is
  an error, not a silent zero.
* The request may carry measured quantities only. `previous_*`, `cumulative_*`, retention, advance
  recovery, VAT and every total are server-computed.
* The database **re-validates the claim**: `app.validate_ipc_previous_values()` recomputes the
  previous position from certified rows and raises `IPC_PREVIOUS_VALUES_INVALID` on any disagreement,
  so even a buggy service cannot persist a wrong previous value.

### 2. Certification is serialized

* `pg_advisory_xact_lock(hashtext('ipc_certify:' || contract_id))` plus `SELECT … FOR UPDATE` on the
  contract/certificate row for the duration of the certification transaction.
* A database-level exclusion constraint prevents two non-cancelled certificates from covering
  overlapping periods for the same contract.
* All writes for a certification (header, lines, deductions, additions, snapshot, status, audit,
  outbox) happen in **one transaction**.

### 3. Derived IPC columns are *stored*, protected by identity CHECKs

Because generated columns cannot chain, the derived IPC figures (`cumulative_*`,
`total_payable_incl_vat`, `outstanding_amount`, `vat_*`, retention/advance cumulative amounts) are
ordinary stored columns written **only** by the certification function, and the database enforces
their correctness with explicit identity constraints (`ck_ipcs_*_identity`), for example:

```
cumulative_work_value = previous_work_value + current_work_value
cumulative_retention  = previous_retention  + retention_current
total_payable_incl_vat = net_payable + vat_amount
outstanding_amount     = total_payable_incl_vat − amount_received
```

The same approach applies to headers whose roll-up would otherwise chain: the header is written in a
single statement (or the CHECKs are deferred within the transaction) so the identity holds at commit.
`ipcs.current_net_payable` **is** a generated column — it derives from non-generated columns of the
same row (`current_work_value`, additions, deductions), which PostgreSQL permits — and services must
never assign it.

### 4. Certification writes a snapshot

`ipc_snapshots` records the terms and inputs the arithmetic depended on (contract value, BOQ revision
and total, retention %, retention cap, advance amount and recovery mode, VAT basis points, currency,
previous certificate reference, engine version) plus a SHA-256 of the canonical payload. The snapshot
is immutable (no args passed to the immutability trigger → every column is protected) and the payload
hash lets a certificate be re-verified independently of the audit chain.

## Consequences

**Positive**

* Previous/cumulative values cannot be wrong because they are read from certified records by the
  database's own rules and re-checked against the stored history.
* Revenue cannot be double-counted by concurrency, because certification is serialized per contract
  and periods cannot overlap.
* The stored-with-CHECK design gives the same "the row cannot be internally inconsistent" guarantee
  that generated columns would have given, and reports the violation as a named constraint
  (`ck_ipcs_total_identity`) that points directly at the arithmetic rule that broke.
* Identities are self-documenting: a future reader sees the formula in the schema, not only in code.
* Snapshots make historical certificates reproducible even after contracts, BOQs and tax rates change.

**Negative / costs to manage**

* The database cannot compute these columns itself, so a code path that writes them outside the
  certification function can violate an identity → the constraint fails the write (good), so the
  failure is loud rather than silent; services must write the header in one statement, and
  multi-statement updates must not leave the row temporarily inconsistent at commit time.
* Two representations of the same money exist (lines and header aggregates) → reconciled on every
  write and monitored as an integrity metric (`Σ lines = header` must hold for every certified IPC).
* Advisory locking is a global resource per contract: long-running certification transactions hold it;
  the certification path is therefore kept deliberately short (no PDF rendering, no exports inside the
  transaction — those are queued through the outbox).

**Follow-ups**

* Certification is implemented once, in the domain layer, and never assembled ad hoc in a view or a
  serializer.
* A concurrency test (two parallel certifications) is part of the blocking suite.
* If a future PostgreSQL version relaxes generated-column chaining, this ADR is revisited; the
  identity CHECKs would remain as a second line of defence regardless.

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Trust `previous_*`/`cumulative_*` from the client** | Explicitly forbidden by the requirements; it is the single most damaging input in the system |
| **Compute previous values on the fly at read time everywhere** | Makes the same number derivable in several ways (report vs document vs API), which is exactly how "the system says something different from the certificate" bugs happen; certification must freeze the numbers it used |
| **GENERATED columns chaining `cumulative_* ← current_* ← lines`** | **Not expressible in PostgreSQL** — a generated column may not reference another generated column. Discovered during Phase 0 when the definition failed to create, and the reason derived IPC columns are stored instead |
| **A trigger that recomputes header totals on any header/line change** | Recursive, hard to reason about, and it would silently "fix" a wrong header rather than refusing it; explicit identity CHECKs make violations visible and let the certification transaction own the write |
| **Application-only validation of the arithmetic** | A service bug then becomes a stored financial falsehood; the database must be able to refuse an inconsistent row (Phase 0 proved it does: a forged `vat_amount` was rejected) |
| **Serializable isolation instead of explicit locks** | Correct but retry-heavy under concurrent certification and slower for the common case; explicit per-contract advisory locking is simpler to reason about and to test. `SERIALIZABLE` remains available for specific aggregates |
| **Optimistic `version` check alone (no advisory lock)** | Two certificates can still race on reading the previous position; the `version` column protects a row, not the contract's cumulative sequence |

## How this will be verified

1. **Phase 0 (done):** a certificate claiming `previous_work_value = 999,999` with no prior certified
   IPC was refused (`IPC_PREVIOUS_VALUES_INVALID`); a forged VAT figure was refused by
   `ck_ipcs_total_identity`; after certification, editing commercial columns raised `IPC_FROZEN`,
   editing lines raised `IPC_LINES_FROZEN`, editing the snapshot raised `IMMUTABLE_FIELD`, and deleting
   a snapshot row raised `IMMUTABLE_ROW_DELETE`.
2. Integration: certified history is the only source of previous values; a certificate for a period
   overlapping a non-cancelled one is refused.
3. Concurrency: two parallel certifications ⇒ exactly one succeeds; total certified revenue equals the
   sum of exactly one certificate's work value.
4. Integrity metric: for every certified IPC, `Σ lines = header` and
   `cumulative = previous + current` hold; any violation is an alert, not a warning.
