# G. RBAC and Project-Scoped Authorization Design

**Non-negotiable:** UI visibility is not authorization. Every sensitive operation is authorized
server-side, in one place, against the caller's *live* server-side context.

---

## 1. Authorization model

Two dimensions, both mandatory, evaluated together:

| Dimension | Question | Scope |
|---|---|---|
| **Company (RBAC)** | What may this role do inside this company? | Roles are company-owned bundles of permission codes (`ipc.certify`, `boq.edit`) |
| **Project (ABAC)** | May this person act on *this project*? | `project_members` grants explicit project access + a project-scoped permission set, optional expiry, optional branch restriction |

Effective decision for a project-scoped operation:

```
allowed = membership.status = 'active'
          AND permission ∈ company_permissions(roles)
          AND project ∈ accessible_projects(membership)
          AND permission ∈ project_permissions(membership, project)
          AND (branch scope allows project.branch_id or scope is empty)
          AND NOT any_deny_rule        -- confidential projects, legal hold, segregation of duties
```

Company-wide operations (partners, cost codes, users, settings) require the company-scoped
permission and, for anything financial, an explicit second check on the target project.

---

## 2. Why the frontend will never be trusted (and what the frontend is for)

| Frontend behaviour | Security status |
|---|---|
| Hiding a "Certify" button | **UX only.** The API independently authorizes `ipc.certify` on that IPC's project |
| Hidden field for `company_id` | Ignored server-side; tenant comes from the session-derived `PrincipalContext` |
| Client-side route guard | Convenience; server returns 404/403 regardless |
| Totals sent by the client | Discarded; recomputed server-side ([I §5](I-financial-architecture.md)) |
| "Project selector" | Selector only — the chosen project must appear in the server-side accessible set |

Consequence: a penetration test that bypasses the SPA and calls the API directly must produce
**exactly** the same authorization outcomes. That is an explicit test case ([S §3](S-testing-strategy.md)).

---

## 3. Permission catalogue (V1)

Codes are stable identifiers; the catalogue ships with the application and tenants cannot invent
permissions (`permissions` is global; `roles` are tenant-owned copies of templates).

### 3.1 Company-scoped

| Code | Meaning | Sensitivity |
|---|---|---|
| `company.settings.read` / `company.settings.manage` | Company profile, VAT, numbering, branches | manage = sensitive |
| `users.read`, `users.invite`, `users.manage`, `users.revoke` | Membership lifecycle | manage/revoke = sensitive |
| `roles.read`, `roles.manage` | Roles & permission assignments | sensitive |
| `partners.read`, `partners.manage` | Clients, suppliers, subcontractors | — |
| `costcodes.read`, `costcodes.manage` | Company cost-code tree | — |
| `wbs.manage` | WBS structure (project-scoped in practice) | — |
| `financials.read` | See monetary values at company level (contracts, IPCs, cash) | sensitive |
| `financials.export` | Export financial data | sensitive |
| `audit.read` | Read the audit trail | sensitive |
| `reports.read`, `reports.export` | Dashboards and reports | — |
| `documents.read`, `documents.upload`, `documents.download`, `documents.delete` | File operations | download is audited |

### 3.2 Project-scoped

| Code | Meaning |
|---|---|
| `project.read` | See the project and its non-financial basics |
| `project.manage` | Edit project settings, memberships, milestones |
| `project.financials.read` | See commercial figures for this project |
| `boq.read`, `boq.edit`, `boq.approve`, `boq.import` | BOQ lifecycle; `impersonate` not available |
| `budget.read`, `budget.edit`, `budget.approve` | Budget lifecycle |
| `variation.read`, `variation.create`, `variation.submit`, `variation.approve` | VO lifecycle |
| `ipc.read`, `ipc.create`, `ipc.submit`, `ipc.certify`, `ipc.approve`, `ipc.post`, `ipc.reverse` | IPC lifecycle |
| `expense.read`, `expense.create`, `expense.approve`, `expense.post` | Cost capture |
| `collection.read`, `collection.create`, `collection.post` | Cash capture |
| `document.read`, `document.upload`, `document.download` | Project documents |

**Sensitive permissions** (`ipc.certify`, `ipc.approve`, `ipc.post`, `ipc.reverse`, `variation.approve`,
`budget.approve`, `users.manage`, `roles.manage`, `audit.read`, `financials.export`) additionally
require step-up authentication (AAL2) and are always audited ([H §5](H-authentication-sessions.md)).

### 3.3 System role templates (seeded, cloneable, not deletable)

| Template | Company permissions | Project permissions |
|---|---|---|
| Company Owner | all | project admin on all projects |
| Company Admin | all except `financials.export`? (configurable) | project admin on assigned projects |
| Finance Manager | `financials.*`, `reports.*`, collections, expenses | `ipc.read/approve/post`, `collection.*`, `expense.*` |
| Project Manager | `partners.read`, `projects.read` | full commercial control of assigned projects, `variation.approve` (if alone, requires owner approval by SoD config) |
| QS / Quantity Surveyor | `partners.read` | `boq.*`, `ipc.create/submit`, `variation.create/submit`, `expense.create` |
| Accountant | `financials.read`, `reports.*` | `expense.create/post`, `collection.create/post` |
| Site Engineer | `partners.read` | `project.read`, `ipc.read`, `document.upload` |
| Storekeeper | — | `expense.create` (materials only, by category rule) |
| Auditor | `audit.read`, `reports.read`, `financials.read` | `project.read`, read-only everywhere |
| Viewer | `partners.read` | `project.read` (non-financial) |

---

