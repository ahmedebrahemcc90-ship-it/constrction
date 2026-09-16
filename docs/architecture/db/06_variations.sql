-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 06 of 13
-- Variation orders (additions/omissions). Only APPROVED VOs may change contract value.
-- =====================================================================================

CREATE TABLE public.variation_orders (
    id                    uuid PRIMARY KEY,
    company_id            uuid NOT NULL,
    project_id            uuid NOT NULL,
    contract_id           uuid NOT NULL,
    vo_number             text NOT NULL,
    client_reference      text,                       -- the client's own VO/instruction number
    title_en              text NOT NULL,
    title_ar              text NOT NULL,
    description           text,
    vo_category           text NOT NULL DEFAULT 'scope_change' CHECK (vo_category IN (
                              'scope_change','client_instruction','design_change','unforeseen_condition',
                              'rate_change','quantity_change','provisional_sum','omit_work'
                          )),
    instruction_source    text NOT NULL DEFAULT 'client' CHECK (instruction_source IN ('client','consultant','engineer','internal')),
    instruction_reference text,
    instruction_date      date,
    -- Amounts are derived from lines by trigger; never accepted from the client (INV-51).
    addition_amount       numeric(20,2) NOT NULL DEFAULT 0 CHECK (addition_amount >= 0),
    omission_amount       numeric(20,2) NOT NULL DEFAULT 0 CHECK (omission_amount >= 0),
    net_amount            numeric(20,2) GENERATED ALWAYS AS (addition_amount - omission_amount) STORED,
    currency_code         char(3) NOT NULL DEFAULT 'SAR' REFERENCES public.currencies(code),
    vat_rate_bp           integer NOT NULL DEFAULT 1500 CHECK (vat_rate_bp BETWEEN 0 AND 10000),
    is_time_impacting     boolean NOT NULL DEFAULT false,
    time_impact_days      integer CHECK (time_impact_days IS NULL OR time_impact_days >= 0),

    -- Lifecycle. Only 'approved' may affect contract value.
    status                text NOT NULL DEFAULT 'draft' CHECK (status IN (
                              'draft','submitted','under_review','approved','rejected','cancelled','superseded'
                          )),
    submitted_by          uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    submitted_at          timestamptz,
    approved_by           uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    approved_at           timestamptz,
    rejected_by           uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    rejected_at           timestamptz,
    rejection_reason      text,
    cancelled_by          uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    cancelled_at          timestamptz,
    superseded_by_vo_id   uuid,

    -- Contract-value posting evidence (idempotent, exactly once per approved VO)
    affects_contract_value boolean NOT NULL DEFAULT true,
    value_posted_at        timestamptz,
    ledger_entry_id        uuid,
    evidence_document_id   uuid,                      -- approval / instruction document

    version               integer NOT NULL DEFAULT 1,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid,
    updated_by            uuid,
    deleted_at            timestamptz,

    CONSTRAINT uq_vo_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_vo_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT fk_vo_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_vo_contract FOREIGN KEY (company_id, project_id, contract_id)
        REFERENCES public.contracts (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_vo_superseded_by FOREIGN KEY (company_id, id) REFERENCES public.variation_orders (company_id, id) ON DELETE RESTRICT,
    -- Approval evidence is mandatory and immutable once approved.
    CONSTRAINT ck_vo_approved_evidence CHECK (
        status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND value_posted_at IS NOT NULL)
    ),
    CONSTRAINT ck_vo_rejected_evidence CHECK (
        status <> 'rejected' OR (rejection_reason IS NOT NULL AND rejected_at IS NOT NULL AND rejected_by IS NOT NULL)
    ),
    CONSTRAINT ck_vo_no_self_supersede CHECK (superseded_by_vo_id IS NULL OR superseded_by_vo_id <> id)
);
CREATE UNIQUE INDEX uq_vo_company_number ON public.variation_orders (company_id, vo_number) WHERE deleted_at IS NULL;
CREATE INDEX idx_vo_project_status ON public.variation_orders (company_id, project_id, status, created_at DESC);
CREATE INDEX idx_vo_contract_approved ON public.variation_orders (company_id, contract_id) WHERE status = 'approved';
-- One VO per contract may carry a given client reference: prevents double-counting the same instruction.
CREATE UNIQUE INDEX uq_vo_client_reference ON public.variation_orders (company_id, contract_id, client_reference)
    WHERE client_reference IS NOT NULL AND status <> 'cancelled';

