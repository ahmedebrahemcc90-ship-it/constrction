# Security Checklist

Status of every control that must hold before and after launch. Aligned with **OWASP ASVS 4.0 Level 2**
(target) and the OWASP Top 10:2021 mapping in [R §5](R-security-threat-model.md).

**Legend**

| Mark | Meaning |
|---|---|
| **✅ VERIFIED** | Demonstrated on a real PostgreSQL 16.2 instance during Phase 0, or a design-time check that cannot be invalidated by coding |
| **🔷 DESIGNED** | Specified, with the authority and mechanism named; must be implemented and tested in Phase 1 |
| **⏳ OWNER** | Requires an owner decision or an external input (see [open-decisions.md](open-decisions.md)) |
| **⚠️ EXCEPTION** | Consciously carried risk, with an owner, a compensating control and a review date |

---

## 1. Tenant isolation (the product's most dangerous failure)

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 1.1 | Every tenant-owned table carries `company_id` | 🔷 DESIGNED | [E §12](E-database-design.md); CI lint asserts index prefix and column presence |
| 1.2 | RLS enabled **and forced** with a policy on every tenant table | ✅ VERIFIED | Runtime role `app_rw` saw only its own company's rows |
| 1.3 | Fail-closed behaviour with no tenant context | ✅ VERIFIED | Zero rows returned, never all rows |
| 1.4 | Cross-tenant INSERT refused by `WITH CHECK` | ✅ VERIFIED | `new row violates row-level security policy for table "projects"` |
| 1.5 | Runtime role cannot bypass RLS | ✅ VERIFIED | `is_superuser=f`, `can_bypass_rls=f`, `can_create_role=f` |
| 1.6 | Composite FKs make cross-tenant references unstorable | ✅ VERIFIED | `fk_contracts_client` refused Company B's client |
| 1.7 | Project-scoped keys stop cross-project references | ✅ VERIFIED | `fk_ipc_lines_boq_item` refused another project's BOQ item |
| 1.8 | Tenant resolved server-side only; `company_id` from clients is never authoritative | 🔷 DESIGNED | [F §4](F-tenant-isolation.md), [G §4](G-authorization-rbac.md); principle 3 |
| 1.9 | `SET LOCAL` context per transaction + reset on pool release | 🔷 DESIGNED | `app.reset_tenant_context()`, leak test in [S §4](S-testing-strategy.md) |
| 1.10 | Two-tenant isolation suite blocks CI on every endpoint | 🔷 DESIGNED | [S §4](S-testing-strategy.md) items 1–10 |
| 1.11 | Cache, search, export and storage channels are tenant-scoped | 🔷 DESIGNED | Key prefixes, `tenants/<company_id>/` object paths, export content assertions |
| 1.12 | Platform-operator access requires audited, reasoned, time-boxed break-glass | 🔷 DESIGNED | [G §7](G-authorization-rbac.md); reason ≥ 10 chars enforced in schema |

---

## 2. Authentication and session management

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 2.1 | Passwords hashed with Argon2id via an established library | 🔷 DESIGNED | Django `PASSWORD_HASHERS[0]`; re-hash on login when parameters change |
| 2.2 | Password policy: ≥ 12 chars, breached-list check, no forced rotation | 🔷 DESIGNED | [H §2](H-authentication-sessions.md) |
| 2.3 | Opaque, database-backed sessions; token stored only as `sha256` | 🔷 DESIGNED | A database leak yields no usable session |
| 2.4 | Cookie flags: `__Host-` prefix, `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/` | 🔷 DESIGNED | [H §3](H-authentication-sessions.md) |
| 2.5 | Session id rotated on login, privilege elevation and password change | 🔷 DESIGNED | Anti-fixation |
| 2.6 | Idle (60 min) and absolute (12 h) timeouts; device list with revocation | 🔷 DESIGNED | Platform operators: 4 h |
| 2.7 | CSRF token bound to the session + `Origin` check on mutations | 🔷 DESIGNED | Same-origin CORS by default; no wildcard |
| 2.8 | Brute-force controls: per-IP and per-account rate limits, progressive lockout, uniform errors | 🔷 DESIGNED | [H §4](H-authentication-sessions.md); no user enumeration |
| 2.9 | MFA (TOTP) mandatory for platform operators and privileged roles; recovery codes hashed, single-use | 🔷 DESIGNED | Enforced by role, not by UI hint |
| 2.10 | Step-up authentication (AAL2, recent factor ≤ 15 min) for certify/approve/post/export/roles | 🔷 DESIGNED | Service-layer check returning `403 auth.step_up_required` |
| 2.11 | Password reset invalidates all sessions; single-use hashed token, 30-min TTL | 🔷 DESIGNED | Reset itself audited |
| 2.12 | Login attempts recorded with outcome; no credential material logged | 🔷 DESIGNED | `login_attempts`; redaction filter |
| 2.13 | Membership suspension/revocation kills sessions and permission caches | 🔷 DESIGNED | [H §6](H-authentication-sessions.md) |

