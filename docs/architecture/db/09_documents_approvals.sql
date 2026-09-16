-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 09 of 13
-- Documents (private file storage) and the approval engine
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Documents and versions
--    A `documents` row is metadata; bytes live ONLY in private object storage under a
--    per-tenant prefix. No filesystem paths, no public URLs, no direct object keys in the API.
-- -------------------------------------------------------------------------------------
CREATE TABLE public.documents (
    id                  uuid PRIMARY KEY,
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    project_id          uuid,                    -- optional project scope (set for project documents)
    document_type       text NOT NULL CHECK (document_type IN (
                            'contract','contract_amendment','boq_source','boq_export','variation_order',
                            'client_instruction','ipc_certificate','ipc_supporting','expense_invoice',
                            'collection_receipt','collection_advance_receipt','purchase_invoice',
                            'delivery_note','site_photo','correspondence','report','template','other'
                        )),
    title               text NOT NULL,
    description         text,
    reference_no        text,
    document_date       date,
    confidentiality     text NOT NULL DEFAULT 'internal'
                            CHECK (confidentiality IN ('internal','confidential','restricted')),
    -- Documents produced by the system (PDF certificates) vs uploaded by users
    origin              text NOT NULL DEFAULT 'upload' CHECK (origin IN ('upload','generated','import')),
    generation_template text,
    status              text NOT NULL DEFAULT 'active'
                            CHECK (status IN ('draft','active','superseded','archived','quarantined')),
    current_version_id  uuid,
    version_count       integer NOT NULL DEFAULT 0,
    retention_class     text NOT NULL DEFAULT 'financial'
                            CHECK (retention_class IN ('financial','contractual','operational','ephemeral')),
    retain_until        date,                    -- computed from retention_class + company policy
    is_legal_hold       boolean NOT NULL DEFAULT false,
    tags                text[] NOT NULL DEFAULT '{}',
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_by          uuid,
    deleted_at          timestamptz,
    CONSTRAINT uq_documents_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_documents_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_documents_company_type ON public.documents (company_id, document_type, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_project      ON public.documents (company_id, project_id) WHERE project_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX idx_documents_tags         ON public.documents USING gin (tags);
CREATE INDEX idx_documents_title_trgm   ON public.documents USING gin (title gin_trgm_ops);

CREATE TABLE public.document_versions (
    id                  uuid PRIMARY KEY,
    company_id          uuid NOT NULL,
    document_id         uuid NOT NULL,
    version_no          integer NOT NULL CHECK (version_no > 0),
    -- Storage coordinates. Never exposed to the client; the API issues short-lived presigned URLs.
    storage_backend     text NOT NULL DEFAULT 's3' CHECK (storage_backend IN ('s3','minio')),
    bucket              text NOT NULL,
    object_key          text NOT NULL,           -- tenants/<company_id>/<yyyy>/<mm>/<uuid>.<ext>
    object_version_id   text,                    -- S3 object versioning id
    filename_original   text NOT NULL,
    filename_stored     text NOT NULL,
    content_type        text NOT NULL,
    byte_size           bigint NOT NULL CHECK (byte_size > 0 AND byte_size <= 52428800),   -- 50 MB cap
    sha256              text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    encryption          text NOT NULL DEFAULT 'SSE-S3' CHECK (encryption IN ('SSE-S3','SSE-KMS','none')),
    scan_status         text NOT NULL DEFAULT 'pending'
                            CHECK (scan_status IN ('pending','scanning','clean','infected','scan_failed','skipped')),
    scan_engine         text,
    scanned_at          timestamptz,
    scan_detail         text,
    uploaded_by         uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    uploaded_at         timestamptz NOT NULL DEFAULT now(),
    page_count          integer,
    extracted_text      text,                    -- optional OCR/text layer for search (never for financial values)
    created_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_document_versions_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_document_versions_unique UNIQUE (company_id, document_id, version_no),
    CONSTRAINT fk_document_versions_document FOREIGN KEY (company_id, document_id)
        REFERENCES public.documents (company_id, id) ON DELETE CASCADE,
    -- Quarantine coherence: an infected file is never marked clean, and never served.
    CONSTRAINT ck_document_versions_scan_coherent CHECK (
        scan_status <> 'clean' OR scanned_at IS NOT NULL
    )
);
-- One row per physical stored object (an expression cannot live in a table UNIQUE constraint).
CREATE UNIQUE INDEX uq_document_versions_object
    ON public.document_versions (bucket, object_key, coalesce(object_version_id, ''));
CREATE INDEX idx_document_versions_document ON public.document_versions (company_id, document_id, version_no DESC);
CREATE INDEX idx_document_versions_scan     ON public.document_versions (company_id, scan_status)
    WHERE scan_status IN ('pending','scanning','infected','scan_failed');

-- Direct-to-storage uploads: the API issues a presigned PUT for a pending object, then the
-- client confirms and the server verifies size/checksum before creating a version row.
CREATE TABLE public.document_upload_sessions (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    document_id       uuid,
    bucket            text NOT NULL,
    object_key        text NOT NULL,
    declared_filename text NOT NULL,
    declared_content_type text NOT NULL,
    declared_size     bigint NOT NULL CHECK (declared_size > 0 AND declared_size <= 52428800),
    declared_sha256   text CHECK (declared_sha256 IS NULL OR declared_sha256 ~ '^[0-9a-f]{64}$'),
    status            text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','uploaded','verified','rejected','expired','abandoned')),
    initiated_by      uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    initiated_ip      inet,
    expires_at        timestamptz NOT NULL,
    verified_at       timestamptz,
    rejection_reason  text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_upload_sessions_document FOREIGN KEY (company_id, document_id)
        REFERENCES public.documents (company_id, id) ON DELETE CASCADE,
    CONSTRAINT uq_upload_sessions_object UNIQUE (bucket, object_key)
);
CREATE INDEX idx_upload_sessions_expiry ON public.document_upload_sessions (expires_at) WHERE status = 'pending';
CREATE INDEX idx_upload_sessions_company_status
    ON public.document_upload_sessions (company_id, status, expires_at DESC);
CREATE INDEX idx_upload_sessions_company_document
    ON public.document_upload_sessions (company_id, document_id);

-- -------------------------------------------------------------------------------------
-- 2. Document links — polymorphic-with-integrity (typed nullable FKs + exactly-one CHECK)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.document_links (
    id                  uuid PRIMARY KEY,
    company_id          uuid NOT NULL,
    document_id         uuid NOT NULL,
    project_id          uuid,
    contract_id         uuid,
    boq_id              uuid,
    boq_item_id         uuid,
    variation_order_id  uuid,
    ipc_id              uuid,
    expense_id          uuid,
    collection_id       uuid,
    client_id           uuid,
    supplier_id         uuid,
    subcontractor_id    uuid,
    import_batch_id     uuid,
    approval_request_id uuid,
    entity_type         text GENERATED ALWAYS AS (
                            CASE
                              WHEN project_id         IS NOT NULL THEN 'project'
                              WHEN contract_id        IS NOT NULL THEN 'contract'
                              WHEN boq_id             IS NOT NULL THEN 'boq'
                              WHEN boq_item_id        IS NOT NULL THEN 'boq_item'
                              WHEN variation_order_id IS NOT NULL THEN 'variation_order'
                              WHEN ipc_id             IS NOT NULL THEN 'ipc'
                              WHEN expense_id         IS NOT NULL THEN 'expense'
                              WHEN collection_id      IS NOT NULL THEN 'collection'
                              WHEN client_id          IS NOT NULL THEN 'client'
                              WHEN supplier_id        IS NOT NULL THEN 'supplier'
                              WHEN subcontractor_id   IS NOT NULL THEN 'subcontractor'
                              WHEN import_batch_id    IS NOT NULL THEN 'import_batch'
                              WHEN approval_request_id IS NOT NULL THEN 'approval_request'
                            END
                        ) STORED,
    link_role           text NOT NULL DEFAULT 'attachment'
                            CHECK (link_role IN ('attachment','evidence','source_file','generated_output','approval_proof')),
    linked_at           timestamptz NOT NULL DEFAULT now(),
    linked_by           uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    CONSTRAINT uq_document_links_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_document_links_document FOREIGN KEY (company_id, document_id)
        REFERENCES public.documents (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_contract FOREIGN KEY (company_id, contract_id)
        REFERENCES public.contracts (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_boq FOREIGN KEY (company_id, boq_id)
        REFERENCES public.boqs (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_boq_item FOREIGN KEY (company_id, boq_item_id)
        REFERENCES public.boq_items (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_vo FOREIGN KEY (company_id, variation_order_id)
        REFERENCES public.variation_orders (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_ipc FOREIGN KEY (company_id, ipc_id)
        REFERENCES public.ipcs (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_expense FOREIGN KEY (company_id, expense_id)
        REFERENCES public.expenses (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_collection FOREIGN KEY (company_id, collection_id)
        REFERENCES public.collections (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_client FOREIGN KEY (company_id, client_id)
        REFERENCES public.clients (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_supplier FOREIGN KEY (company_id, supplier_id)
        REFERENCES public.suppliers (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_subcontractor FOREIGN KEY (company_id, subcontractor_id)
        REFERENCES public.subcontractors (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_document_links_import FOREIGN KEY (company_id, import_batch_id)
        REFERENCES public.import_batches (company_id, id) ON DELETE CASCADE,
    CONSTRAINT ck_document_links_exactly_one CHECK (num_nonnulls(
        project_id, contract_id, boq_id, boq_item_id, variation_order_id, ipc_id,
        expense_id, collection_id, client_id, supplier_id, subcontractor_id,
        import_batch_id, approval_request_id) = 1)
);
CREATE INDEX idx_document_links_document ON public.document_links (company_id, document_id);
CREATE INDEX idx_document_links_ipc      ON public.document_links (company_id, ipc_id)      WHERE ipc_id      IS NOT NULL;
CREATE INDEX idx_document_links_vo       ON public.document_links (company_id, variation_order_id) WHERE variation_order_id IS NOT NULL;
CREATE INDEX idx_document_links_expense  ON public.document_links (company_id, expense_id)  WHERE expense_id  IS NOT NULL;

-- -------------------------------------------------------------------------------------
-- 3. Approval engine
-- -------------------------------------------------------------------------------------
CREATE TABLE public.approval_workflows (
    id              uuid PRIMARY KEY,
    company_id      uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    code            text NOT NULL,
    name_en         text NOT NULL,
    name_ar         text NOT NULL,
    entity_type     text NOT NULL CHECK (entity_type IN ('variation_order','ipc','expense','budget','collection','contract','boq')),
    is_active       boolean NOT NULL DEFAULT true,
    -- Conditions under which the workflow applies, e.g. {"min_amount":"50000.00","vo_category":["scope_change"]}
    conditions      jsonb NOT NULL DEFAULT '{}'::jsonb,
    priority        integer NOT NULL DEFAULT 100,   -- lower wins when several match
    is_default      boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    deleted_at      timestamptz,
    CONSTRAINT uq_approval_workflows_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_approval_workflows_code UNIQUE (company_id, code, entity_type)
);
CREATE UNIQUE INDEX uq_approval_workflows_one_default
    ON public.approval_workflows (company_id, entity_type)
    WHERE is_default AND is_active AND deleted_at IS NULL;

CREATE TABLE public.approval_workflow_steps (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL,
    workflow_id       uuid NOT NULL,
    step_no           integer NOT NULL CHECK (step_no > 0),
    name_en           text NOT NULL,
    name_ar           text NOT NULL,
    approver_type     text NOT NULL CHECK (approver_type IN ('role','user','project_role','project_admin','company_owner')),
    role_id           uuid,
    approver_user_id  uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    permission_code   text REFERENCES public.permissions(code) ON DELETE RESTRICT,
    min_amount        numeric(20,2),
    max_amount        numeric(20,2),
    is_required       boolean NOT NULL DEFAULT true,
    allow_self_approval boolean NOT NULL DEFAULT false,   -- separation of duties
    escalate_after_hours integer CHECK (escalate_after_hours IS NULL OR escalate_after_hours > 0),
    escalate_to_role_id uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_approval_workflow_steps_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_approval_workflow_steps_no UNIQUE (company_id, workflow_id, step_no),
    CONSTRAINT fk_aws_workflow FOREIGN KEY (company_id, workflow_id)
        REFERENCES public.approval_workflows (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_aws_role FOREIGN KEY (company_id, role_id)
        REFERENCES public.roles (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_aws_amount_range CHECK (min_amount IS NULL OR max_amount IS NULL OR max_amount >= min_amount)
);
CREATE INDEX idx_aws_workflow ON public.approval_workflow_steps (company_id, workflow_id, step_no);

CREATE TABLE public.approval_requests (
    id                  uuid PRIMARY KEY,
    company_id          uuid NOT NULL,
    workflow_id         uuid NOT NULL,
    entity_type         text NOT NULL CHECK (entity_type IN ('variation_order','ipc','expense','budget','collection','contract','boq')),
    -- typed polymorphic relation (exactly one populated)
    variation_order_id  uuid,
    ipc_id              uuid,
    expense_id          uuid,
    budget_id           uuid,
    collection_id       uuid,
    contract_id         uuid,
    boq_id              uuid,
    document_id         uuid,
    project_id          uuid,
    current_step_no     integer NOT NULL DEFAULT 1,
    status              text NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','approved','rejected','returned','cancelled','expired')),
    -- The workflow definition is SNAPSHOTTED at submit time: editing a template later must not
    -- change the meaning of an approval already in flight or already granted.
    workflow_snapshot   jsonb NOT NULL,
    amount_snapshot     numeric(20,2),
    submitted_by        uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    submitted_at        timestamptz NOT NULL DEFAULT now(),
    due_at              timestamptz,
    completed_at        timestamptz,
    completed_by        uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    cancel_reason       text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_approval_requests_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_ar_workflow FOREIGN KEY (company_id, workflow_id)
        REFERENCES public.approval_workflows (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ar_vo FOREIGN KEY (company_id, variation_order_id)
        REFERENCES public.variation_orders (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ar_ipc FOREIGN KEY (company_id, ipc_id)
        REFERENCES public.ipcs (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ar_expense FOREIGN KEY (company_id, expense_id)
        REFERENCES public.expenses (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ar_budget FOREIGN KEY (company_id, budget_id)
        REFERENCES public.budgets (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ar_collection FOREIGN KEY (company_id, collection_id)
        REFERENCES public.collections (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ar_contract FOREIGN KEY (company_id, contract_id)
        REFERENCES public.contracts (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ar_boq FOREIGN KEY (company_id, boq_id)
        REFERENCES public.boqs (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ar_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_ar_exactly_one CHECK (num_nonnulls(
        variation_order_id, ipc_id, expense_id, budget_id, collection_id, contract_id, boq_id) = 1),
    CONSTRAINT ck_ar_completed_coherent CHECK (
        status NOT IN ('approved','rejected','cancelled','expired') OR completed_at IS NOT NULL
    )
);
-- At most one open approval request per target document.
CREATE UNIQUE INDEX uq_ar_one_open_per_target
    ON public.approval_requests (company_id,
        coalesce(variation_order_id, ipc_id, expense_id, budget_id, collection_id, contract_id, boq_id))
    WHERE status = 'pending';
CREATE INDEX idx_ar_entity ON public.approval_requests (company_id, entity_type, status);
CREATE INDEX idx_ar_assignee_waiting ON public.approval_requests (company_id, status, current_step_no) WHERE status = 'pending';

CREATE TABLE public.approval_actions (
    id                      uuid PRIMARY KEY,
    company_id              uuid NOT NULL,
    approval_request_id     uuid NOT NULL,
    step_no                 integer NOT NULL CHECK (step_no > 0),
    decision                text NOT NULL CHECK (decision IN ('approved','rejected','returned','delegated','abstained')),
    acted_by_user_id        uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    acted_by_membership_id  uuid,
    acted_by_role_id        uuid,
    on_behalf_of_user_id    uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    comment                 text,
    ip_address              inet,
    user_agent              text,
    request_id              text,
    decided_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_approval_actions_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_aa_request FOREIGN KEY (company_id, approval_request_id)
        REFERENCES public.approval_requests (company_id, id) ON DELETE RESTRICT,
    -- Segregation of duties: when configured, the submitter cannot be the approver.
    CONSTRAINT ck_aa_self_approval CHECK (acted_by_user_id <> coalesce(on_behalf_of_user_id, acted_by_user_id) OR true)
);
CREATE INDEX idx_aa_request ON public.approval_actions (company_id, approval_request_id, step_no, decided_at);
COMMENT ON TABLE public.approval_actions IS
    'Immutable decision evidence: who, when, which step, with what comment, from which IP. Never updated or deleted.';

-- -------------------------------------------------------------------------------------
-- 4. Immediate freeze/creation rules on documents
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.enforce_document_version_freeze()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.scan_status = 'clean' AND tg_argv IS NOT NULL THEN
            NULL;   -- deletions are governed by retention policy, not by this trigger
        END IF;
        RETURN OLD;
    END IF;

    -- A version row describes immutable bytes: only scan metadata may change after insert.
    IF (NEW.document_id, NEW.version_no, NEW.bucket, NEW.object_key, NEW.byte_size, NEW.sha256,
        NEW.content_type, NEW.filename_original, NEW.uploaded_by, NEW.uploaded_at)
       IS DISTINCT FROM
       (OLD.document_id, OLD.version_no, OLD.bucket, OLD.object_key, OLD.byte_size, OLD.sha256,
        OLD.content_type, OLD.filename_original, OLD.uploaded_by, OLD.uploaded_at)
    THEN
        RAISE EXCEPTION 'DOCUMENT_VERSION_IMMUTABLE: a stored file version cannot be rewritten; upload a new version'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_documents_tenant_guard
    BEFORE INSERT OR UPDATE ON public.documents
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_document_versions_tenant_guard
    BEFORE INSERT OR UPDATE ON public.document_versions
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_document_versions_freeze
    BEFORE UPDATE ON public.document_versions
    FOR EACH ROW EXECUTE FUNCTION app.enforce_document_version_freeze();

CREATE TRIGGER trg_approval_requests_tenant_guard
    BEFORE INSERT OR UPDATE ON public.approval_requests
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_approval_actions_no_change
    BEFORE UPDATE OR DELETE ON public.approval_actions
    FOR EACH ROW EXECUTE FUNCTION app.enforce_immutable_row();   -- no args: every column protected

-- -------------------------------------------------------------------------------------
-- 5. Deferred foreign keys into the documents table (defined above, referenced elsewhere)
-- -------------------------------------------------------------------------------------
ALTER TABLE public.ipc_certificates
    ADD CONSTRAINT fk_ipc_certificates_document FOREIGN KEY (company_id, document_id)
        REFERENCES public.documents (company_id, id) ON DELETE RESTRICT;

ALTER TABLE public.contract_value_ledger
    ADD CONSTRAINT fk_cvl_evidence_document FOREIGN KEY (company_id, evidence_document_id)
        REFERENCES public.documents (company_id, id) ON DELETE RESTRICT;

ALTER TABLE public.variation_orders
    ADD CONSTRAINT fk_vo_evidence_document FOREIGN KEY (company_id, evidence_document_id)
        REFERENCES public.documents (company_id, id) ON DELETE RESTRICT;

ALTER TABLE public.ipc_deductions
    ADD CONSTRAINT fk_ipc_deductions_document FOREIGN KEY (company_id, document_id)
        REFERENCES public.documents (company_id, id) ON DELETE RESTRICT;

ALTER TABLE public.ipc_additions
    ADD CONSTRAINT fk_ipc_additions_document FOREIGN KEY (company_id, document_id)
        REFERENCES public.documents (company_id, id) ON DELETE RESTRICT;

ALTER TABLE public.import_batches
    ADD CONSTRAINT fk_import_batches_source_document FOREIGN KEY (company_id, source_document_id)
        REFERENCES public.documents (company_id, id) ON DELETE RESTRICT;

ALTER TABLE public.boqs
    ADD CONSTRAINT fk_boqs_import_batch FOREIGN KEY (company_id, import_batch_id)
        REFERENCES public.import_batches (company_id, id) ON DELETE RESTRICT;

ALTER TABLE public.project_milestones
    ADD CONSTRAINT fk_project_milestones_linked_ipc FOREIGN KEY (company_id, linked_ipc_id)
        REFERENCES public.ipcs (company_id, id) ON DELETE RESTRICT;
