# R. Security Threat Model

Threat vectors in §4 are numbered **TV-01…TV-46**; the risk *register* uses separate IDs (`R-01…`)
and lives in [risks.md](risks.md).

Method: assets → actors → trust boundaries → abuse cases (STRIDE-flavoured) with concrete attack
vectors, then the defence-in-depth mapping, then the residual risk we accept in writing. Aligned with
OWASP ASVS L2 (target) and the OWASP Top 10:2021 categories.

---

## 1. Assets, ranked by the damage of their loss

| # | Asset | Impact of compromise |
|---|---|---|
| A1 | **Tenant financial data** (contract values, BOQ rates, IPCs, expenses, margins) | Direct commercial harm: a competitor sees a bid's cost structure; a client sees margin; a dispute is lost |
| A2 | **Cross-tenant read access** (any path that lets A see B) | Product-ending loss of trust; contractual breach; regulatory exposure |
| A3 | **Integrity of financial records** (certified IPCs, contract value ledger, audit trail) | Fraud, false certificates, unrecoverable disputes |
| A4 | **Credentials & sessions** | Account takeover; everything above becomes reachable |
| A5 | **Uploaded documents** (contracts, invoices, client correspondence) | Privacy breach; commercially sensitive leakage |
| A6 | **Availability** | Payroll/period-close delays, engineering idle time, SLA breach |
| A7 | **Backups** | Worst case: total, unrecoverable loss |
| A8 | **Reputation / regulatory standing** | Loss of new business; Saudi PDPL exposure |

---

## 2. Actors

| Actor | Motivation | Capability |
|---|---|---|
| Malicious tenant user (insider, or a subcontractor given access) | Steal a competitor's rates; falsify progress; hide overspend | Legitimate account, knows the UI, can call the API directly |
| Disgruntled employee / departing staff | Vandalise or exfiltrate | Privileged account, knows internal processes |
| External attacker (opportunistic) | Mass scanning, credential stuffing, ransomware | Automated tooling, public exploits |
| External attacker (targeted, e.g. competitor) | Data theft | Patient, may pay for a phished credential |
| Hosting/provider insider | Access to volumes/snapshots | Infrastructure-level |
| Well-meaning user | Mistakes that look like attacks (bad import, wrong project) | Legitimate intent, no malice |
| Support/platform engineer | Legitimate operational need | Superuser-level database access |

---

## 3. Trust boundaries

| # | Boundary | Crossing controls |
|---|---|---|
| TB1 | Internet → nginx | TLS, rate limits, request-size limits, IP reputation |
| TB2 | Browser → application | Session cookie (HttpOnly/Secure/SameSite), CSRF token, Origin check, permission checks per request |
| TB3 | Application → PostgreSQL | Role-scoped credentials (`app_rw`), RLS force-enabled, `SET LOCAL` tenant context, grant-based append-only enforcement |
| TB4 | Application → object storage | Presigned, short-lived, tenant-prefixed keys, authorization before presign |
| TB5 | Application → queue/broker | Internal network only; job envelopes carry tenant + actor; workers re-authorize |
| TB6 | Application → external world | Egress restricted; **no** government-API integrations exist in V1 (constraint 22) |
| TB7 | Host/container boundary | Non-root containers, no Docker socket, read-only roots, separate networks, secrets as files not env-in-image |
| TB8 | Tenant A ↔ Tenant B | Application scoping + RLS + composite FKs + storage prefixes + cache key prefixes + tests |
| TB9 | Platform operator ↔ tenant data | No ambient access; audited, reasoned, time-boxed break-glass; read-only by default |
| TB10 | Backup repository ↔ anyone on the VPS | Client-side encryption with off-host keys; immutable off-site copy; separate credentials |

---

## 4. Attack vectors and mitigations (the working table)

### 4.1 Tenancy and authorization