---

## 3. Authorization and privilege escalation

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 3.1 | Every sensitive operation authorized server-side at a single choke point | 🔷 DESIGNED | [G §4](G-authorization-rbac.md) pipeline (8 steps) |
| 3.2 | UI visibility is never authorization; direct-API parity is tested | 🔷 DESIGNED | Permission-matrix suite runs against the API only |
| 3.3 | Project-level permissions enforced on detail **and** list **and** export endpoints | 🔷 DESIGNED | `scope_queryset`, `require_project` |
| 3.4 | Anti-IDOR: foreign ids return **404**, never 403 (no existence oracle) | 🔷 DESIGNED | [G §4.2](G-authorization-rbac.md) |
| 3.5 | No one can grant a permission they do not hold (`can_grant ⊆ own`) | 🔷 DESIGNED | [G §5](G-authorization-rbac.md); audited denial |
| 3.6 | Separation of duties on VO, IPC, budget, expense approvals (configurable, default on) | 🔷 DESIGNED | [G §6](G-authorization-rbac.md); submitter ≠ approver |
| 3.7 | Delegations bounded (permissions, projects, dates), reasoned, audited — never wider than the delegator | 🔷 DESIGNED | `access_delegations` |
| 3.8 | No writable `status` field on any API; transitions only via action endpoints | 🔷 DESIGNED | [J §2](J-document-lifecycle.md); registry-driven |
| 3.9 | Mass assignment prevented: derived fields absent from write DTOs | 🔷 DESIGNED | Totals, `company_id`, `certified_*` never accepted |
| 3.10 | Route-parity CI check: no state-changing route without an explicit permission | 🔷 DESIGNED | [S §3](S-testing-strategy.md) |

---

## 4. Financial integrity (domain-specific controls)

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 4.1 | No floating point in the financial path | 🔷 DESIGNED | CI schema lint; `numeric`/`Decimal` only ([ADR-0004](adr/ADR-0004-money-representation-and-rounding.md)) |
| 4.2 | Line amounts generated by the database; totals recomputed server-side | ✅ VERIFIED | Generated `amount` columns + identity CHECKs |
| 4.3 | Client-supplied totals ignored (not merely validated) | ✅ VERIFIED | Forged `vat_amount` rejected by `ck_ipcs_total_identity` |
| 4.4 | IPC previous/cumulative values read from certified history only | ✅ VERIFIED | `IPC_PREVIOUS_VALUES_INVALID` on a fabricated claim |
| 4.5 | Only approved VOs change contract value; posting idempotent | ✅ VERIFIED | Same ledger id twice; ledger-derived RCV |
| 4.6 | Certified/posted documents immutable; corrections are reversal + re-issue | ✅ VERIFIED | `IPC_FROZEN`, `IPC_LINES_FROZEN`, `IMMUTABLE_FIELD`, `IMMUTABLE_ROW_DELETE`, `VO_FROZEN` |
| 4.7 | Concurrency controls: per-contract advisory lock, `FOR UPDATE`, EXCLUDE on periods, allocation limits | ✅ VERIFIED (partly) | Locks and constraints exist; the parallel-certification test is a Phase 1 gate |
| 4.8 | Append-only tables deny UPDATE/DELETE at the grant layer | ✅ VERIFIED | `permission denied for table audit_logs / contract_value_ledger / ipc_snapshots` |
| 4.9 | Retention/advance percentages and VAT basis points snapshotted per certificate | 🔷 DESIGNED | `ipc_snapshots`; historical reproducibility |
| 4.10 | Contract value cache reconciled against the ledger nightly; drift is alerted | 🔷 DESIGNED | Integrity metric must stay 0 |
| 4.11 | Over-certification blocked by default; if enabled, flagged on every report | ⏳ OWNER | Open decision D-11 |
| 4.12 | Every financial figure drillable to its source rows | 🔷 DESIGNED | [I §8](I-financial-architecture.md), [ADR-0021](adr/ADR-0021-curated-reporting-not-query-builder.md) |

---

