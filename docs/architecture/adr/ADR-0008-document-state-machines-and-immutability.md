# ADR-0008 — Explicit document state machines; certified and posted documents are immutable

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Application Architect, Financial Domain Architect
- **Related:** [J](../J-document-lifecycle.md), [L](../L-audit-logging.md),
  [I §7](../I-financial-architecture.md), [ADR-0005](ADR-0005-contract-value-ledger.md), db/03–db/08

## Context

Requirement 15: financial documents require controlled lifecycle/status transitions.
Requirement 16: certified/posted financial history must not be silently edited.

Real-world pressures that push the other way:

* A quantity is mistyped and the certificate has already been sent to the client.
* A VO amount changes because the client issued a revised instruction.
* A cost was booked to the wrong cost code and month-end is two days away.
* An administrator "just needs to fix" a status to unblock a workflow.

If any of these can be satisfied by editing a record, then the system cannot be used as evidence in a
dispute, the audit trail becomes decorative, and the financial dashboards are only as trustworthy as
the last person in a hurry.

## Decision

**Every financially significant document has an explicit state machine; transitions are executed
through one service; documents are immutable from the moment they carry consequences; corrections are
reverse-and-reissue with a reason.**

1. **States and transitions are declared, not ad hoc.** A registry maps
   `(entity_type, from_status, action) → {permission, guards, effects}`. An unlisted transition is
   refused with `409 invalid_transition`. No API accepts a writable `status` field — the API exposes
   intent endpoints (`POST /ipcs/{id}/certify`), not `PATCH {status: …}`.
2. **One executor.** `workflow.transition()` loads the row `FOR UPDATE`, authorizes (permission +
   project scope + step-up + separation of duties), runs the guards, applies effects, appends status
   history, writes the audit row and enqueues outbox events — all in the caller's transaction.
3. **Immutability from a defined point** per document ([J §3](../J-document-lifecycle.md)):
   variation orders from first submission; BOQ items and budget lines from approval; IPC header,
   lines, deductions/additions and snapshot from certification; expenses from posting; collections
   from posting; document versions from upload; ledger, approval actions and audit rows from insert.
4. **Two independent enforcement layers:**
   * **Grants:** the runtime role holds no `UPDATE`/`DELETE` on append-only tables
     (`audit_logs`, `contract_value_ledger`, `ipc_snapshots`, `approval_actions`).
   * **Triggers:** freeze functions name the protected columns explicitly and raise a named error
     (`IPC_FROZEN`, `VO_FROZEN`, `IPC_LINES_FROZEN`, `IMMUTABLE_FIELD`, `IMMUTABLE_ROW_DELETE`),
     so a violation is a *specific*, actionable message rather than a generic permission error.
5. **Reversal is a first-class document**, not a delete: it carries the actor, timestamp, reason,
   a link to the reversed document and is itself immutable. Reversals do not erase the original's
   effect on history; they add a compensating one.
6. **No hard delete of business documents.** Master data uses soft delete (`deleted_at`) with partial
   unique indexes; documents are archived, never destroyed while referenced by a financial record.

## Consequences

**Positive**

* What is in the database is evidence: a certificate's numbers at certification time, and the state of
  every document at any point in its life, are recoverable.
* The set of legal moves is data — it can be enumerated, tested exhaustively and rendered in the UI
  without duplicating rules.
* Silence is impossible: an attempt to change a frozen document fails loudly with a named error, and
  in production that error is also a security/ops signal ([Q](../Q-observability.md)).
* Corrections are visible as business events ("certificate 3 reversed for reason X, certificate 4
  issued"), which is precisely what an auditor or a client wants to see.
* The design also protects against the *inside* job: no support engineer, operator or admin has a code
  path that can edit a certified certificate.

**Negative / costs to manage**

* Users must learn "reverse and re-issue" instead of "edit". This is a training and UX obligation:
  the UI must offer the reversal path prominently, pre-fill the correction, and explain the
  consequence (the next certificate reflects it).
* More rows and more documents over time (a corrected VO is two records) — acceptable; storage is
  cheap and disputes are expensive.
* Mistyped *drafts* must be freely editable, otherwise the discipline becomes obstructive; the line is
  drawn at the point the document gains consequences.
* Freeze triggers must be maintained as columns are added — a new column on a frozen table is
  unprotected by default unless the trigger's column list is updated (the whitelist-only pattern, and
  its subtle `TG_ARGV` NULL pitfall, is documented in [J §3](../J-document-lifecycle.md) and covered by
  a schema test).

**Follow-ups**

* Every frozen table gets an immutability smoke test (attempt the forbidden update, assert the named
  error) — including the no-argument trigger form.
* The transition registry is the single source for the UI's available actions, so the frontend never
  invents a transition.
* Reversal reasons are mandatory (minimum length enforced in the schema) and always audited.

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Editable records with a "locked" flag checked in the UI** | UI flags are not authorization and not integrity; one direct API call and history is gone |
| **Full audit-only approach (everything editable, rely on the audit log to see who changed what)** | The *current* state would still be wrong: a report or a client-facing certificate would show edited numbers, and reconstructing "what the certificate said when it was signed" would require replaying history |
| **Soft-delete + recreate on correction** | Loses the linkage between the wrong and the corrected document; the client-facing register would show gaps instead of an explanation |
| **Optimistic locking (`version`) only** | Prevents lost updates, not impermissible ones — a stale-but-authorized client could still change a certified value |
| **Database-only triggers without domain transitions** | Triggers cannot express authorization, SoD or workflow state; they are the *last* line, not the mechanism |
| **Status as a free-text field with application-side rules** | No enumeration, no exhaustive tests, and every service reinvents the rules; also makes "invalid status" a runtime surprise |

## How this will be verified

1. **Phase 0 (done):** editing an approved BOQ item raised `BOQ_LOCKED`; editing an approved VO raised
   `VO_FROZEN`; editing certified IPC commercial columns raised `IPC_FROZEN`; editing certified IPC
   lines raised `IPC_LINES_FROZEN`; editing or deleting an IPC snapshot raised `IMMUTABLE_FIELD` /
   `IMMUTABLE_ROW_DELETE`; `UPDATE`/`DELETE` on `audit_logs`, `contract_value_ledger` and
   `ipc_snapshots` were denied at the grant level for `app_rw`.
2. Conformance suite: for every frozen document type, an update of a protected column must raise the
   expected named error, and every state must have an exhaustive transition test (legal moves succeed,
   illegal moves return `409`).
3. E2E: a reversed certificate leaves the original untouched, creates a compensating document, appears
   in both the register and the audit trail, and the contract's certified revenue reflects the net
   position.
4. API contract test: no endpoint accepts `status` as a writable field.
