# M. File-Storage Security Architecture

Uploaded documents are the easiest way to leak data or compromise a server in a construction SaaS:
invoices, contracts, site photos, client correspondence. The rules below are therefore strict.

---

## 1. Storage decision

**Private S3-compatible object storage (MinIO on the VPS, S3 API), never the application filesystem,
never the database, never a public bucket.**

| Aspect | Decision |
|---|---|
| Buckets | `app-documents` (tenant uploads), `app-generated` (PDFs the system produces), `app-imports` (source workbooks), `app-exports` (user exports, short-lived), `app-backups` (backup agent, not app-accessible) |
| Access | All buckets private; no anonymous read; no public bucket policy; bucket policies scoped by prefix and by the application role |
| Tenant scoping | Key format `tenants/<company_id>/<document_type>/<yyyy>/<mm>/<uuid>.<ext>` — the tenant is part of the key, so a mis-scoped query cannot cross tenants by accident, and per-tenant export/deletion is a prefix operation |
| Server-side encryption | SSE enabled on every bucket; keys held in the deployment secret store; disk-level encryption (LUKS) beneath it on the host |
| Versioning | Enabled on `app-documents`/`app-generated` so an overwrite cannot destroy evidence; old versions follow the retention policy |
| Lifecycle | `app-exports` auto-expires after 7 days; `app-imports` retained per import-batch evidence rules; documents follow `retention_class` |
| Credentials | Dedicated per-service credentials from Docker secrets, scoped to the bucket/prefix; **no** root credential in the app; rotation on a schedule |

---

## 2. Upload path (direct-to-storage, server-authorized)

```
1. Client requests an upload session            POST /documents/upload-sessions
   → server authorizes (documents.upload, project scope, size/type policy)
   → creates document_upload_sessions row with a random object_key under the tenant prefix
   → returns a PRESIGNED PUT URL valid ≤ 5 minutes (content-type and size constrained if supported)

2. Client uploads directly to object storage    (the application never proxies large files)

3. Client confirms                              POST /documents/upload-sessions/{id}/complete
   → server HEADs the object: size, content-type, and (for chunked/checksum uploads) the checksum
   → compares against the declared values and the session's size cap
   → creates document_versions row (sha256, size, content type, filename)
   → sets scan_status = 'pending' and enqueues an AV scan job
   → documents.status stays 'draft' (not visible in normal lists) until the scan completes

4. Scan completes                               AV/MIME job
   → clean   : version becomes servable, document becomes 'active'
   → infected: version quarantined, document 'quarantined', owner notified, event audited
   → failure : retained as 'scan_failed' and NOT servable (fail closed)
```

Why this shape: presigned URLs keep large payloads off the application server, and the **server**
still decides the key, the size limit and the content type — the client can never choose an
arbitrary path or reach another tenant's prefix (the signature is scoped to one key).

---

## 3. Validation rules (defence in depth)

| Rule | Value |
|---|---|
| Size | ≤ 25 MB per upload for documents (50 MB hard column cap); ≥ 1 byte; enforced at the session, at the object check and in the DB |
| Content type | Allow-list per document type: PDF, JPEG, PNG, WEBP, XLSX, CSV, DOCX, TXT. Declared type **and** sniffed magic bytes must both match; a mismatch is rejected |
| Filenames | Sanitised to a display name only; the stored key is a UUID. No path separators, no control characters, no Unicode tricks; the original name is kept for display and never used for storage |
| Dangerous content | Macro-enabled Office formats are refused (`xlsm`/`docm`); PDFs are scanned but never executed; archives (zip/rar) are refused for tenant uploads |
| Parsing | Excel/CSV parsing is done in a worker with row/cell/zip-bomb limits (max rows, max expanded size, max compression ratio) and `defusedxml` for XML inside OOXML |
| Antivirus | ClamAV in a worker container; the file is streamed, not executed; the result is stored (`scan_status`, `scan_engine`, `scanned_at`) |
| Duplicate content | SHA-256 stored per version, enabling deduplication and detection of the same file uploaded to two tenants without exposing either |
| Images | Strip EXIF (including GPS) for site photos unless the tenant explicitly enables geotagging; a PDF is generated from images rather than served raw when rendered |