## 5. Input handling, files and documents

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 5.1 | Parameterized queries only; no string-built SQL; raw SQL reviewed | 🔷 DESIGNED | ORM + psycopg 3; least-privilege role limits blast radius |
| 5.2 | Strict CSP without `unsafe-inline`; `nosniff`; `frame-ancestors 'none'` | 🔷 DESIGNED | nginx + app headers ([P §3](P-deployment-vps-docker.md)) |
| 5.3 | Upload type allow-list verified against magic bytes; macros/archives refused; size caps | 🔷 DESIGNED | [M §3](M-file-storage-security.md) |
| 5.4 | Antivirus scan before a file becomes servable; scan failure = not servable | 🔷 DESIGNED | Fail-closed `scan_status` |
| 5.5 | Files private; authorization checked **before** presigning; URLs ≤ 5 min | 🔷 DESIGNED | [M §4](M-file-storage-security.md); downloads audited |
| 5.6 | Object keys server-generated UUIDs under the tenant prefix; filenames never touch storage paths | 🔷 DESIGNED | Path traversal eliminated by construction |
| 5.7 | Excel/CSV parsing hardened (row/size/expansion limits, hardened XML, no formula evaluation) | 🔷 DESIGNED | `defusedxml`, worker limits ([K §7](K-boq-ipc-vo-design.md)) |
| 5.8 | CSV/Excel export formula injection neutralised | 🔷 DESIGNED | `=+-@` prefixed as text in exports |
| 5.9 | No user-controlled outbound fetch (SSRF); renderer containers have no network | 🔷 DESIGNED | [M §5](M-file-storage-security.md), [B §5](B-infrastructure-architecture.md) |
| 5.10 | Document versions append-only; checksums retained; overwrite recoverable | 🔷 DESIGNED | `document_versions`, object versioning |

---

## 6. Audit and monitoring

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 6.1 | Sensitive actions audited in the same transaction as the change | 🔷 DESIGNED | `app.audit_append` + row-change triggers |
| 6.2 | Audit trail is append-only for all application roles | ✅ VERIFIED | `UPDATE`/`DELETE` denied on `audit_logs` for `app_rw` |
| 6.3 | Hash chain detects silent alteration | ✅ VERIFIED | Superuser edit reported as `row_hash mismatch (content altered)` |
| 6.4 | Chain verification is scheduled and alerted; result feeds a must-stay-0 metric | 🔷 DESIGNED | [L §4](L-audit-logging.md), [Q §3](Q-observability.md) |
| 6.5 | Off-site encrypted checkpoints make tampering detectable even against a DBA | 🔷 DESIGNED | [O §2](O-backup-disaster-recovery.md) |
| 6.6 | Payload redaction: no passwords, tokens, full bank details or file contents stored | 🔷 DESIGNED | [L §6](L-audit-logging.md) |
| 6.7 | Document downloads and financial exports audited | 🔷 DESIGNED | Explicit exceptions to read-logging policy |
| 6.8 | Security signals alerted (auth spikes, authorization denials, cross-tenant 404 bursts) | 🔷 DESIGNED | [Q §5](Q-observability.md) |
| 6.9 | Application logs scrubbed and tenant-tagged; no tenant financial values in monitoring | 🔷 DESIGNED | [Q §4](Q-observability.md) |

---

## 7. Infrastructure, secrets and network

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 7.1 | PostgreSQL never publicly exposed (no published port; internal-only network) | 🔷 DESIGNED | [P §5](P-deployment-vps-docker.md); external port probe in the pre-launch checklist |
| 7.2 | Redis/MinIO likewise unpublished; only nginx listens publicly | 🔷 DESIGNED | Compose topology [P §2](P-deployment-vps-docker.md) |
| 7.3 | DB credentials per role (`app_rw`, `app_ro`, `app_migrator`, `app_backup`) with least privilege | ✅ VERIFIED (roles) | db/14; attributes checked in Phase 0 |
| 7.4 | TLS 1.2+, HSTS, auto-renewed certificates with expiry alerting | 🔷 DESIGNED | Certbot + monitoring |
| 7.5 | Rate limiting on auth, imports, exports and downloads | 🔷 DESIGNED | nginx `limit_req`/`limit_conn` + app-level limits |
| 7.6 | Secrets never in Git, images or logs; runtime injection; gitleaks gate | 🔷 DESIGNED | `check --deploy` in CI; redaction filter |
| 7.7 | Containers: non-root, no Docker socket, read-only roots where possible, pinned digests | 🔷 DESIGNED | [P §2](P-deployment-vps-docker.md) |
| 7.8 | Dependency and image scanning with a patch SLA (critical ≤ 72 h) | 🔷 DESIGNED | Trivy, pip-audit, npm audit |
| 7.9 | SSH keys only, no password login, fail2ban, automatic security updates | 🔷 DESIGNED | [P §1](P-deployment-vps-docker.md) |
| 7.10 | Backup credentials separate from app credentials; restores require approval | 🔷 DESIGNED | [O §3](O-backup-disaster-recovery.md) |