-- -------------------------------------------------------------------------------------
-- Lines
-- -------------------------------------------------------------------------------------
CREATE TABLE public.variation_order_lines (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL,
    project_id        uuid NOT NULL,
    variation_order_id uuid NOT NULL,
    line_no           integer NOT NULL CHECK (line_no > 0),
    line_type         text NOT NULL CHECK (line_type IN (
                          'new_item','quantity_change','rate_change','omission','lump_sum','provisional_allowance'
                      )),
    boq_item_id       uuid,                        -- NULL for genuinely new items
    item_code         text,                        -- new/modified item code (unique inside the VO)
    description_en    text NOT NULL,
    description_ar    text,
    unit_id           uuid,
    quantity_delta    numeric(18,6) NOT NULL,      -- signed: negative = omission
    unit_rate         numeric(18,4) NOT NULL CHECK (unit_rate >= 0),
    -- Signed amount, computed by the database and consistent with the sign of quantity_delta.
    amount            numeric(20,2) GENERATED ALWAYS AS (round(quantity_delta * unit_rate, 2)) STORED,
    is_omission       boolean NOT NULL DEFAULT false,
    notes             text,
    sort_order        integer NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid,
    CONSTRAINT uq_vo_lines_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_vo_lines_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT uq_vo_lines_no UNIQUE (company_id, variation_order_id, line_no),
    CONSTRAINT fk_vo_lines_vo FOREIGN KEY (company_id, project_id, variation_order_id)
        REFERENCES public.variation_orders (company_id, project_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_vo_lines_boq_item FOREIGN KEY (company_id, project_id, boq_item_id)
        REFERENCES public.boq_items (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_vo_lines_sign_coherent CHECK (
        (is_omission AND quantity_delta <= 0) OR (NOT is_omission AND quantity_delta >= 0)
    ),
    CONSTRAINT ck_vo_lines_omission_amount CHECK (NOT is_omission OR amount <= 0)
    ,
    CONSTRAINT fk_vo_lines_unit FOREIGN KEY (unit_id)
        REFERENCES public.units_of_measure(id) ON DELETE RESTRICT
);
CREATE INDEX idx_vo_lines_vo ON public.variation_order_lines (company_id, variation_order_id, line_no);
CREATE INDEX idx_vo_lines_item ON public.variation_order_lines (company_id, boq_item_id) WHERE boq_item_id IS NOT NULL;
COMMENT ON COLUMN public.variation_order_lines.amount IS
    'Generated from signed quantity_delta x unit_rate. A client-supplied amount is never stored (INV-51).';

-- -------------------------------------------------------------------------------------
-- Approval evidence (immutable)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.variation_order_approvals (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL,
    variation_order_id uuid NOT NULL,
    approval_request_id uuid,                      -- link to the generic approval engine (file 09)
    step_no            integer NOT NULL CHECK (step_no > 0),
    decision           text NOT NULL CHECK (decision IN ('approved','rejected','returned','delegated','abstained')),
    decided_by         uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    decided_by_role_id uuid,
    decided_at         timestamptz NOT NULL DEFAULT now(),
    comment            text,
    ip_address         inet,
    request_id         text,                       -- correlation id
    document_version_no integer,                   -- which version of the VO was approved
    CONSTRAINT fk_vo_approvals_vo FOREIGN KEY (company_id, variation_order_id)
        REFERENCES public.variation_orders (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT uq_vo_approvals_step UNIQUE (company_id, variation_order_id, step_no, decided_by)
);

-- -------------------------------------------------------------------------------------
-- Contract-value posting function
--   Called INSIDE the approval transaction (same transaction as the status change).
--   Idempotent: the unique index uq_cvl_source_once guarantees a VO can never be posted twice.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.post_vo_to_contract_value(
    p_company_id uuid,
    p_vo_id      uuid,
    p_actor      uuid
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_vo        record;
    v_entry_id  uuid;
BEGIN
    SELECT * INTO v_vo
      FROM public.variation_orders
     WHERE company_id = p_company_id AND id = p_vo_id
     FOR UPDATE;                                  -- serialises concurrent approvals

    IF NOT FOUND THEN
        RAISE EXCEPTION 'VO_NOT_FOUND' USING ERRCODE = '42501';
    END IF;

    IF v_vo.status <> 'approved' THEN
        RAISE EXCEPTION 'VO_NOT_APPROVED: status=% cannot affect contract value', v_vo.status
            USING ERRCODE = '23514';
    END IF;

    IF v_vo.ledger_entry_id IS NOT NULL THEN
        RETURN v_vo.ledger_entry_id;              -- already posted: no-op, never double count
    END IF;

    IF NOT v_vo.affects_contract_value THEN
        RETURN NULL;                              -- e.g. time-extension only / pure re-measurement
    END IF;

    INSERT INTO public.contract_value_ledger (
        id, company_id, contract_id, entry_type, amount_delta, effective_date,
        source_type, source_id, source_reference, reason, evidence_document_id,
        approved_by, approved_at, created_by
    ) VALUES (
        gen_random_uuid(), p_company_id, v_vo.contract_id,
        CASE WHEN v_vo.net_amount < 0 THEN 'omission_approved' ELSE 'variation_approved' END,
        v_vo.net_amount,
        coalesce(v_vo.instruction_date, current_date),
        'variation_order', v_vo.id, v_vo.vo_number,
        'Approved variation order ' || v_vo.vo_number,
        v_vo.evidence_document_id, v_vo.approved_by, v_vo.approved_at, p_actor
    )
    RETURNING id INTO v_entry_id;

    UPDATE public.variation_orders
       SET value_posted_at = now(), ledger_entry_id = v_entry_id
     WHERE company_id = p_company_id AND id = p_vo_id;

    -- Refresh the cached contract value from the ledger (authoritative source).
    UPDATE public.contracts c
       SET current_value = (
              SELECT coalesce(sum(l.amount_delta), 0)
                FROM public.contract_value_ledger l
               WHERE l.company_id = c.company_id AND l.contract_id = c.id
           ),
           value_last_reconciled_at = now(),
           updated_at = now()
     WHERE c.company_id = p_company_id AND c.id = v_vo.contract_id;

    RETURN v_entry_id;
END;
$$;

-- -------------------------------------------------------------------------------------
-- Header totals are DERIVED from lines by the database (client totals are never trusted)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.recalculate_vo_totals()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_vo_id   uuid := coalesce(NEW.variation_order_id, OLD.variation_order_id);
    v_company uuid := coalesce(NEW.company_id, OLD.company_id);
    v_add     numeric(20,2);
    v_omit    numeric(20,2);
BEGIN
    SELECT coalesce(sum(l.amount) FILTER (WHERE NOT l.is_omission), 0),
           coalesce(abs(sum(l.amount) FILTER (WHERE l.is_omission)), 0)
      INTO v_add, v_omit
      FROM public.variation_order_lines l
     WHERE l.company_id = v_company AND l.variation_order_id = v_vo_id;

    UPDATE public.variation_orders
       SET addition_amount = v_add, omission_amount = v_omit, updated_at = now()
     WHERE company_id = v_company AND id = v_vo_id AND deleted_at IS NULL;

    RETURN NULL;   -- AFTER trigger
END;
$$;

-- -------------------------------------------------------------------------------------
-- Freeze function: after a decision, only lifecycle columns may still change.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.enforce_vo_freeze()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'draft' THEN
        RETURN NEW;      -- a draft VO (and its totals) may still change
    END IF;

    -- Commercial identity of the VO: immutable once it leaves draft.
    IF (NEW.vo_number, NEW.project_id, NEW.contract_id, NEW.vo_category,
        NEW.addition_amount, NEW.omission_amount, NEW.currency_code, NEW.vat_rate_bp,
        NEW.affects_contract_value, NEW.instruction_source, NEW.instruction_reference,
        NEW.instruction_date, NEW.description, NEW.title_en, NEW.title_ar,
        NEW.is_time_impacting, NEW.time_impact_days, NEW.client_reference)
       IS DISTINCT FROM
       (OLD.vo_number, OLD.project_id, OLD.contract_id, OLD.vo_category,
        OLD.addition_amount, OLD.omission_amount, OLD.currency_code, OLD.vat_rate_bp,
        OLD.affects_contract_value, OLD.instruction_source, OLD.instruction_reference,
        OLD.instruction_date, OLD.description, OLD.title_en, OLD.title_ar,
        OLD.is_time_impacting, OLD.time_impact_days, OLD.client_reference)
    THEN
        RAISE EXCEPTION 'VO_FROZEN: a % variation order cannot be modified; supersede it instead', OLD.status
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$;

-- -------------------------------------------------------------------------------------
-- Triggers
-- -------------------------------------------------------------------------------------
CREATE TRIGGER trg_vo_tenant_guard
    BEFORE INSERT OR UPDATE ON public.variation_orders
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_vo_lines_tenant_guard
    BEFORE INSERT OR UPDATE ON public.variation_order_lines
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

-- Keep the header totals equal to the sum of the lines, whatever the client sends.
CREATE TRIGGER trg_vo_lines_recalculate_totals
    AFTER INSERT OR UPDATE OR DELETE ON public.variation_order_lines
    FOR EACH ROW EXECUTE FUNCTION app.recalculate_vo_totals();

-- After submission a VO is frozen except for lifecycle columns.
CREATE TRIGGER trg_vo_freeze_after_draft
    BEFORE UPDATE ON public.variation_orders
    FOR EACH ROW EXECUTE FUNCTION app.enforce_vo_freeze();

-- Deletion of a variation order is never allowed through the application role.
CREATE TRIGGER trg_vo_no_delete
    BEFORE DELETE ON public.variation_orders
    FOR EACH ROW EXECUTE FUNCTION app.enforce_no_delete();

-- VO lines are editable only while the VO is draft; after submission they are frozen and a
-- correction requires returning the VO to draft by an authorised approver (audited transition).
CREATE OR REPLACE FUNCTION app.enforce_vo_line_editability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status text;
    v_vo_id  uuid := coalesce(NEW.variation_order_id, OLD.variation_order_id);
    v_company uuid := coalesce(NEW.company_id, OLD.company_id);
BEGIN
    SELECT status INTO v_status
      FROM public.variation_orders
     WHERE company_id = v_company AND id = v_vo_id;

    IF v_status IS NULL THEN
        RETURN coalesce(NEW, OLD);   -- missing parent: let the FK constraint report it
    END IF;

    IF v_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'VO_LOCKED: lines of a % variation order cannot be modified', v_status
            USING ERRCODE = '42501';
    END IF;
    RETURN coalesce(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_vo_lines_editable_only_in_draft
    BEFORE INSERT OR UPDATE OR DELETE ON public.variation_order_lines
    FOR EACH ROW EXECUTE FUNCTION app.enforce_vo_line_editability();
