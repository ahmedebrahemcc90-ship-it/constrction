# H. Authentication and Session Architecture

Design goals: credentials that are hard to steal and easy to revoke, no bearer tokens in browser
storage, MFA where it matters, and full auditability of identity events.

---

## 1. Authentication methods (V1)

| Method | Scope | Notes |
|---|---|---|
| Email + password | All users | Argon2id hashing, per-user salt, server-side policy |
| TOTP MFA | Mandatory for `is_platform_operator`; **enforced by role** for owners/admins and for users holding sensitive permissions | Recovery codes (hashed, single-use) |
| Google Workspace / Microsoft Entra SSO | Optional per company (post-V1 candidate) | Not in V1 scope; the session model below is unaffected |
| API tokens | **Not in V1** | If added, they must be scoped, short-lived, per-integration, and never grant interactive privileges |
| Passwordless / magic link | Not in V1 | — |

---

## 2. Password handling

| Control | Decision |
|---|---|
| Algorithm | **Argon2id** via `argon2-cffi`, configured through Django's `PASSWORD_HASHERS[0]` (memory ≥ 64 MB, time ≥ 3 iterations, parallelism 1–4, tuned to the VPS CPU) |
| Never | Custom hashing, reversible encryption, MD5/SHA-1/SHA-256 alone, "pepper in code" |
| Policy | Minimum 12 characters, checked against a breached-password list, no forced rotation, no composition theatre; Arabic/Unicode allowed |
| Storage | `user_credentials.password_hash` (algorithm embedded in the encoded string) so the algorithm can be upgraded without a schema change |
| Upgrade on login | If the stored hash uses an outdated parameter set, it is transparently re-hashed at next successful login |
| Reset | Single-use token, 30-minute TTL, hash-only storage, invalidates **all** existing sessions, and is itself audited |
| Invitation | Single-use token bound to the invited email, 72-hour TTL, hash-only storage; accepting creates the membership, never a pre-authenticated session |

---

## 3. Session architecture

**Opaque, database-backed sessions** — not JWTs — because revocation and server-side lifecycle are
requirements for a financial system.

| Aspect | Decision |
|---|---|
| Transport | Cookie `__Host-session` (implies `Secure`, no `Domain`, `Path=/`) with `HttpOnly`, `SameSite=Lax` |
| Token | 256-bit random value; only `sha256(token)` is stored (`sessions.token_hash`) — a database leak does not yield usable sessions |
| Server state | `sessions` row: user, active company/membership, auth level, IP, user agent, created/last-seen, idle and absolute expiry, revocation |
| Idle timeout | 60 minutes (configurable) |
| Absolute timeout | 12 hours for interactive users; shorter (4 h) for platform operators |
| Rotation | The session id is rotated on login, on privilege elevation, and on password change (defence against fixation) |
| Binding | IP and user agent are recorded; a change to the user agent (or a country-level IP change) triggers re-authentication for sensitive operations, not a hard lockout |
| Concurrency | Multiple sessions allowed; the session list is visible to the user and individually revocable ("sign out everywhere") |
| Logout | Deletes the session row server-side, then clears the cookie; a replayed cookie is worthless |
| Revocation triggers | Password change/reset, membership suspension/revocation, role downgrade, administrator action, detected token reuse |
| CSRF | Double-submit CSRF token bound to the session, required on all state-changing requests; `SameSite=Lax` plus an `Origin` check on mutations |
| CORS | Same-origin by default; any additional origin is explicitly allow-listed, never `*` |

**Company switching** is not a new session: it updates `sessions.active_company_id` after
re-validating the membership server-side, and is audited.

---

## 4. Anti-abuse and brute force

| Control | Decision |
|---|---|
| Rate limits | Per `(email, IP)` and per IP on `/auth/login`: token-bucket with exponential backoff; 5 failures → progressive delay, 10 → 15-minute lock with notification |
| Generic errors | Login failures never reveal whether the email exists or the company is valid |
| Timing | Constant-time comparison for tokens/passwords; a uniform failure path |
| Signup | By invitation only; no self-service tenant creation in V1 (provisioned by an operator with an audited action) |
| Enumeration | Invitation and password-reset responses are always "if the account exists, an email was sent" |
| Alerting | A spike in failures, logins from new countries, or impossible-travel patterns raise alerts ([Q](Q-observability.md)) |
| Login audit | Every attempt is recorded (`login_attempts`) with outcome; successes and failures are retained 90 days |

---

## 5. Step-up authentication (AAL2)

Sensitive operations require `auth_level = 2` (MFA verified) in the current session, and for the
most sensitive ones (IPC post/reverse, role management, export of financial data, break-glass) a
**recent** factor (≤ 15 minutes) is required.

| Operation | Requirement |
|---|---|
| View dashboards | AAL1 |
| Create/submit documents | AAL1 |
| Certify/approve/post/reverse financial documents | AAL2 |
| Manage roles/permissions, export financial data, read audit | AAL2 |
| Platform-operator elevation | AAL2 + reason + notification |

If a user without MFA attempts a protected operation, the API returns `403 auth.step_up_required`
with a machine-readable code so the SPA can prompt for enrolment — the operation still does not
happen.

---

## 6. Permission freshness and invalidations

| Event | Effect |
|---|---|
| Role or permission change | Permission cache invalidated immediately; the affected session's context is rebuilt on next request |
| Membership suspended/revoked | All sessions for that membership are revoked; company switch to it fails |
| Project access revoked | Project scope cache invalidated; detail endpoints return 404 immediately |
| Password change | All other sessions revoked |
| Company suspension | Login refused; existing sessions are revoked at the next request (and by a scheduled sweep) |

Sessions therefore carry **identity**, not authority: authority is always resolved fresh from the
database. A stale session can never carry stale privileges.

---

## 7. Audit of identity events (all recorded, see [L](L-audit-logging.md))

`auth.login.succeeded`, `auth.login.failed`, `auth.logout`, `auth.mfa.enrolled`,
`auth.mfa.disabled`, `auth.mfa.challenge_failed`, `auth.password.changed`, `auth.password.reset_requested`,
`auth.session.revoked` (by user/admin/system with reason), `auth.company.switched`,
`auth.invitation.created/accepted/revoked`, `auth.step_up.succeeded/failed`,
`platform.elevation.requested/granted/denied/expired`.

Each record carries actor, IP, user agent, request id and outcome. Password and token values are
**never** logged; sensitive payload fields are redacted by a logging filter ([Q §4](Q-observability.md)).

---

## 8. Secrets and key material

| Secret | Storage | Rotation |
|---|---|---|
| `SECRET_KEY` (Django) | Docker secret / root-only env file | On a schedule and on personnel change |
| DB credentials (per role) | Docker secrets | Scheduled + on suspicion |
| Object-storage keys | Docker secrets, scoped per bucket/prefix | Scheduled |
| MFA TOTP secrets | Encrypted column (`user_mfa_totp.secret_encrypted`) with an app-level key from secrets | N/A (per-user) |
| Backup encryption passphrases | Off-host secret store / escrow, **never** on the VPS | Yearly, with re-encryption of the newest full backup |
| Audit HMAC key version | `hash_key_version` recorded per row to allow rotation | Versioned rotation |

Absent secrets fail **closed**: the application refuses to start rather than falling back to a
default (no `SECRET_KEY = 'dev'` fallback in production settings; `manage.py check --deploy` runs in CI).
