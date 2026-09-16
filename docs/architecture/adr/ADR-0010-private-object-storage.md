# ADR-0010 — Private S3-compatible object storage with authorization before short-lived presigned URLs

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Owner, Security Engineer, Infrastructure Architect
- **Related:** [M](../M-file-storage-security.md), [F §5](../F-tenant-isolation.md),
  [N](../N-background-jobs.md), db/09, [P §2](../P-deployment-vps-docker.md)

## Context

Construction companies upload the most sensitive documents in their business: signed contracts,
client correspondence, invoices, site photos, sometimes identity documents of subcontractor staff.
Requirements 18 and 19 are explicit — files must be private, authorization must be checked before
download, and uploads must be validated and stored safely.

Constraints on the solution:

* it must run on a single VPS with the rest of the stack (no cloud vendor assumption);
* large files (25 MB workbooks, drawing PDFs) must not be pushed through the application's Python
  workers, which would tie up workers and hit proxy limits;
* per-tenant isolation must be as strong for files as for database rows (principle 2);
* a leaked link must have bounded, auditable consequences;
* the storage layout must support per-tenant export/deletion for offboarding.

## Decision

**Use private S3-compatible object storage (MinIO on the internal Docker network, S3 API) as the only
place where files live, with tenant-scoped key prefixes, and grant access exclusively through
short-lived presigned URLs that are issued only after server-side authorization.**

1. **No files on the application filesystem, none in the database.** The database stores metadata
   (`documents`, `document_versions`: key, size, content type, sha256, scan status) and small
   generated payloads only.
2. **Buckets are private**, no anonymous read, no public policy, server-side encryption enabled,
   versioning enabled for documents and generated artefacts, and per-bucket lifecycle rules
   (`app-exports` expires in 7 days).
3. **Tenant-scoped keys:** `tenants/<company_id>/<document_type>/<yyyy>/<mm>/<uuid>.<ext>`. The tenant
   is part of the key so a scoping mistake cannot silently cross tenants, and offboarding is a prefix
   operation.
4. **Uploads are authorized then direct-to-storage.** The API creates a `document_upload_sessions`
   row with a server-generated key and returns a presigned `PUT` valid for ≤ 5 minutes. On completion
   the server HEADs the object, verifies size/content type, records the checksum, sets
   `scan_status = 'pending'` and enqueues an antivirus/MIME job; the version is **not servable** until
   the scan is clean (fail closed on scan failure).
5. **Downloads authorize first, then presign.** `documents.download` + project scope are checked, the
   document must be `active` with `scan_status = 'clean'`, the download is audited, and only then is a
   presigned `GET` (≤ 5 minutes) returned. The object key is never exposed to the client.
6. **Validation is layered:** allow-listed MIME types verified against magic bytes, size caps, macro
   formats and archives refused, filename sanitised (stored key is a UUID), parsing in workers with
   row/expansion limits and hardened XML parsing, EXIF stripped from images unless geotagging is
   explicitly enabled.
7. **Generated PDFs** are rendered in a separate container with no database credentials and no
   outbound network, written to `app-generated`, and linked to the source document and (for
   certificates) to the snapshot payload hash.

## Consequences

**Positive**

* Tenant isolation for files is structural (prefix) and enforced by the authorization step, not by
  obscurity; a test can assert that Company A cannot obtain a URL for Company B's object.
* Large uploads bypass the Python workers and the reverse proxy, so a 25 MB workbook does not consume
  a web worker for a minute; the API handles only metadata.
* A leaked URL is useless within minutes and its issuance is auditable; there are no permanent public
  links to forget about.
* Versioning + checksums give an evidentiary chain: which file, which version, which checksum, who
  downloaded it, when.
* Storage operations (backup, export, per-tenant deletion) work on prefixes, which keeps the
  offboarding story simple.

**Negative / costs to manage**

* MinIO is another service to run, monitor, back up and patch on the same VPS; it is on the internal
  network with no published port and its data is covered by the backup strategy.
* Presigned URL flows require the browser to reach the storage endpoint via the same public origin
  (proxy path or a dedicated subdomain) with correct CORS, and require clock synchronisation (NTP)
  because signatures are time-bound. Both are operational obligations tested in staging.
* Two-step uploads (session → confirm) mean an orphaned object is possible if the client never
  confirms; a garbage-collection job sweeps unconfirmed upload sessions and their objects, and the
  session row keeps the object traceable in the meantime.
* Antivirus scanning adds latency between upload and availability; the UI must say "processing" rather
  than "available", and users must not be able to download an unscanned file (they cannot).

**Follow-ups**

* GC job for expired upload sessions and orphaned objects; alert if the orphaned-object count grows.
* Explicit test that a quarantined/infected file is not downloadable by anyone, including an admin.
* Document the CORS/signature configuration in the deployment runbook.

## Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **Store files on the VPS filesystem, path-per-tenant** | No isolation primitive stronger than the path, backup/restore of millions of small files is painful (pgBackRest covers the DB, not the file tree), and one path-handling bug is a cross-tenant exposure |
| **Store files in the database as `bytea` / large objects** | Bloats the database and its backups, slows vacuuming, and makes PITR of the DB the only recovery path for files; the DB backup window grows with file volume |
| **Public bucket with unguessable UUID URLs ("security by obscurity")** | A leaked URL is permanently valid, no authorization is possible before delivery, and nothing is audited; unacceptable for contracts and invoices |
| **Cloud object storage (S3/GCS/Azure Blob)** | Not disallowed for the future, but V1 targets a single VPS with no cloud account assumption; the S3 API keeps this choice swappable without touching the application |
| **Proxy every download through the application** | Simple authorization, but large files occupy web workers, break range requests, and add a memory/streaming hazard; the presigned model keeps the app in the authorization path only |
| **Long-lived signed URLs (hours/days)** | Turns a URL into a bearer token with a long life; contradicts the "authorize before download" requirement in spirit |
| **Row-level "file" storage with a per-tenant bucket per company** | Thousands of buckets on one MinIO instance, per-bucket policies to maintain, and no security benefit over prefixed keys with per-request scoping |

## How this will be verified

1. Isolation tests: Company A cannot presign, guess or download Company B's object; a key from another
   tenant's prefix is refused server-side.
2. Upload abuse tests: macro file, wrong magic bytes, oversized file, zip bomb, EICAR test file
   (quarantined, not served).
3. Authorization tests: every download path checks `documents.download` **and** project scope **and**
   `scan_status = 'clean'`; a quarantined file is refused even for an administrator.
4. Operational tests: presigned URL expiry, clock-skew failure mode, orphan GC, and restore of a
   deleted document version from object versioning + the encrypted backup.
5. Dependency and image scanning of the storage service, plus a check that its port is not published
   ([P §5](../P-deployment-vps-docker.md)).
