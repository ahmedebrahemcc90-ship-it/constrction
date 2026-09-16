# ADR-0009 — Append-only, hash-chained, partitioned audit log with off-site checkpoints

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Security Engineer, Database Architect
- **Related:** [L](../L-audit-logging.md), [Q](../Q-observability.md), [O](../O-backup-disaster-recovery.md),
  [G §7](../G-authorization-rbac.md), db/10, db/14

## Context

Requirements 17 (audit sensitive actions), 16 (no silent edits to financial history) and 3–6
(server-side authorization, project scoping) mean the audit trail is not a nice-to-have: it is the
mechanism by which the system can *prove* what happened.

Threats the audit design must survive:

* a tenant user or an insider editing history through the application;
* an operator or DBA with direct database access rewriting rows to cover tracks;
* the audit table becoming the largest table in the database and slowing down every financial write;
* the log becoming a privacy liability (it captures before/after payloads).

## Decision

**The audit log is append-only by privilege, tamper-evident by hash chain, efficient by partition, and
verifiable from outside the database.**

1. **Two complementary sources:**
   * row-change triggers (`app.audit_row_change`) on every audited table — guarantees that a data
     change without an audit row is impossible, even if application code forgets;
   * semantic events written by services through `app.audit_append(...)` — captures *intent*
     (`ipc.certified`, `vo.approved`, `role.permissions_changed`, `auth.login.failed`,
     `financials.exported`, `document.downloaded`, `platform.elevation.granted`) with actor, reason,
     request id and a human-readable entity label.
2. **Written in the same transaction as the change** — the audit is part of the commit, not a
   fire-and-forget side effect. A rolled-back transaction leaves no audit row, which is correct: the
   change did not happen.
3. **INSERT-only by privilege.** No application role holds `UPDATE` or `DELETE`; `app_rw` has
   `INSERT`/`SELECT` only, and the trail is exposed read-only for reporting through
   `reporting.v_audit_trail`. Phase 0 verified the denial at the grant layer.
4. **Per-company SHA-256 hash chain:** `row_hash = sha256(prev_hash ‖ company_id ‖ chain_seq ‖
   canonical_payload)`, with `chain_seq` allocated under `pg_advisory_xact_lock(hashtext('audit_chain:' ‖ company_id))`
   so the chain is strictly linear even under concurrency. The chain is per tenant, so one tenant's
   volume cannot break another's and a single tenant's trail is self-verifying when exported.
5. **Monthly partitions** with `app.ensure_audit_partitions()` pre-creating three months ahead;
   indexes on `(company_id, …)` for timeline and forensic queries; retention by detaching old
   partitions into an `archive` schema after encrypted export.
6. **Off-site checkpoints.** A scheduled job writes the covered sequence range, row count, head hash
   and an encrypted JSONL export to immutable off-site storage. This is what makes the chain
   *tamper-evident against a DBA*: rewriting the chain locally cannot match a previously exported
   checkpoint hash.
7. **Verification as a job and as a metric.** `app.verify_audit_chain(company_id)` recomputes every
   hash and reports the offending sequence with a reason; it runs incrementally nightly, fully weekly,
   and its result feeds a `must stay 0` integrity metric that pages on failure.
8. **Redaction at write time**: no passwords, tokens, MFA secrets, full bank details or document
   contents; large payloads are referenced, not embedded; the curated view exposes the trail without
   before/after JSON for users who should not see commercial values.
9. **Actors are stored as ids without a foreign key** so that anonymising a user account cannot erase
   who approved a financial document.

## Consequences

**Positive**

* A silent edit is detectable even when performed with superuser rights — Phase 0 demonstrated the
  exact failure message for a tampered row: `2 | row_hash mismatch (content altered)`.
* Because the trigger layer is generic, adding a new audited table is a one-line binding rather than a
  service-by-service obligation.
* The trail is queryable per document ("show me this certificate's history") which is what users
  actually need in a dispute, not a raw log viewer.
* Partitioning keeps the hot table small; retention is an operational decision (detach/archive)
  rather than a mass `DELETE`.
* The checkpoint export gives a customer-facing assurance story: "we can prove the trail you reviewed
  last month has not changed since".

**Negative / costs to manage**

* Roughly one extra insert per audited change and a per-company advisory lock per append — measured
  overhead is expected under 10 % of the transaction and is benchmarked in [S §9](../S-testing-strategy.md);
  the lock is per tenant, not global, so contention stays local.
* Timestamps are not part of the canonical payload — they are covered by the row's own columns and the
  before/after JSON; a chain verifier must therefore read columns, not a serialized blob.
* Payload JSON grows; the cap and the reference-don't-embed rule must be honoured in review.
* Deferred constraint/FK tricks and cascading deletes interact badly with triggers — the audited tables
  avoid `ON DELETE CASCADE` into frozen documents, which is already a modelling rule.
* Audit rows for *every* row change are verbose for bulk operations (a 20k-row import) → bulk imports
  audit the batch and its commit as a semantic event plus the resulting row-level changes in the
  target tables, and the import staging rows are **not** individually row-audited.

**Follow-ups**

* Verification results themselves are audited, and a failed nightly verification is a P1 alert.
* A "document timeline" UI read-model is built from this table, company-scoped.
* Retention/legal-hold interactions are reviewed with the owner (statutory windows differ from
  operational ones).

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Application logs as the audit trail** | Mutable, prunable, not transactionally tied to the change, no before/after guarantee, and no way to prove integrity. Logs are for operations; the audit trail is evidence |
| **A separate audit database or external service** | Adds a component that can be unavailable exactly when a financial transaction commits; and cross-system consistency (audit written but business rolled back, or vice versa) becomes an unsolvable distributed problem for no operational gain at this scale |
| **A blockchain / append-only ledger service** | Complexity and cost with no benefit over a per-tenant hash chain plus off-site checkpoints; operators cannot debug it |
| **Hash chain without off-site checkpoints** | Only detects tampering by actors who cannot recompute the chain — i.e. it fails exactly against a DBA. Checkpoints are the part that makes the claim true |
| **Triggers only, no semantic events** | Provides "what changed" but not "why" — approvals, reasons, exports, downloads and denials would be invisible |
| **Append via an asynchronous queue (write-behind)** | Loses audit rows on crash and cannot be part of the transaction; unacceptable for an evidence trail |
| **No partitions, delete old rows by retention** | Mass deletes on the largest table, and a retention action that is indistinguishable from an attack |
| **Audit everything, including reads** | Volume and privacy cost without proportionate value; the deliberate exceptions (financial exports and document downloads) are the ones with real risk |

## How this will be verified

1. **Phase 0 (done):** three chained rows verified clean (`0` bad sequences); a superuser edit of row 2
   was reported as `row_hash mismatch (content altered)`; `app_rw` was denied `UPDATE`/`DELETE` on
   `audit_logs`.
2. CI/schema tests: the runtime role holds no `UPDATE`/`DELETE` on append-only tables; every audited
   table has its row trigger bound; `chain_seq` is unique per company.
3. Operational: nightly checkpoint export verified against the restored backup during the monthly
   restore drill (the chain must verify *in the restored copy too*).
4. Volume/performance: benchmark that audit overhead stays below 10 % of the financial transaction and
   that timeline queries stay under a documented threshold with partitions in place.
