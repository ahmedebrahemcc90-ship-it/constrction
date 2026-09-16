# J. Document Lifecycle and State-Machine Architecture

Financial documents must move through **controlled** transitions, must be **immutable** once they
carry consequences, and must be **correctable** without erasing history.

---

## 1. State machines (V1)

### Variation Order
```
        ┌────────────────────── return_for_changes (audited) ─────────────────────┐
        ▼                                                                         │
   [draft] ─submit→ [submitted] ⇄ [under_review] ─approve→ [approved] ─supersede→ [superseded]
                                       │                                             │
                                       ├─reject→ [rejected]                          │
                                       └─cancel→ [cancelled] ◀──cancel──────────────┘
```
Guards: `approve` requires `variation.approve` **and** SoD (submitter ≠ approver when configured)
**and** an approval workflow instance at its final step. Only `approved` posts to the contract value
ledger, exactly once.

### IPC (client certificate)
```
[draft] ─submit→ [submitted] → [under_review] ─certify→ [certified] ─approve→ [approved] ─post→ [posted]
                    │                  │                                                  │
                    │                  └─reject→ [rejected]                              ▼
                    └─cancel→ [cancelled]                                    [partially_paid] → [paid] → [closed]
                                                                                          │
                                                            [certified…paid] ─reverse→ [reversed] (new reversing document)
```
Guards per transition:

| Transition | Requires |
|---|---|
| `submit` | `ipc.create/submit`, at least one line, no period overlap with a non-cancelled IPC |
| `certify` | `ipc.certify` + AAL2, contract `active`, BOQ `approved`, all guards of [I §4.3](I-financial-architecture.md), and the advisor lock |
| `approve` | `ipc.approve` + SoD |
| `post` | `ipc.post` + AAL2; this is what makes the certificate accounting-relevant (and can trigger notifications) |
| payment states | driven **only** by collection allocations reaching `total_payable_incl_vat` |
| `reverse` | `ipc.reverse` + reason; creates a reversing certificate and stops the original from accepting further allocations |

### Contract
`draft → active → (on_hold ⇄ active) → substantially_completed → completed → closed`, plus
`terminated`. Amendments are ledger entries, not field edits.

### BOQ
`draft → in_review → approved → superseded/archived`. Items are editable **only** in `draft`;
afterwards changes flow through `boq_revisions` + `boq_item_versions` (+ a ledger entry if the value
changes).

### Budget
`draft → submitted → under_review → approved` (one approved version per project) → `superseded`.
Post-approval movement is a `budget_transfer` (explicit, approved, audited) or a new version.

### Expense / Collection
`draft → submitted → approved → posted → paid/reconciled`, plus `rejected`, `cancelled`, `reversed`.

### Document (file)
`draft → active → superseded/archived`, plus `quarantined` while an AV scan is inconclusive;
versions are append-only ([M §4](M-file-storage-security.md)).

### Approval request
`pending → approved | rejected | returned | cancelled | expired`, one open request per target
document at a time.

---

## 2. Transition enforcement (one mechanism for all documents)

```text
TRANSITIONS = {
  ("ipc", "draft", "submit"):    Transition(permission="ipc.submit",   requires=[...guards], effect=[...]),
  ("ipc", "submitted", "certify"): Transition(permission="ipc.certify", requires=[...], effect=[...]),
  ...
}
```

Every transition is executed through one service:

```text
workflow.transition(document, action, actor, payload)
  1. load the document row FOR UPDATE (tenant-scoped)
  2. look up the transition for (type, current_status, action)   -> unknown ⇒ 409 invalid_transition
  3. authorize: permission + project scope + AAL + SoD
  4. run guards (domain rules; may lock related rows)
  5. apply effects (field changes, snapshots, ledger postings, allocations)
  6. append status history + audit row (+ outbox event) in the SAME transaction
  7. commit
```

Consequences: there is exactly one place where status changes; the set of legal moves is data
(a registry), so it is testable and reviewable; and no endpoint can "set status" directly — the API
exposes `POST /ipcs/{id}/certify`, not `PATCH /ipcs/{id} {status: …}`.

---

## 3. Immutability rules