| # | Vector | Mitigation | Residual |
|---|---|---|---|
| TV-01 | **IDOR/BOLA**: change an id in a URL to another tenant's document | Server-side resolution always tenant+project scoped; **404** not 403 for foreign ids; RLS as backstop; automated two-tenant test suite on every endpoint | Very low |
| TV-02 | Forge `company_id` in a request body/header to read another tenant | Tenant comes only from the session's membership resolved server-side; client-supplied tenant values are ignored, not merely validated (requirement 3) | Very low |
| TV-03 | **Horizontal escalation inside a tenant**: a site engineer opens another project's financials | Project membership + project-scoped permission on detail *and* list *and* export endpoints; project filters applied in the repository layer | Very low |
| TV-04 | **Vertical escalation**: QS grants themselves `ipc.certify` | `roles.manage` required; `can_grant ⊆ own permissions`; self-escalation refused and audited; role changes alerted | Low |
| TV-05 | Self-approval / collusion on a VO or IPC | Segregation of duties (submitter ≠ approver, ≤ configurable thresholds), immutable approval actions with actor evidence, dual control option above a threshold | Medium (collusion between two humans is a governance issue, mitigated by audit) |
| TV-06 | Stale permission cache allows a revoked user to act | Permission resolution fresh per request, membership-scoped cache keys, immediate invalidation on role/membership change, revocation sweep | Very low |
| TV-07 | Confused-deputy via a job carrying stale authority | Jobs carry the actor and re-authorize before acting; a job whose actor lost rights fails closed | Low |
| TV-08 | **Tenant leakage through a non-obvious channel**: exports, search, dashboards, PDF metadata, cache keys, error messages, timing | Tenant scoping applied uniformly (queries, cache keys, storage prefixes, exports, MV filters); explicit tests for each channel; error messages structured so they never echo another tenant's identifier | Medium — this is a design-discipline risk, see [risks.md](risks.md) |
| TV-09 | Enumeration of tenants/users via invitation or password-reset responses | Uniform responses; no existence oracle | Very low |
| TV-10 | Cross-tenant write via a foreign key | Composite `(company_id, …)` FKs make it structurally impossible (verified in Phase 0) | Negligible |

### 4.2 Authentication and session

| # | Vector | Mitigation | Residual |
|---|---|---|---|
| TV-11 | Credential stuffing / brute force | Argon2id, per-IP and per-account rate limits with backoff and lockout, breached-password check, MFA for privileged roles, alerting on spikes | Low |
| TV-12 | Stolen session cookie (XSS, device theft) | HttpOnly + Secure + `__Host-` cookies, strict CSP, session binding metadata, idle/absolute timeouts, device list with revoke, step-up for sensitive actions | Low–Medium |
| TV-13 | Session fixation | Session id rotated on login and on privilege elevation | Very low |
| TV-14 | CSRF on a state-changing request | CSRF token bound to session + SameSite=Lax + Origin validation on mutations | Very low |
| TV-15 | Token/replay attack on download URLs | Presigned URLs with ≤ 5 min TTL, audited issuance, no long-lived signed links, revocation by disabling the document | Low |
| TV-16 | Password reset abuse | Single-use hashed tokens, short TTL, all sessions invalidated on reset, uniform responses | Very low |
| TV-17 | MFA bypass / downgrade | TOTP verified server-side, recovery codes hashed and single-use, no "remember this device" in V1 for privileged roles, step-up enforced at the service layer (not only the UI) | Low |
| TV-18 | Insecure password storage | Argon2id only; no reversible storage anywhere; parameter upgrades on login | Negligible |

### 4.3 Injection and input handling

| # | Vector | Mitigation | Residual |
|---|---|---|---|
| TV-19 | SQL injection | Parameterized ORM/psycopg only; no string-built SQL; raw SQL restricted to reviewed, parameterized functions; least-privilege DB role limits blast radius | Very low |
| TV-20 | XSS (stored/reflected) | React auto-escaping, no `dangerouslySetInnerHTML` on tenant data, strict CSP without `unsafe-inline`, sanitized rich text (none accepted in V1), `nosniff` on responses and downloads | Low |
| TV-21 | CSV/Excel formula injection in exports | Exports prefix `=+-@"` cells with `'` and write text types; documented in the export service | Low |
| TV-22 | Malicious file upload (macro, webshell, bomb) | Allow-listed types, magic-byte verification, AV scan, worker-side parse limits, private storage with no execution path | Low |
| TV-23 | Prompt/LLM or third-party content injection | No LLM features in V1; no tenant content is sent to third parties | N/A |
| TV-24 | Mass assignment / parameter pollution | Explicit serializer field allow-lists; derived fields are not writable; unknown fields rejected | Very low |

### 4.4 Financial integrity (the domain-specific threats)

