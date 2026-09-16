# Architecture Decision Records

An ADR here records a decision that is **expensive to reverse** (schema shape, tenancy model, money
handling, security boundary, deployment topology) together with the alternatives that were rejected.
Cheap, reversible choices are made in code review and are not ADRs.

## Template

```markdown
# ADR-NNNN — Title
- Status: Proposed | Accepted | Superseded by ADR-NNNN | Deprecated
- Date: YYYY-MM-DD
- Deciders: (owner / architect)
- Related: documents, invariants, other ADRs, open decisions

## Context
## Decision
## Consequences (positive / negative / follow-ups)
## Alternatives considered and rejected
## How this will be verified
```

## Index

| ADR | Decision | Status | Touches |
|---|---|---|---|
| [0001](ADR-0001-multi-tenancy-shared-schema-rls.md) | Multi-tenancy: single database, shared schema, `company_id` + fail-closed RLS | Accepted | `F`, `E §6`, `S §4`, db/13 |
| [0004](ADR-0004-money-representation-and-rounding.md) | Money as `numeric`/`Decimal` with one documented rounding rule; no floats | Accepted | `I §2`, `E §1`, db/00, `S §5` |
| [0005](ADR-0005-contract-value-ledger.md) | Append-only contract value ledger; only approved variations change contract value | Accepted | `K §3`, `I §4.1`, db/03, db/06 |
| [0007](ADR-0007-ipc-derived-cumulative-and-locking.md) | IPC previous/cumulative values derived from certified history under lock; stored derived columns + identity CHECKs instead of generated-column chains | Accepted | `I §4.3`, `I §6`, db/07 |
| [0008](ADR-0008-document-state-machines-and-immutability.md) | Explicit state machines; certified/posted documents immutable; corrections by reversal | Accepted | `J`, db/03–db/08 |
| [0009](ADR-0009-append-only-hash-chained-audit.md) | Append-only, hash-chained, partitioned audit log with INSERT-only grants and off-site checkpoints | Accepted | `L`, db/10, db/14 |
| [0010](ADR-0010-private-object-storage.md) | Private S3-compatible object storage with authorization **before** short-lived presigned URLs | Accepted | `M`, db/09 |
| [0011](ADR-0011-backup-and-pitr.md) | pgBackRest PITR + client-side-encrypted immutable off-site copies + mandatory tested restores | Accepted | `O`, `P §4` |
| [0018](ADR-0018-composite-foreign-keys.md) | Composite tenant-aware foreign keys `(company_id, parent_id)` instead of single-column FKs | Accepted | `E §6`, `F §2`, all db files |
| [0019](ADR-0019-project-scoped-composite-foreign-keys.md) | Project-scoped composite keys `(company_id, project_id, id)` for project-owned children | Accepted | `E §6`, db/03, db/04, db/07, db/08 |
| [0021](ADR-0021-curated-reporting-not-query-builder.md) | Curated reports and fixed views in V1; no user-facing report/query builder | Accepted | `A §5`, `C §7`, db/11 |

## Numbering

Numbering is stable and numbers are **never reused**. Numbers 0002, 0003, 0006 and 0012–0017 and 0020
were assigned during Phase 0 outline planning to candidate decisions (database access roles, workflow
engine, deployment topology, observability stack, front-end rendering strategy, and others) whose
content was subsequently folded into the ADRs above, the architecture documents, or the open decisions
in [`../open-decisions.md`](../open-decisions.md) rather than issued as separate records. They stay
reserved. The next new decision is **ADR-0022**.

## Proposing a new ADR

1. Copy the template to `ADR-<next-number>-<slug>.md`.
2. State the context in terms of a real constraint (a requirement, a measured limit, a regulation) —
   not a preference.
3. List at least two rejected alternatives with the reason each was rejected.
4. Describe how the decision will be **verified** (a test, a schema check, an operational drill).
5. Open a PR. An ADR that changes a previously accepted decision sets the old record's status to
   `Superseded by ADR-NNNN` rather than editing history.