---

## 4. Download path (authorize *then* presign)

```
GET /documents/{id}/download
  1. authenticate session                          → 401 if absent
  2. authorize: documents.download + project scope  → 404 if out of scope (no existence oracle)
  3. verify the document/version is servable:
        documents.status = 'active' AND scan_status = 'clean'
        (a quarantined or unscanned file is never served — not even to an admin)
  4. audit the download (actor, document, version, IP, request id)
  5. return a presigned GET URL valid ≤ 5 minutes, with a content-disposition filename
```

Hard rules:

* No public URLs, ever. No long-lived signed URLs. No bucket listing to clients.
* The object key is never returned to the client; only the presigned URL for that one object.
* A URL shared with a third party expires in minutes; if it leaks, the access it grants is bounded
  and already audited.
* Range requests are supported by the storage layer, not by the application.
* `Content-Disposition: attachment` for anything that could render script; `X-Content-Type-Options:
  nosniff` and a restrictive `Content-Security-Policy` on the doc viewer.

---

## 5. Generated documents (PDFs)

* Generated certificates, BOQ exports and reports are written to `app-generated` under the tenant
  prefix, and linked through `documents`/`document_versions` + `ipc_certificates` like any other file.
* Rendering happens in a **separate container** (`pdf` service) with no database credentials and no
  tenant data beyond the payload it is given; it renders HTML produced by our own templates (no
  user-supplied HTML, no external resource loading, no network access during rendering).
* Fonts are bundled in the image (Arabic shaping verified); no runtime font downloads.
* A generated artefact is immutable once created; regenerating creates a new version and the old one
  is retained.
* Every generated PDF that matters (an IPC certificate) is linked to the `ipc_snapshots` payload hash
  in the audit trail, so the file and the numbers can be tied together.

---

## 6. Retention, deletion and legal hold

| Situation | Behaviour |
|---|---|
| User "deletes" a document | Soft delete (`documents.deleted_at`): hidden from the UI, retained for the retention window, still auditable; a hard-delete job exists but is restricted and always audited |
| Document referenced by a financial record | Never hard-deleted while the record exists; retention follows the financial retention class |
| Legal hold | `is_legal_hold = true` blocks deletion and expiry regardless of retention class |
| Company offboarding | Export package (documents + data) produced, retention countdown started, then prefix-level deletion with an audit record |
| Storage versioning | An accidental overwrite is recoverable from the object version history |
| Backup copies | Documents are covered by the encrypted backup strategy ([O](O-backup-disaster-recovery.md)); deletion in the live system does not immediately remove backup copies, which is intentional and disclosed in the retention policy |

---

## 7. Threats addressed

| Threat | Mitigation |
|---|---|
| Malicious upload (webshell, macro, exploit) | Allow-listed types + magic-byte check + AV scan + no execution path + private storage |
| Zip bomb / XML bomb in XLSX | Parsing limits in the worker, expanded-size caps, hardened XML parser |
| SSRF via document URL | The app never fetches user-supplied URLs in V1; the pdf/worker containers have no outbound access ([B §5](B-infrastructure-architecture.md)) |
| Path traversal | Keys are server-generated UUIDs; filenames never touch the filesystem |
| Tenancy leak via storage | Tenant-scoped prefixes, per-tenant presigning scope, authorization before any presign, and tests asserting that Company A cannot obtain a URL for Company B's object |
| Leaked link | Short TTL, audited issuance, revocable by disabling the document |
| Storage compromise | Private buckets + SSE + LUKS + separate backup credentials + anomaly alerts on download volume |
| Insider exfiltration | Every download audited, bulk download/export rate-limited and alerted, exports are permission-gated (`financials.export`) with AAL2 |
