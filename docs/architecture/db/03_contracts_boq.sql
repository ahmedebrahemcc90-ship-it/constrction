-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 03 of 13
-- Contracts, contract value ledger, BOQ (sections / items / revisions)
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Contracts
-- -------------------------------------------------------------------------------------
CREATE TABLE public.contracts (
    id                       uuid PRIMARY KEY,
    company_id               uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    project_id               uuid NOT NULL,
    client_id                uuid NOT NULL,
    contract_number          text NOT NULL,
    external_reference       text,                       -- client-side contract reference
    title_en                 text NOT NULL,
    title_ar                 text NOT NULL,
    contract_type            text NOT NULL
                                 CHECK (contract_type IN ('lump_sum','unit_price','cost_plus','design_build','other')),
    currency_code            char(3) NOT NULL DEFAULT 'SAR' REFERENCES public.currencies(code),
    original_value           numeric(20,2) NOT NULL CHECK (original_value >= 0),
    -- Cached view of SUM(contract_value_ledger.amount_delta). Authoritative value is ALWAYS the
    -- ledger; this column exists for fast dashboards and is reconciled nightly (see file 11).
    current_value            numeric(20,2) NOT NULL DEFAULT 0,
    value_last_reconciled_at timestamptz,
    is_vat_inclusive         boolean NOT NULL DEFAULT false,
    -- Commercial terms kept on the contract AND snapshotted per IPC at certification time.
    retention_pct            numeric(9,4) NOT NULL DEFAULT 5.0 CHECK (retention_pct BETWEEN 0 AND 100),
    retention_cap_pct        numeric(9,4) CHECK (retention_cap_pct BETWEEN 0 AND 100),
    retention_release_rule   text CHECK (retention_release_rule IN ('on_completion','half_on_completion_half_on_defects','staged','custom')),
    advance_amount           numeric(20,2) NOT NULL DEFAULT 0 CHECK (advance_amount >= 0),
    advance_recovery_pct     numeric(9,4) NOT NULL DEFAULT 0 CHECK (advance_recovery_pct BETWEEN 0 AND 100),
    advance_recovery_mode    text NOT NULL DEFAULT 'proportional'
                                 CHECK (advance_recovery_mode IN ('proportional','fixed_installments','milestone')),
    payment_terms_days       integer NOT NULL DEFAULT 30 CHECK (payment_terms_days BETWEEN 0 AND 365),
    performance_bond_pct     numeric(9,4) CHECK (performance_bond_pct BETWEEN 0 AND 100),
    signed_date              date,
    start_date               date,
    completion_date          date,
    extended_completion_date date,
    status                   text NOT NULL DEFAULT 'draft'
                                 CHECK (status IN ('draft','active','on_hold','substantially_completed','completed','terminated','closed')),
    is_primary               boolean NOT NULL DEFAULT true,
    notes                    text,
    version                  integer NOT NULL DEFAULT 1,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid,
    updated_by               uuid,
    deleted_at               timestamptz,
    CONSTRAINT uq_contracts_company_id_id UNIQUE (company_id, id),
    -- project-scoped parent key: variation orders, IPCs, expenses and collections reference
    -- (company_id, project_id, id) so a contract can never be attached to the wrong project.
    CONSTRAINT uq_contracts_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT fk_contracts_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_contracts_client FOREIGN KEY (company_id, client_id)
        REFERENCES public.clients (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_contracts_dates CHECK (completion_date IS NULL OR start_date IS NULL OR completion_date >= start_date)
);
CREATE UNIQUE INDEX uq_contracts_company_number ON public.contracts (company_id, contract_number) WHERE deleted_at IS NULL;
-- At most one primary active contract per project drives the V1 dashboards.
CREATE UNIQUE INDEX uq_contracts_one_primary_active
    ON public.contracts (company_id, project_id)
    WHERE is_primary AND status = 'active' AND deleted_at IS NULL;
CREATE INDEX idx_contracts_project ON public.contracts (company_id, project_id, status);

-- -------------------------------------------------------------------------------------
-- 2. Contract value ledger — APPEND-ONLY. The only authority for revised contract value.
--    Revised Contract Value = original_value + SUM(amount_delta) over posted entries.
--    Only APPROVED variation orders may create an increase (docs K §3, INV-13/14/15).
-- -------------------------------------------------------------------------------------
CREATE TABLE public.contract_value_ledger (
    id               uuid PRIMARY KEY,
    company_id       uuid NOT NULL,
    contract_id      uuid NOT NULL,
    entry_type       text NOT NULL CHECK (entry_type IN (
                         'original_contract',
                         'variation_approved',
                         'omission_approved',
                         'contract_amendment',
                         'remeasurement_correction',
                         'reversal'
                     )),
    -- Signed delta in contract currency. Negative only for omissions/reversals.
    amount_delta     numeric(20,2) NOT NULL,
    effective_date   date NOT NULL,
    source_type      text NOT NULL CHECK (source_type IN ('contract','variation_order','manual_adjustment')),
    source_id        uuid,                        -- variation_orders.id or contracts.id when applicable
    source_reference text,                        -- display reference, never used for logic
    reason           text NOT NULL,
    evidence_document_id uuid,
    approved_by      uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    approved_at      timestamptz,
    posted_at        timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    reverses_id      uuid REFERENCES public.contract_value_ledger(id) ON DELETE RESTRICT,
    CONSTRAINT fk_cvl_contract FOREIGN KEY (company_id, contract_id)
        REFERENCES public.contracts (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_cvl_sign CHECK (
        (entry_type IN ('omission_approved','reversal') AND amount_delta <= 0)
        OR (entry_type NOT IN ('omission_approved','reversal') AND amount_delta >= 0)
    ),
    CONSTRAINT ck_cvl_source_coherent CHECK (
        (entry_type = 'original_contract'    AND source_type = 'contract') OR
        (entry_type = 'variation_approved'   AND source_type = 'variation_order' AND source_id IS NOT NULL) OR
        (entry_type = 'omission_approved'    AND source_type = 'variation_order' AND source_id IS NOT NULL) OR
        (entry_type = 'contract_amendment'   AND source_type IN ('contract','manual_adjustment')) OR
        (entry_type = 'remeasurement_correction') OR
        (entry_type = 'reversal')
    ),
    CONSTRAINT ck_cvl_reversal_reference CHECK ((entry_type = 'reversal') = (reverses_id IS NOT NULL))
);
-- Idempotency: a given source document can affect contract value at most once per entry type.
CREATE UNIQUE INDEX uq_cvl_source_once
    ON public.contract_value_ledger (company_id, source_type, source_id, entry_type)
    WHERE source_id IS NOT NULL AND entry_type <> 'reversal';
CREATE UNIQUE INDEX uq_cvl_one_original
    ON public.contract_value_ledger (company_id, contract_id, entry_type)
    WHERE entry_type = 'original_contract';
CREATE INDEX idx_cvl_contract ON public.contract_value_ledger (company_id, contract_id, effective_date);
COMMENT ON TABLE public.contract_value_ledger IS
    'Append-only authority for revised contract value. Application role has INSERT/SELECT only (see file 13).';

-- -------------------------------------------------------------------------------------
-- 3. BOQ header — versioned per contract; exactly one approved revision is the measurement
--    baseline at any time.
-- -------------------------------------------------------------------------------------
CREATE TABLE public.boqs (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL,
    project_id         uuid NOT NULL,
    contract_id        uuid NOT NULL,
    revision_no        integer NOT NULL CHECK (revision_no > 0),
    title_en           text NOT NULL,
    title_ar           text NOT NULL,
    currency_code      char(3) NOT NULL DEFAULT 'SAR' REFERENCES public.currencies(code),
    vat_mode           text NOT NULL DEFAULT 'exclusive' CHECK (vat_mode IN ('exclusive','inclusive')),
    -- Derived cache of SUM(boq_items.amount); recomputed by trigger and by nightly reconciliation.
    total_amount       numeric(20,2) NOT NULL DEFAULT 0,
    status             text NOT NULL DEFAULT 'draft'
                           CHECK (status IN ('draft','in_review','approved','superseded','archived')),
    based_on_boq_id    uuid,
    import_batch_id    uuid,                        -- set when created via Excel import (file 05)
    approved_by        uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    approved_at        timestamptz,
    notes              text,
    version            integer NOT NULL DEFAULT 1,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_by         uuid,
    deleted_at         timestamptz,
    CONSTRAINT uq_boqs_company_id_id UNIQUE (company_id, id),
    -- project-scoped parent key: lets children prove project membership structurally
    CONSTRAINT uq_boqs_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT uq_boqs_contract_revision UNIQUE (company_id, contract_id, revision_no),
    CONSTRAINT fk_boqs_contract FOREIGN KEY (company_id, contract_id)
        REFERENCES public.contracts (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_boqs_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_boqs_based_on FOREIGN KEY (company_id, based_on_boq_id)
        REFERENCES public.boqs (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_boqs_approved_coherent CHECK ((status = 'approved') = (approved_at IS NOT NULL))
);
-- One approved BOQ revision per contract: the measurement baseline.
CREATE UNIQUE INDEX uq_boqs_one_approved_per_contract
    ON public.boqs (company_id, contract_id)
    WHERE status = 'approved' AND deleted_at IS NULL;
CREATE INDEX idx_boqs_project ON public.boqs (company_id, project_id, status);

CREATE TABLE public.boq_sections (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL,
    project_id        uuid NOT NULL,
    boq_id            uuid NOT NULL,
    parent_section_id uuid,
    code              text NOT NULL,               -- e.g. '01', '01.02'
    title_en          text NOT NULL,
    title_ar          text NOT NULL,
    level             smallint NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 10),
    sort_order        integer NOT NULL DEFAULT 0,
    -- Materialized path for subtree queries ('/01/02/'); maintained by trigger.
    path              text NOT NULL DEFAULT '',
    subtotal_amount   numeric(20,2) NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid,
    updated_by        uuid,
    CONSTRAINT uq_boq_sections_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_boq_sections_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT uq_boq_sections_unique UNIQUE (company_id, boq_id, code),
    CONSTRAINT fk_boq_sections_boq FOREIGN KEY (company_id, project_id, boq_id)
        REFERENCES public.boqs (company_id, project_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_boq_sections_parent FOREIGN KEY (company_id, project_id, parent_section_id)
        REFERENCES public.boq_sections (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_boq_sections_not_self CHECK (parent_section_id IS NULL OR parent_section_id <> id)
);
CREATE INDEX idx_boq_sections_tree ON public.boq_sections (company_id, boq_id, parent_section_id, sort_order);
CREATE INDEX idx_boq_sections_path ON public.boq_sections (company_id, path text_pattern_ops);

-- -------------------------------------------------------------------------------------
-- 4. BOQ items — the priced revenue lines
-- -------------------------------------------------------------------------------------
CREATE TABLE public.boq_items (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL,
    project_id         uuid NOT NULL,
    boq_id             uuid NOT NULL,
    boq_section_id     uuid NOT NULL,
    parent_item_id     uuid,                        -- for roll-up/measured-parent items (nullable)
    item_code          text NOT NULL,               -- client's item number, e.g. '02.01.005'
    serial_no          text,                        -- alternative client indexing
    description_en     text NOT NULL,
    description_ar     text,
    specification      text,
    unit_id            uuid NOT NULL,
    quantity           numeric(18,6) NOT NULL CHECK (quantity >= 0),
    unit_rate          numeric(18,4) NOT NULL CHECK (unit_rate >= 0),
    -- DB-computed: clients can never send an amount that disagrees with qty x rate (INV-10).
    amount             numeric(20,2)
                           GENERATED ALWAYS AS (round(quantity * unit_rate, 2)) STORED,
    vat_rate_bp        integer NOT NULL DEFAULT 1500 CHECK (vat_rate_bp BETWEEN 0 AND 10000),
    item_nature        text NOT NULL DEFAULT 'measured'
                           CHECK (item_nature IN ('measured','lump_sum','provisional','star_rate','daywork')),
    is_omitted         boolean NOT NULL DEFAULT false,
    wbs_node_id        uuid,                        -- optional execution attribution
    cost_code_id       uuid,                        -- optional default cost classification
    sort_order         integer NOT NULL DEFAULT 0,
    source_row_no      integer,                     -- traceability back to the imported file
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_by         uuid,
    deleted_at         timestamptz,
    CONSTRAINT uq_boq_items_company_id_id UNIQUE (company_id, id),
    -- project-scoped parent key: IPC lines, expenses and budget lines prove project membership
    -- structurally by referencing (company_id, project_id, id) instead of (company_id, id).
    CONSTRAINT uq_boq_items_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT uq_boq_items_code UNIQUE (company_id, boq_id, item_code),
    CONSTRAINT fk_boq_items_boq FOREIGN KEY (company_id, project_id, boq_id)
        REFERENCES public.boqs (company_id, project_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_boq_items_section FOREIGN KEY (company_id, project_id, boq_section_id)
        REFERENCES public.boq_sections (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_boq_items_parent FOREIGN KEY (company_id, project_id, parent_item_id)
        REFERENCES public.boq_items (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_boq_items_not_self CHECK (parent_item_id IS NULL OR parent_item_id <> id),
    CONSTRAINT ck_boq_items_omitted_zero CHECK (NOT is_omitted OR quantity = 0)
    ,
    CONSTRAINT fk_boq_items_unit FOREIGN KEY (unit_id)
        REFERENCES public.units_of_measure(id) ON DELETE RESTRICT
);
CREATE INDEX idx_boq_items_section ON public.boq_items (company_id, boq_id, boq_section_id, sort_order);
CREATE INDEX idx_boq_items_wbs     ON public.boq_items (company_id, wbs_node_id) WHERE wbs_node_id IS NOT NULL;
CREATE INDEX idx_boq_items_cost    ON public.boq_items (company_id, cost_code_id) WHERE cost_code_id IS NOT NULL;
COMMENT ON COLUMN public.boq_items.amount IS
    'Generated column: round(quantity * unit_rate, 2). Never accepted from a client payload.';

-- -------------------------------------------------------------------------------------
-- 5. BOQ item history — every change while draft, and every post-approval revision change.
--    Enables "what did this item look like when IPC #4 was certified?" (docs I §7).
-- -------------------------------------------------------------------------------------
CREATE TABLE public.boq_item_versions (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL,
    boq_item_id        uuid NOT NULL,
    revision_no        integer NOT NULL,
    change_source      text NOT NULL CHECK (change_source IN ('draft_edit','boq_revision','variation_order','correction')),
    change_reason      text,
    change_source_id   uuid,                        -- e.g. variation_orders.id
    item_code          text NOT NULL,
    description_en     text NOT NULL,
    description_ar     text,
    unit_id            uuid NOT NULL,
    quantity           numeric(18,6) NOT NULL,
    unit_rate          numeric(18,4) NOT NULL,
    amount             numeric(20,2) NOT NULL,
    valid_from         timestamptz NOT NULL DEFAULT now(),
    valid_to           timestamptz,
    changed_by         uuid,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_boq_versions_item FOREIGN KEY (company_id, boq_item_id)
        REFERENCES public.boq_items (company_id, id) ON DELETE CASCADE,
    CONSTRAINT uq_boq_item_versions UNIQUE (company_id, boq_item_id, revision_no)
);
CREATE INDEX idx_boq_item_versions_item ON public.boq_item_versions (company_id, boq_item_id, valid_from DESC);

-- -------------------------------------------------------------------------------------
-- 6. BOQ revisions (header-level) — post-approval changes to the baseline
-- -------------------------------------------------------------------------------------
CREATE TABLE public.boq_revisions (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL,
    boq_id            uuid NOT NULL,
    revision_no       integer NOT NULL,
    reason            text NOT NULL,
    effective_date    date NOT NULL,
    source_type       text NOT NULL CHECK (source_type IN ('remeasurement','variation_order','correction','client_instruction')),
    source_id         uuid,
    delta_amount      numeric(20,2) NOT NULL,
    approved_by       uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    approved_at       timestamptz NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_boq_revisions_boq FOREIGN KEY (company_id, boq_id)
        REFERENCES public.boqs (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT uq_boq_revisions UNIQUE (company_id, boq_id, revision_no)
);
COMMENT ON TABLE public.boq_revisions IS
    'An approved BOQ is never edited in place. Post-approval change = new revision row + boq_item_versions entries (+ contract_value_ledger entry when it changes value).';

-- -------------------------------------------------------------------------------------
-- 7. Triggers binding the immutability rules
-- -------------------------------------------------------------------------------------
CREATE TRIGGER trg_contracts_tenant_guard
    BEFORE INSERT OR UPDATE ON public.contracts
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_cvl_tenant_guard
    BEFORE INSERT OR UPDATE ON public.contract_value_ledger
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_boqs_tenant_guard
    BEFORE INSERT OR UPDATE ON public.boqs
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_boq_sections_tenant_guard
    BEFORE INSERT OR UPDATE ON public.boq_sections
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_boq_sections_no_cycle
    BEFORE INSERT OR UPDATE OF parent_section_id ON public.boq_sections
    FOR EACH ROW EXECUTE FUNCTION app.forbid_tree_cycle('parent_section_id');

CREATE TRIGGER trg_boq_items_tenant_guard
    BEFORE INSERT OR UPDATE ON public.boq_items
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_boq_items_no_cycle
    BEFORE INSERT OR UPDATE OF parent_item_id ON public.boq_items
    FOR EACH ROW EXECUTE FUNCTION app.forbid_tree_cycle('parent_item_id');

-- BOQ items may only be changed while the BOQ is draft; afterwards only through the
-- revision path (which writes boq_item_versions and, if value changes, the ledger).
CREATE OR REPLACE FUNCTION app.enforce_boq_item_editability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM public.boqs
     WHERE company_id = coalesce(NEW.company_id, OLD.company_id)
       AND id = coalesce(NEW.boq_id, OLD.boq_id);

    IF v_status IS NULL THEN
        RETURN coalesce(NEW, OLD);   -- missing parent: let the FK constraint report it
    END IF;

    IF v_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'BOQ_LOCKED: items of a % BOQ cannot be modified directly; create a revision', v_status
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_boq_items_editable_only_in_draft
    BEFORE INSERT OR UPDATE OR DELETE ON public.boq_items
    FOR EACH ROW EXECUTE FUNCTION app.enforce_boq_item_editability();

-- Contract value ledger is append-only: no UPDATE, no DELETE through the application role.
-- NOTE: no arguments are passed, so EVERY column is protected. Passing the full column list
-- would have made the guard vacuous (nothing left to compare).
CREATE TRIGGER trg_cvl_immutable
    BEFORE UPDATE OR DELETE ON public.contract_value_ledger
    FOR EACH ROW EXECUTE FUNCTION app.enforce_immutable_row();