| # | Vector | Mitigation | Residual |
|---|---|---|---|
| TV-25 | Client submits a total that does not match its lines | All totals recomputed server-side; DB generated columns + identity CHECKs make divergence impossible (verified in Phase 0) | Negligible |
| TV-26 | Client submits `previous_cumulative_value` to inflate/understate a certificate | Prior values read from certified history; DB validation function refuses disagreement (`IPC_PREVIOUS_VALUES_INVALID`) | Negligible |
| TV-27 | Double posting of a variation order (retry, double click, re-approval) | Idempotent posting by unique source key; approval is a single guarded transition; verification returns the same ledger entry | Negligible |
| TV-28 | Editing a certified certificate or an approved VO | Freeze triggers on the document, its lines, deductions/additions and snapshot + REVOKE UPDATE/DELETE; correction requires reversal with reason | Very low |
| TV-29 | **Race condition**: two concurrent certifications double-count revenue | Advisory lock per contract + `FOR UPDATE` on the certificate + EXCLUDE constraint on overlapping periods | Very low |
| TV-30 | Over-allocation of a collection across certificates | Allocating function locks both rows and enforces `Σ allocations ≤ amount` and `≤ outstanding` | Very low |
| TV-31 | Retroactive change of VAT/retention altering history | Rates snapshotted per certificate; contract value changes go through the ledger | Negligible |
| TV-32 | Silent deletion of an inconvenient ledger entry or audit row | Append-only grants + BEFORE UPDATE/DELETE trigger + hash chain + off-site checkpoints | Very low |
| TV-33 | Records altered by a privileged DBA | Hash chain + off-site checkpoints + verification job; tampering is *detectable* even if not preventable | **Accepted residual** (see §7) |
| TV-34 | Rounding exploitation across many lines | Single documented rounding rule, per-line rounding, aggregation defined as sum-of-rounded-lines, golden regression fixtures | Very low |
| TV-35 | Fictitious expense/cost injection to manipulate margin | Expense requires attachable evidence, approval workflow, cost-code/WBS linkage, audit + SoD; anomalies (round numbers, weekend entries, duplicate amounts) surfaced in the finance dashboard | Medium (detection, not prevention — mitigations are procedural) |

### 4.5 Platform, infrastructure and operations

| # | Vector | Mitigation | Residual |
|---|---|---|---|
| TV-36 | Publicly exposed PostgreSQL/Redis | No published ports, internal-only networks, `listen_addresses`/`pg_hba` restricted, SCRAM-SHA-256, external port probe in CI, UFW as a secondary control | Very low |
| TV-37 | Secrets in Git/images/logs | gitleaks in CI + pre-commit, Docker secrets, runtime injection, log redaction filter, `check --deploy` in CI | Low |
| TV-38 | Compromised dependency | Pinned versions, lockfiles, weekly `pip-audit`/`npm audit`, image scanning (Trivy) and a policy for critical CVEs | Medium (supply chain is a real-world risk) |
| TV-39 | Container escape / lateral movement | Non-root users, read-only roots where possible, no Docker socket, distinct networks, minimal images, no compilers in runtime images | Low–Medium |
| TV-40 | SSRF (URL fetch, webhook, PDF renderer loading remote resources) | No user-controlled outbound fetch in V1; the PDF renderer has no network; the app's egress is restricted; metadata endpoints (169.254.169.254) blocked by egress policy | Low |
| TV-41 | DDoS / resource exhaustion | nginx rate and connection limits, upload size caps, strict timeouts, worker concurrency caps, provider-level protection option, `statement_timeout`/`idle_in_transaction_session_timeout` on the DB role | Medium |
| TV-42 | Backup theft or ransomware | Client-side encrypted backups with off-host keys, immutable off-site repository (object lock), separate credentials, restore drills, least-privilege backup role | Low–Medium |
| TV-43 | Log/monitoring leakage of sensitive data | Redaction filters, no financial values in metrics, tenant-tagged logs with restricted Grafana access | Low |
| TV-44 | Abuse of break-glass by platform staff | Reason required and audited, tenant notified, read-only default, time-boxed, monthly review | Medium (trust in operators is inherent; detection is the control) |
| TV-45 | Accidental data destruction by an operator (bad migration, bad script) | Pre-deploy backup + WAL marker, migration review with expand/contract discipline, PITR, staging rehearsal | Low |
| TV-46 | Retention/privacy violation (keeping data too long, or an unhandled deletion request) | Documented retention classes, legal hold flags, offboarding procedure with export-then-delete, audit of deletions | Medium (process discipline) |

---

## 5. OWASP Top 10:2021 mapping

