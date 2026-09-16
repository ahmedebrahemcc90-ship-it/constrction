-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 05 of 13
-- Transactional import pipeline: Upload/parse -> validate -> preview -> explicit
-- confirmation -> atomic commit/rollback.
--
-- DESIGN: the uploaded file is never written directly into business tables. It is parsed
-- into a STAGING batch (`import_rows`) that can be inspected, corrected and re-validated.
-- Only an explicit, audited confirmation runs the commit transaction, which either writes
-- every row or none. The staging batch is retained afterwards as the import evidence.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Import batches
-- -------------------------------------------------------------------------------------
CREATE TABLE public.import_batches (
    id                  uuid PRIMARY KEY,
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    project_id          uuid,
    contract_id         uuid,
    target_boq_id       uuid,                     -- when importing into an existing draft BOQ
    import_type         text NOT NULL CHECK (import_type IN (
                            'boq','budget','expenses','collections','cost_codes','wbs','parties','opening_balances'
                        )),
    status              text NOT NULL DEFAULT 'uploaded' CHECK (status IN (
                            'uploaded','parsing','parse_failed',
                            'validating','preview_ready','validation_failed',
                            'awaiting_confirmation','committing','committed',
                            'commit_failed','cancelled','expired'
                        )),
    source_document_id  uuid NOT NULL,            -- documents.id (private object storage, file 09)
    original_filename   text NOT NULL,
    file_sha256         text NOT NULL CHECK (file_sha256 ~ '^[0-9a-f]{64}$'),
    file_size_bytes     bigint NOT NULL CHECK (file_size_bytes > 0 AND file_size_bytes <= 26214400),  -- 25 MB cap
    sheet_name          text,
    header_row_no       integer NOT NULL DEFAULT 1 CHECK (header_row_no >= 0),
    column_mapping      jsonb NOT NULL DEFAULT '{}'::jsonb,
    mapping_template_id uuid,
    options             jsonb NOT NULL DEFAULT '{}'::jsonb,   -- e.g. {"update_existing":false,"skip_zeros":true}

    -- Validation/commit accounting
    rows_total          integer NOT NULL DEFAULT 0,
    rows_valid          integer NOT NULL DEFAULT 0,
    rows_warning        integer NOT NULL DEFAULT 0,
    rows_error          integer NOT NULL DEFAULT 0,
    preview_hash        text,                     -- hash of the staged data confirmed by the user
    validation_summary  jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Lifecycle evidence
    uploaded_by         uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    parse_started_at    timestamptz,
    parsed_at           timestamptz,
    validated_at        timestamptz,
    confirmed_by        uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    confirmed_at        timestamptz,
    committed_by        uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    committed_at        timestamptz,
    cancelled_by        uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    cancelled_at        timestamptz,
    failure_reason      text,
    expires_at          timestamptz,              -- staged data auto-purged after this instant
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    version             integer NOT NULL DEFAULT 1,

    CONSTRAINT uq_import_batches_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_import_batches_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_import_batches_contract FOREIGN KEY (company_id, contract_id)
        REFERENCES public.contracts (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_import_batches_boq FOREIGN KEY (company_id, target_boq_id)
        REFERENCES public.boqs (company_id, id) ON DELETE RESTRICT,
    -- Commit can only ever happen from the explicitly confirmed state.
    CONSTRAINT ck_import_batches_commit_only_after_confirm CHECK (
        status NOT IN ('committing','committed','commit_failed')
        OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL)
    ),
    -- Preview is only meaningful once validation ran.
    CONSTRAINT ck_import_batches_preview_after_validate CHECK (
        status <> 'preview_ready' OR validated_at IS NOT NULL
    )
);
CREATE INDEX idx_import_batches_company_status ON public.import_batches (company_id, status, created_at DESC);
CREATE INDEX idx_import_batches_expiry ON public.import_batches (expires_at) WHERE status IN ('preview_ready','awaiting_confirmation','validation_failed');
COMMENT ON TABLE public.import_batches IS
    'One row per upload attempt. Retained permanently as import evidence (auditability of how a BOQ came to exist).';

