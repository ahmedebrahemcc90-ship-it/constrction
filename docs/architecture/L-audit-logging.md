# L. Audit-Log Architecture

The audit log answers: **who did what, when, to which tenant-owned object, from where, with what
evidence, and has anything been altered since?**

---

## 1. Design requirements

| # | Requirement | Implementation |
|---|---|---|
| 1 | Audit a change **in the same transaction** as the change itself | `app.audit_append` is called by the service inside the business transaction; subscription-based or after-commit logging is not used for mandatory events |
| 2 | Append-only, no exceptions | No UPDATE/DELETE grants for any application role; a BEFORE UPDATE/DELETE trigger refuses tampering even for the owner |
| 3 | Tamper-**evident** | Per-company SHA-256 hash chain (`prev_hash` → `row_hash`), with a verification function |
| 4 | Tamper-evident even against a DBA | Periodic **checkpoints** (sequence range + head hash + encrypted export) stored off-site, so recomputing the chain locally does not hide an edit |
| 5 | Multi-tenant | `company_id` on every row, RLS-scoped like any tenant table |
| 6 | Efficient at scale | Monthly range partitions, indexes on (company, time), (company, entity), (company, actor), (company, action) |
| 7 | Searchable without leaking | Payload (before/after JSON) is visible to `audit.read` holders only and redacted for everyone else; a curated view exposes the trail without payloads |
| 8 | Retention-aware | Company-configurable retention (default 7 years); expired partitions are archived to encrypted object storage, never dropped silently |
| 9 | Useful to non-engineers | Every row carries a human label (`entity_label`, e.g. `IPC-2026-000317`) and a bilingual action code |

---

## 2. Two sources of truth (deliberately redundant)

| Source | Written by | Captures | Weakness covered by the other |
|---|---|---|---|
| **Row-change audit** (`app.audit_row_change` triggers) | The database | Insert/update/delete of every audited table, with full before/after JSON | Fires even if application code forgets; cannot express *intent* |
| **Semantic audit** (`app.audit_append` from services) | The application | Business actions: `ipc.certified`, `vo.approved`, `role.permissions_changed`, `auth.login.failed`, `financials.exported`, `document.downloaded`, `platform.elevation.granted` | Explains *why*, records context (reason, step, delegation) |

A sensitive operation therefore produces at least two rows — the intent and the data change — and a
missing one is itself detectable (a certification with no semantic row is a test failure).

---

## 3. What is audited (mandatory set)

**Row-level (triggers):** `contracts`, `contract_value_ledger`, `boqs`, `boq_items`,
`variation_orders`, `variation_order_lines`, `ipcs`, `ipc_lines`, `ipc_deductions`, `ipc_additions`,
`ipc_snapshots`, `expenses`, `collections`, `collection_allocations`, `budgets`, `budget_lines`,
`budget_transfers`, `projects`, `project_members`, `memberships`, `membership_roles`,
`role_permissions`, `roles`, `company_settings`, `tax_rates`, `number_series`, `documents`,
`document_versions`, `document_links`, `approval_requests`, `approval_actions`, `cost_codes`,
`wbs_nodes`, `import_batches` (commits/cancellations), `project_forecast_overrides`.

**Semantic (services):** authentication and session events, MFA changes, permission/role changes,
project access grants/revocations, invitation lifecycle, document download/export, report exports,
break-glass elevation, approval decisions, every state transition, reversal with reason, settings
changes affecting money (VAT, retention defaults, numbering), and integration/job anomalies that
change data.

**Explicitly not audited** (too noisy, low value): read-only list/detail views, dashboard renders,
dropdown lookups, health checks — with the exception of financial **exports** and document
**downloads**, which are always audited because they move data outside the system.

---

## 4. Hash chain

```
row_hash = sha256( prev_hash || company_id || chain_seq || canonical_payload )

canonical_payload = jsonb_build_object(
    company_id, actor_user_id, actor_membership_id, actor_kind, action,
    entity_type, entity_id, entity_label, project_id,
    before, after, changed, reason, source, request_id)
```

Properties:

* The chain is **per company**, so one tenant's volume cannot break another's chain and an export of
  one tenant's trail is self-verifying.
* `chain_seq` is allocated under `pg_advisory_xact_lock(hashtext('audit_chain:' || company_id))`,
  guaranteeing a single linear chain per company under concurrency.
* `app.verify_audit_chain(company_id)` recomputes every hash and returns any bad sequence number with
  a reason. **Verified in Phase 0:** three chained rows verify clean, and a *silent superuser edit* of
  one row is reported as `row_hash mismatch (content altered)`.
* **Checkpoints**: a scheduled job writes the covered sequence range, row count, head hash and an
  encrypted JSONL export to off-site storage. Even a DBA who rewrites the whole chain locally cannot
  match a previously exported checkpoint hash. Verification results are themselves recorded, and a
  mismatch raises a P1 alert ([Q](Q-observability.md)).
* `hash_key_version` is stored per row so the hashing scheme can be rotated without invalidating old
  rows.

---

## 5. Operations

| Concern | Approach |
|---|---|
| Write cost | One extra INSERT per audited change, in the same transaction; partitioned table with narrow indexes; payload JSONB is capped (large blobs are referenced, not embedded) |
| Read cost for the UI | Indexed by (company, entity) for a document timeline; the payload is fetched lazily |
| Partition management | `app.ensure_audit_partitions()` pre-creates 3 months ahead; the scheduler runs it daily and pages on failure |
| Retention | Partitions older than the retention window are detached into the `archive` schema and exported encrypted off-site before being dropped; `is_legal_hold` on documents does not block audit retention (financial trails are kept longer) |
| Verification | Nightly incremental verification of the previous day plus a weekly full-chain verification per company; restore-tested during DR drills |
| Access | `audit.read` (AAL2), company-scoped; platform operators require break-glass; the UI shows a document's timeline inline (IPC, VO, contract, expense) |
| Anti-noise | Routine reads are not logged; noisy technical events go to application logs, not the audit trail |

---

## 6. Privacy and actor identity

* Actors are stored as **user ids without a foreign key** so that anonymising a user account (a future
  GDPR-style request) cannot erase who approved a financial document.
* Before/after payloads are **redacted at write time** for fields that must never be stored in an
  audit trail: passwords, tokens, MFA secrets, full bank details (only a masked account reference is
  kept), and document contents (only metadata and checksum).
* IP addresses and user agents are retained because they are evidence for financial disputes; the
  retention policy applies to them together with the row.
* A document timeline shown to a tenant shows only that tenant's rows (RLS), and the payload view is
  permission-gated.

---

## 7. What an auditor can reconstruct

1. Every state a document passed through, with the actor, timestamp, comment and (delegated) role.
2. The exact values before and after each change of a financial field.
3. The chain of custody of a file: upload, scan result, checksum, version history, every download.
4. The basis of every approval: which workflow version, which step, which decision, with what reason.
5. Every attempt to act outside one's scope: denied authorization and rejected cross-tenant
   attempts are logged (they are security signals, not just errors).
6. Every access by support/platform staff, with the reason they gave.