| Document | Frozen from | Frozen content | Still changeable |
|---|---|---|---|
| Variation Order | first submission | amounts, contract, project, instruction data, category | lifecycle stamps, superseding link |
| `contract_value_ledger` | insert | everything (no UPDATE, no DELETE, grants revoked) | nothing |
| BOQ item | BOQ approval | qty, rate, code, unit, amounts | nothing (use a revision) |
| Budget line | budget approval | amounts, cost-code/WBS attribution | nothing (use a transfer or new version) |
| IPC header | certification | period, previous/cumulative values, retention %, VAT, net payable, snapshot link | status, settlement figures, notes |
| IPC lines/deductions/additions | certification | quantities, rates, amounts | nothing |
| `ipc_snapshots` | insert | everything | nothing |
| Expense | approval (`draft` editable) | amount, VAT, cost code, WBS/BOQ link, party, date | status, posting stamps |
| Collection | posting | amount, contract/client, date, method, bank reference | status, reconciliation, allocations |
| `approval_actions` | insert | everything | nothing |
| `audit_logs` | insert | everything | nothing |
| Document version | insert | storage location, size, checksum, filename | scan metadata only |

Implementation: `FORCE`-enabled grants (no UPDATE/DELETE for the runtime role on append-only tables)
**plus** freeze trigger functions that name the immutable columns explicitly. Both were verified in
Phase 0 — including the discovery that an empty-argument immutability guard must handle `TG_ARGV`
being `NULL`, otherwise the guard is silently vacuous.

---

## 4. Correction patterns (history is never rewritten)

| Situation | Correct response | Never |
|---|---|---|
| Wrong quantity on a **draft** IPC | Edit freely (draft is not evidence) | — |
| Wrong quantity on a **certified** IPC | Reverse the certificate (with reason) and issue a corrected one in the next period | Editing certified lines |
| Client rejects part of a certified amount | New IPC line with a negative quantity, or an `other_deduction` line with evidence | Deleting the line |
| VO amount wrong before approval | Edit (draft) | — |
| VO amount wrong after approval | `supersede` + new VO (the original stays, posted ledger entry stays, and a corrective ledger entry is added if value changes) | Editing an approved VO or deleting its ledger entry |
| Expense entered against the wrong cost code after posting | Reverse + re-record with a link (`reverses_expense_id`) | Changing the cost code in place |
| Collection applied to the wrong certificate | Reverse the allocation (audited) and re-allocate | Editing history |
| BOQ item wrong after approval | BOQ revision (`boq_revisions` + `boq_item_versions`) and, if value changes, a ledger entry | Editing approved items |
| VAT rate mis-set on a document | Corrective document for the period; the rate snapshot stays for the original | Retroactive re-rating |

Every reversal carries: who, when, why (`reversal_reason`), a link to the reversed document, and an
audit row. Reversals do not delete the original's effect on history; they add a compensating one.

---

## 5. Approval workflow integration

1. On `submit`, the matching `approval_workflow` is selected by entity type, conditions
   (`{"min_amount": "50000.00"}`, category filters) and priority; the winning definition is
   **snapshotted** onto the request so later template edits cannot change an in-flight approval.
2. Steps are executed in order; each step resolves its approvers at decision time (role, user, or
   project role) so staffing changes take effect without rewriting history.
3. A decision writes an immutable `approval_actions` row (actor, role, step, comment, IP, request id,
   on-behalf-of when delegated).
4. The document's transition happens **in the same transaction** as the final approval decision — an
   approval cannot be recorded without its effect, and vice versa.
5. Reject/return requires a comment; return moves the document back to `draft` with an audited
   transition (lines become editable again, and the previously granted approvals are invalidated).
6. Delegation and time-boxing are supported for real-world leave; every delegated decision records
   both the delegate and the principal.
7. Escalation: `escalate_after_hours` on a step schedules a reminder/escalation job
   ([N](N-background-jobs.md)); it never auto-approves.

---

## 6. Numbering

Document numbers are allocated inside the same transaction as the insert, from `number_series`, using
`SELECT … FOR UPDATE` on the series row (`app.next_document_number`). Format is per company/type
(`IPC-2026-000317`). Numbers are displayed, never used as identifiers, and never reused. A cancelled
document keeps its number; gaps are acceptable (they are not an audit problem because every document
and its cancellation is auditable).

---

## 7. What the lifecycle design deliberately prevents

| Prevented outcome | Mechanism |
|---|---|
| A certified certificate silently changed after the client signed it | Freeze trigger + grants + snapshot hash |
| Two certificates covering the same period, double-counting revenue | EXCLUDE constraint on non-cancelled IPC periods + certification guard |
| A VO approved twice, doubling contract value | Ledger idempotency key + posting function + `VO_FROZEN` |
| An approval granted by an edited workflow template | Workflow snapshot at submit |
| A filed document quietly replaced | Document versions are append-only; the file's checksum is stored |
| "Cleanup" of inconvenient history | No DELETE permission on business documents; reversal + reason is the only path |
| Status jump forged by the API | Transition registry + `POST /…/action` endpoints, no writable `status` field |