-- -------------------------------------------------------------------------------------
-- 2. Staged rows (the parsed-but-not-committed data)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.import_rows (
    id             uuid PRIMARY KEY,
    company_id     uuid NOT NULL,
    batch_id       uuid NOT NULL,
    row_no         integer NOT NULL,              -- 1-based row number in the source sheet
    raw_data       jsonb NOT NULL,                -- original cell values, verbatim
    mapped_data    jsonb,                         -- after column mapping, before validation coercion
    normalized     jsonb,                         -- typed/trimmed values used by validation
    validation_status text NOT NULL DEFAULT 'pending'
                       CHECK (validation_status IN ('pending','valid','warning','error','skipped')),
    proposed_action text CHECK (proposed_action IN ('insert','update','skip')),
    matched_entity_id uuid,                       -- e.g. existing boq_items.id for update rows
    computed_amount numeric(20,2),                -- qty x rate as computed server-side
    row_hash       text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_import_rows_batch_row UNIQUE (company_id, batch_id, row_no),
    CONSTRAINT fk_import_rows_batch FOREIGN KEY (company_id, batch_id)
        REFERENCES public.import_batches (company_id, id) ON DELETE CASCADE
);
CREATE INDEX idx_import_rows_status ON public.import_rows (company_id, batch_id, validation_status);

CREATE TABLE public.import_validation_issues (
    id           uuid PRIMARY KEY,
    company_id   uuid NOT NULL,
    batch_id     uuid NOT NULL,
    row_no       integer,
    severity     text NOT NULL CHECK (severity IN ('error','warning','info')),
    issue_code   text NOT NULL,                   -- e.g. 'MISSING_UNIT','UNKNOWN_ITEM_CODE','NEGATIVE_RATE','DUPLICATE_CODE','FORMULA_IN_AMOUNT'
    field_name   text,
    message_en   text NOT NULL,
    message_ar   text NOT NULL,
    raw_value    text,
    suggestion   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_import_issues_batch FOREIGN KEY (company_id, batch_id)
        REFERENCES public.import_batches (company_id, id) ON DELETE CASCADE
);
CREATE INDEX idx_import_issues_batch ON public.import_validation_issues (company_id, batch_id, severity, row_no);

-- -------------------------------------------------------------------------------------
-- 3. Saved column-mapping templates (each client sends a different Excel layout)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.import_column_mappings (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    name          text NOT NULL,
    import_type   text NOT NULL,
    mapping       jsonb NOT NULL,                 -- {"source_header": "target_field"}
    header_signature text NOT NULL,               -- hash of the header row, for auto-suggestion
    options       jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_default    boolean NOT NULL DEFAULT false,
    created_by    uuid,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_import_column_mappings UNIQUE (company_id, import_type, header_signature)
);

-- -------------------------------------------------------------------------------------
-- 4. Commit protocol (implemented in the service layer; specified here because the
--    transactional guarantees are part of the schema contract)
-- -------------------------------------------------------------------------------------
-- COMMIT TRANSACTION SHAPE:
--   BEGIN;
--     SET LOCAL app.current_company_id = <company>;  SET LOCAL app.current_user_id = <actor>;
--     -- 1. serialise against concurrent imports into the same BOQ
--     SELECT pg_advisory_xact_lock(hashtext('boq_import:' || <target_boq_id>::text));
--     -- 2. re-verify preconditions INSIDE the transaction (state may have changed since preview)
--     SELECT status, preview_hash FROM import_batches WHERE ... FOR UPDATE;
--       -> must be 'awaiting_confirmation'; preview_hash must equal the confirmed hash
--       -> target BOQ must still be 'draft' (or the import creates a new draft BOQ)
--     -- 3. re-run validation against current DB state (units exist, codes unique, no duplicates)
--     -- 4. write business rows: boq_sections / boq_items (+ import_batch_id traceability)
--     -- 5. recompute boq total via trigger; assert equality with the previewed total
--     -- 6. write audit_logs + outbox event
--     UPDATE import_batches SET status='committed', committed_at=now(), committed_by=...;
--   COMMIT;
--
-- Failure at any step => ROLLBACK: no partial BOQ exists, and the batch returns to
-- 'awaiting_confirmation' (or 'commit_failed' with the reason) so the user can fix and retry.
-- The import source file and the staged rows are never deleted, so a committed BOQ can always
-- be traced back to the exact file, sheet, row and user that produced it.

-- -------------------------------------------------------------------------------------
-- 5. Triggers
-- -------------------------------------------------------------------------------------
CREATE TRIGGER trg_import_batches_tenant_guard
    BEFORE INSERT OR UPDATE ON public.import_batches
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_import_batches_touch
    BEFORE UPDATE ON public.import_batches
    FOR EACH ROW EXECUTE FUNCTION app.touch_row();