---

## 8. Backup, restore and continuity

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 8.1 | Continuous WAL archiving + nightly fulls; RPO ≤ 15 min target | 🔷 DESIGNED | pgBackRest ([ADR-0011](adr/ADR-0011-backup-and-pitr.md)) |
| 8.2 | Off-site copies encrypted client-side with off-host keys | 🔷 DESIGNED | Key escrow documented; provider cannot read |
| 8.3 | Off-site repository immutable for the retention window | 🔷 DESIGNED | Object lock; ransomware/insider deletion control |
| 8.4 | Restores verified automatically and drilled monthly with integrity assertions | 🔷 DESIGNED | [O §4/§6](O-backup-disaster-recovery.md); drill report archived |
| 8.5 | "No backup in 24 h" and WAL lag are P1 alerts | 🔷 DESIGNED | [Q §5](Q-observability.md) |
| 8.6 | Pre-deploy backup + WAL marker recorded | 🔷 DESIGNED | Deployment runbook |
| 8.7 | Audit chain verified **in the restored copy** during drills | 🔷 DESIGNED | Proves evidence survives recovery |
| 8.8 | Rollback path named for every release; breaking changes ship expand/contract | 🔷 DESIGNED | [P §4](P-deployment-vps-docker.md) |

---

## 9. Process, compliance and operations

| # | Control | Status | Evidence / mechanism |
|---|---|---|---|
| 9.1 | No invented government integrations; no ZATCA e-invoicing claim | 🔷 DESIGNED | Requirement 22; positioning recorded as risk R-08 |
| 9.2 | Retention schedule defined and configurable per data class | ⏳ OWNER | Open decision D-06 |
| 9.3 | Tenant offboarding: export → retention countdown → prefix + row deletion, audited | 🔷 DESIGNED | [M §6](M-file-storage-security.md) |
| 9.4 | Access review monthly (roles, memberships, break-glass elevations) | 🔷 DESIGNED | [Q §8](Q-observability.md) |
| 9.5 | Quarterly threat-model and permission-matrix review | 🔷 DESIGNED | [R](R-security-threat-model.md), [G §8](G-authorization-rbac.md) |
| 9.6 | Incident response plan with severity definitions, contacts and evidence handling | ⏳ OWNER | To be written before launch; escalation channel is D-09 |
| 9.7 | Privacy notice, DPAs and customer expectations in writing | ⏳ OWNER | Legal, not technical |
| 9.8 | Penetration test before first production tenant (or documented acceptance) | ⏳ OWNER | Budget and timing decision |

---

## 10. Consciously carried exceptions

| # | Exception | Why accepted | Compensating control | Owner / review |
|---|---|---|---|---|
| ⚠️ E-1 | A host root compromise can read live financial data (database co-located with the app) | Single-VPS constraint in V1; managed DB or a separate host doubles cost | Hardening, least privilege, no public DB port, detectability (audit chain + off-site checkpoints), immutable backups | Owner — review at each release milestone |
| ⚠️ E-2 | A DBA/superuser can read all tenants' data | Unavoidable while operations are in-house at this size | Break-glass policy, audit of elevation, minimised use, monthly review; field-level encryption is open decision D-05 | Owner — revisit with D-05 |
| ⚠️ E-3 | Object-storage RPO is nightly, not continuous | Synchronous replication of file storage is disproportionate in V1 | Object versioning, upload-session traceability, small re-upload cost; stated plainly to customers | Owner — revisit at stage 2 scaling |
| ⚠️ E-4 | Audit-row timestamps are not inside the hash payload | They are columns covered by the row and by checkpoints; excluding them keeps the hasher simple and stable across time zones | Checkpoints record the covered window and head hash off-site | Architect — quarterly |
| ⚠️ E-5 | No user-facing report builder (power users may want one) | Security/consistency/product reasons ([ADR-0021](adr/ADR-0021-curated-reporting-not-query-builder.md)) | Rich parameterised reports, stable exports designed for pivot use, intake process for new catalogue reports | Owner — revisit if demand persists |

---

## 11. What "done" means for this checklist

This checklist is not a one-time artefact:

* every **⏳ OWNER** item must have a decision before the corresponding phase of
  [T](T-implementation-phases.md) completes;
* every **🔷 DESIGNED** item must become **✅ VERIFIED** with a named test or drill before go-live, and
  the verification is linked back into this table;
* **⚠️ EXCEPTIONS** are reviewed at the stated cadence; an exception that is no longer justified becomes
  a work item, not a footnote.