## 4. The enforcement choke point (server-side)

### 4.1 Request pipeline

```
1. Session authentication            → user_id (or 401)
2. Membership resolution             → active membership for the requested company (else 403)
3. PrincipalContext build            → company_id + effective permission set + project scopes
                                       (loaded/cached per request, invalidated on change)
4. Route-level permission check      → @require("ipc.certify")           (company scope)
5. Object resolution                 → tenant-qualified + project-scope filtered
                                       → out of scope ⇒ 404 (no existence oracle)
6. Service-level re-check            → require_project(ipc.project_id, "ipc.certify")
7. Domain rules                      → state machine, SoD, amount limits, locks
8. Audit + outbox in the same transaction
```

Every step is mandatory for sensitive operations; steps 4–6 are cheap enough to be unconditional.

### 4.2 Object resolution helpers (anti-IDOR/BOLA)

| Helper | Behaviour |
|---|---|
| `get_in_scope(Model, ctx, id)` | Adds `company_id` + project-scope filter, raises **404** when absent |
| `require_project(ctx, project_id, permission)` | Raises 404 when the project is not accessible, 403 when accessible but the permission is missing **on a company-scoped route only** |
| `scope_queryset(qs, ctx)` | Company filter + project filter; used by *every* list endpoint |
| `assert_same_tenant(parent, child, ctx)` | Belt-and-braces check before linking entities (the composite FK is the last line) |

**Deliberate asymmetry:** "does not exist" and "exists but is not yours" return the same 404. This
removes the enumeration oracle that BOLA attacks rely on. Authorization *within* a visible project
returns 403, because there the existence is not a secret.

### 4.3 Why not 403 everywhere

A 403 on a cross-tenant id confirms the id exists, enabling enumeration of other companies'
documents ("does IPC 1234 exist?"). 404 leaks nothing. Documented and tested
([S §3](S-testing-strategy.md)).

---

## 5. Privilege-escalation defences

| Attack | Defences |
|---|---|
| **Horizontal** — user in Company A reads Company B | Tenant-scoped every request + RLS + composite FKs + isolation tests |
| **Horizontal inside a company** — site engineer on Project 1 reads Project 2's margin | Project membership is required; `financials.read` is project-gated; project scope is applied to list **and** detail endpoints and to exports |
| **Vertical** — QS grants themselves `ipc.certify` | Permission management requires `roles.manage`; nobody may grant a permission they do not hold themselves (`can_grant ⊆ own`); self-escalation is refused and audited |
| **Vertical via role editing** | System templates cannot be edited in place; changes create a new version; a user cannot edit a role that grants permissions above their own |
| **Self-approval** | Segregation of duties: when `approval_sod_required` (default true) the submitter cannot approve their own VO/IPC/Budget/Expense; DB records decision evidence with actor + step |
| **Approval by stub account / delegation abuse** | Delegation is explicit, bounded (`permission_codes`, `project_ids`, `valid_from/to`), reasoned, never wider than the delegator, and audited |
| **Mass assignment** | Serializers whitelist fields; `company_id`, `status`, `certified_*`, `amount`-style fields are never writable inputs |
| **Forced browsing to admin routes** | Route-level permission classes, not router concealment |
| **Token/permission confusion** | Permissions are resolved from the database (roles → permissions) on each request, never from a token payload |
| **Stale permission cache** | Cache keyed by membership + invalidated on role/membership change; revocation propagates within the session freshness window |
| **Race on permission change** | Role changes take effect transactionally; concurrent operations are serialized by the same row locks used for the document |

---

## 6. Separation of duties (configurable, default ON)

| Document | Rule (default) |
|---|---|
| Variation Order | Creator/submitter ≠ approver; approval requires `variation.approve`; amount thresholds per workflow step |
| IPC | Preparer ≠ certifier ≠ poster where staff permits; `ipc.post` requires `financials.read` |
| Budget | Preparer ≠ approver |
| Expense | Creator ≠ approver; posting requires a finance permission |
| Payment/Collection | Recorder ≠ reconciler where configured |
| Role change | One admin may change roles; the change is audited and (optionally) requires a second approver above a configured privilege level |

Thresholds support the real-world pattern "PM approves up to SAR 50,000; above that the Commercial
Director must also approve" via `approval_workflow_steps.min_amount/max_amount`.

---

## 7. Break-glass (platform operator access)

1. Platform operators hold **no** tenant permissions and are not members of any tenant.
2. Accessing tenant data requires an explicit elevation request with a **reason** (≥ 10 characters,
   enforced by a CHECK constraint on the audit row) and, in production, MFA step-up.
3. Elevation is transaction-scoped (`app.platform_elevation`), read-only by default, time-boxed, and
   generates an audit row plus an immediate notification to the tenant's owner.
4. Dashboards and exports refuse to run while elevation is active.
5. Elevations are reviewed monthly; the review itself is recorded.

---

## 8. Testing hooks (what CI must prove)

| Test | Assertion |
|---|---|
| Permission matrix | For each (role template × endpoint) pair: expected status code is produced by the **API**, not the UI |
| Project scope | User with Project 1 access calling Project 2 endpoints → 404 for detail, empty for lists |
| Cross-tenant | Two-tenant fixtures: no B id appears in any A response, and no B row is mutated by an A request |
| Escalation | A user cannot grant a permission they lack; cannot approve their own document; cannot delegate beyond their own rights |
| Route parity | Every route on the API has an explicit permission declaration; a CI check fails on an undeclared route |
| Direct-API parity | The permission-matrix suite runs against the API directly (no SPA) to prove the UI is not load-bearing |
