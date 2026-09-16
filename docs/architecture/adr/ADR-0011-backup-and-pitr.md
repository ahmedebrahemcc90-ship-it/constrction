# ADR-0011 — pgBackRest PITR + client-side-encrypted immutable off-site backups + mandatory tested restores

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Infrastructure Architect, Security Engineer
- **Related:** [O](../O-backup-disaster-recovery.md), [P §4](../P-deployment-vps-docker.md),
  [Q §5](../Q-observability.md), [L §4](../L-audit-logging.md), [S §8](../S-testing-strategy.md)

## Context

Requirement 20: backups must be encrypted and off-site where practical, and restoration must be
testable. Requirement 22-style discipline also applies here: do not assume a cloud service exists.

The data at stake: contracts, BOQ rates, certificates, costs, margins, and the audit trail. Losing any
of it is unrecoverable in a commercial sense; silently losing *part* of it (a restore that loses the
last day and nobody notices) is worse, because numbers in the system then disagree with the numbers in
signed documents.

Constraints: a single VPS, one small operations team, a database that grows continuously (audit
partitions), and an owner who needs the assurance in plain language.

## Decision

**Continuous WAL archiving plus nightly/daily physical backups with pgBackRest, restored-window
verification, client-side-encrypted off-site copies held under an immutability policy, and scheduled
restore drills that are treated as a first-class operational obligation.**

1. **PITR:** pgBackRest full every night, incrementals every 6 hours, continuous WAL archiving to a
   local repository on a **separate volume**; restore to any second inside the retention window
   (35 days locally). Target RPO ≤ 15 minutes (archiving interval), measured — not assumed.
2. **Off-site copy:** the local repository is replicated to a different provider/region on completion
   and after verification; the repository is **encrypted client-side** (AES-256, passphrase held
   off-host) before upload, and the remote target enforces an **object-lock/immutability** policy for
   the retention window. This is the ransomware/insider-deletion control.
3. **Files:** restic snapshots of object storage (deduplicated, incremental, client-side encrypted)
   nightly, plus configuration archives (compose, nginx, schedules, non-secret env template).
4. **Keys never live with the data.** Backup passphrases are held in an off-host secret store or a
   physical escrow, never on the VPS, and are documented (including the break-glass copy and its
   custodian) as part of the operational runbook.
5. **Verification is mandatory and automatic:** `pgbackrest verify` after every full; a weekly restore
   of a single database/table from the **off-site** copy; restic `--read-data-subset=5%` weekly.
6. **Restore drills monthly (automated script, human confirmation):** restore the newest off-site
   backup into an isolated environment, run the data-integrity assertions
   ([O §4](../O-backup-disaster-recovery.md)) and the tenant-isolation smoke suite, verify the audit
   chain in the restored copy, measure the achieved RTO/RPO, and archive the report as evidence.
7. **Integrity assertions after any restore:** ledger sum equals `contracts.current_value`; every
   certified IPC has its snapshot; certificate sequences are monotonic and periods do not overlap;
   line sums equal header values; allocations do not exceed collections; the audit chain verifies
   clean; migration version matches the application version.
8. **Alerting:** "no successful backup in 24 hours" and "WAL archive lag > 30 minutes" are P1 alerts;
   a failed drill is a P1/P2 depending on the failure mode. Backups are never a background task nobody
   watches.

## Consequences

**Positive**

* A bad deploy, a bad migration or a bad script is recoverable to a precise point in time, which is a
  materially different capability from "we have last night's snapshot".
* Ransomware or a malicious insider deleting backups locally cannot delete the immutable off-site
  copies, and cannot read them without the off-host key.
* The monthly drill produces **measured** RTO/RPO numbers and an evidence trail, so the owner's
  assurance is empirical rather than aspirational; the drill also exercises the runbook, which is
  where real gaps (a missing credential, an undocumented step) surface.
* Restoring during a drill verifies the *application*, not just the bytes: the isolation suite and the
  audit chain are checked in the restored copy.

**Negative / costs to manage**

* Real operational weight: a second repository (off-site), key custody discipline, a weekly off-site
  verification job and a monthly drill that occupies an engineer for part of a day. This is
  non-negotiable and is budgeted as recurring work, not a one-off task.
* Storage and egress cost for off-site copies (deduplicated, but non-zero, and audit partitions grow
  continuously).
* Encryption keys become a critical dependency: losing the passphrase loses the backups. Mitigated by
  escrow with a documented custodian and a yearly re-encryption review.
* Object storage RPO is a nightly schedule, not continuous: a file uploaded and destroyed within the
  same day is only recoverable from object versioning, not from the off-site snapshot. Stated plainly
  in [O §7](../O-backup-disaster-recovery.md) rather than hidden.
* Restore time grows with data volume; the drill measures it, so the RTO claim is re-validated yearly.

**Follow-ups**

* Runbooks (restore, rotate keys, promote replica) are written, versioned and exercised by someone
  other than their author before launch.
* Deployment pipeline performs a pre-deploy backup and records the WAL marker, so any deploy can be
  rolled forward/back with a known recovery point.
* If availability requirements rise, the next step is a streaming replica as a warm standby
  ([P §9](../P-deployment-vps-docker.md)) — an additive change to this design, not a replacement of it.

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **`pg_dump` nightly only** | Loses everything since the dump; a night of certificates retyped by hand. Not acceptable for a financial system |
| **Local-only backups on the same VPS** | The most common real-world failure: disk failure, ransomware or host loss takes the backups with the data |
| **Off-site copies without client-side encryption** | The storage provider (or anyone who compromises its credentials) can read the customer's contracts and margins; contradicts requirement 20 |
| **Off-site copies with a server-side-encrypted (provider-managed) key** | Provider compromise or a legal request yields plaintext; the customer's commercial data should not be readable by the infrastructure operator |
| **Off-site copies without immutability/object lock** | A compromised credential can delete history; object lock is what makes the copy a *last resort* rather than another deletable target |
| **Backups without periodic restore drills** | An untested backup is a hypothesis, not a capability; the drill is the only honest measure of RTO and the only way to find the missing step before an incident |
| **Replicating to a second VPS only (no archive)** | A replica faithfully reproduces an accidental `DELETE` or a logical corruption within seconds; retention-based archives are what make "yesterday" recoverable |
| **Encrypting backups with a key stored on the VPS** | Turns every host compromise into total backup compromise; the key's location must be independent of the data's location |

## How this will be verified

1. Automated: backup age, WAL archive lag and verify results are monitored; a synthetic failure is
   injected once to prove the alert reaches a human ([Q §5](../Q-observability.md)).
2. Monthly drill: off-site restore → integrity assertions → isolation suite → audit chain verification
   → measured RTO/RPO → archived report.
3. PITR test: restore to a timestamp **between** two known writes and assert exactly the expected row
   state (proves the WAL chain, not merely the base backup).
4. Key-loss/key-rotation exercise: restore using only the escrowed passphrase, then rotate and confirm
   old and new backups both restore.
5. Failure-path tests: unreachable off-site target (backs off and alerts), corrupted backup (verify
   catches it before it is trusted), expired credentials (job fails loudly with an actionable message).