| Category | Where addressed |
|---|---|
| A01 Broken Access Control | [G](G-authorization-rbac.md) in full, [F](F-tenant-isolation.md), TV-01…TV-10 |
| A02 Cryptographic Failures | [H §2/§8](H-authentication-sessions.md), [M §1/§4](M-file-storage-security.md), [O §2](O-backup-disaster-recovery.md), TLS in [P §3](P-deployment-vps-docker.md) |
| A03 Injection | TV-19…TV-24, parameterized ORM, CSP, export hardening |
| A04 Insecure Design | This document plus [D](D-domain-model.md) invariants and [S](S-testing-strategy.md) tests; financial state machines instead of free-form status fields |
| A05 Security Misconfiguration | [P §8](P-deployment-vps-docker.md) checklist, `check --deploy` in CI, image pinning, least-privilege DB roles |
| A06 Vulnerable & Outdated Components | Pinned digests, weekly dependency scanning, CVE policy (TV-38) |
| A07 Identification & Authentication Failures | [H](H-authentication-sessions.md) in full, TV-11…TV-18 |
| A08 Software & Data Integrity Failures | Immutable images, signed artefacts (optional cosign), append-only audit chain, migration discipline |
| A09 Security Logging & Monitoring Failures | [L](L-audit-logging.md) + [Q](Q-observability.md), including security-signal alerts |
| A10 SSRF | TV-40, network segmentation in [B §5](B-infrastructure-architecture.md) |

**ASVS L2 coverage intent:** all L1+essential L2 items are in scope for V1; the exceptions we
consciously carry are documented in [security-checklist.md](security-checklist.md) with an owner
and a date.

---

## 6. Abuse cases specific to construction finance (worth building tests for)

| Case | Expected system behaviour |
|---|---|
| A QS certifies 130% of the BOQ quantity | Blocked by default (over-certification guard); if the company enables over-certification, the certificate is flagged and appears on the exception dashboard |
| A PM approves their own variation to inflate contract value | SoD blocks it; a second approver is required and both decisions are recorded |
| Someone retro-dates a certificate to fit a reporting period | Periods cannot overlap and must be sequential; `certified_at` is server-set; a misfitted period is visible in the register |
| A collection is quietly re-applied from Certificate 1 to Certificate 2 to hide an aging receivable | Re-allocation is an explicit, audited operation that reverses the first allocation; aging reports read from the live allocation set |
| An expense is deleted after month-end to improve margin | Posting freezes the record; deletion is not granted; correction is reversal with a reason, visible in the cost report |
| An import is confirmed, then the source workbook is edited to "match" | The batch, its rows, the validation issues and the original file are retained with the checksum; the committed BOQ can be traced to the exact file |
| A user exports the whole company's financials at 02:00 and deletes their account | Export is permission-gated (AAL2), rate-limited, audited and alerted; the account is not hard-deleted while it holds audit references |
| An operator looks up a customer's contract values during a support call | Break-glass requires a reason, is read-only, time-boxed, notified to the tenant owner and reviewed monthly |
| A tenant claims "we never changed this rate" | The audit trail shows the before/after values of the rate field with actor and timestamp; the contract ledger shows approved variation entries |

---

## 7. Residual risk statement (explicit, for the owner)

1. **A compromised host is a compromised system.** The database is on the same VPS as the application;
   an attacker with root can read live data. Mitigations reduce likelihood (hardening, least
   privilege, no public DB port), and the audit chain + off-site immutable backups limit *undetectable
   alteration* and *total loss*, but they do not prevent the initial read. A materially stronger posture
   requires the DB on a managed service or a separate host.
2. **A DBA can read everything.** Encrypted backups do not encrypt live data at rest beyond disk
   encryption. Field-level encryption of rate/margin data is technically possible but breaks
   reporting, sorting and integrity checks; it is recorded as an open decision (D-05), not silently
   ignored.
3. **Insider fraud is mitigated, not eliminated.** Segregation of duties, approvals and immutable
   audit raise cost and leave evidence; a determined collusion of two authorised humans with a
   matching story is a governance problem.
4. **Supply-chain compromise** of a dependency or base image can defeat application-level controls;
   pinning, scanning and a fast patch path reduce the window.
5. **Availability on one VPS** has a single failure domain; the DR design bounds the loss but not the
   downtime ([O §7](O-backup-disaster-recovery.md)).
6. **No system is 100 % secure.** This model is designed to fail safely (deny by default), to
   minimise blast radius, and to make what happened provable afterwards.
