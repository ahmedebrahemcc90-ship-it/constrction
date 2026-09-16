-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 08 of 13
-- Project expenses (actual cost) and collections (cash), with commitments schema-ready
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Expenses — incurred cost
--    COST SPACE: never revenue. Posted rows are immutable (corrections = reversal + new row).
-- -------------------------------------------------------------------------------------
CREATE TABLE public.expenses (
    id                  uuid PRIMARY KEY,
    company_id          uuid NOT NULL,
    project_id          uuid NOT NULL,
    expense_number      text NOT NULL,
    expense_date        date NOT NULL,
    posting_date        date,                     -- drives the accounting period (may differ from expense_date)
    category            text NOT NULL CHECK (category IN (
                            'materials','labour','plant_equipment','subcontractor','transport',
                            'overhead','utilities','permits_fees','fuel','consumables','other'
                        )),
    description         text NOT NULL,
    -- Cost classification: cost code is mandatory; WBS and BOQ link are optional analysis axes.
    cost_code_id        uuid NOT NULL,
    wbs_node_id         uuid,
    boq_item_id         uuid,

    -- Party: at most one of supplier / subcontractor (payroll is out of V1 scope)
    supplier_id         uuid,
    subcontractor_id    uuid,
    payee_name_manual   text,                     -- for cash purchases with no party master

    -- Amounts: exact decimals; VAT identity enforced by CHECK
    currency_code       char(3) NOT NULL DEFAULT 'SAR' REFERENCES public.currencies(code),
    quantity            numeric(18,6) CHECK (quantity IS NULL OR quantity > 0),
    unit_id             uuid REFERENCES public.units_of_measure(id) ON DELETE RESTRICT,
    unit_cost           numeric(18,4) CHECK (unit_cost IS NULL OR unit_cost >= 0),
    net_amount          numeric(20,2) NOT NULL CHECK (net_amount >= 0),
    vat_rate_bp         integer NOT NULL DEFAULT 1500 CHECK (vat_rate_bp BETWEEN 0 AND 10000),
    vat_amount          numeric(20,2) NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
    gross_amount        numeric(20,2)
                            GENERATED ALWAYS AS (net_amount + vat_amount) STORED,
    withholding_amount  numeric(20,2) NOT NULL DEFAULT 0 CHECK (withholding_amount >= 0),
    paid_amount         numeric(20,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),

    -- External references and controls
    supplier_invoice_no text,
    supplier_invoice_date date,
    payment_method      text CHECK (payment_method IN ('cash','bank_transfer','cheque','credit_card','petty_cash')),
    payment_status      text NOT NULL DEFAULT 'unpaid'
                            CHECK (payment_status IN ('unpaid','partially_paid','paid','cancelled')),
    is_rechargeable     boolean NOT NULL DEFAULT false,   -- recoverable from client / others
    recovery_status     text NOT NULL DEFAULT 'not_applicable'
                            CHECK (recovery_status IN ('not_applicable','pending','partially_recovered','recovered','written_off')),

    -- Lifecycle: draft -> submitted -> approved -> posted -> (paid | reversed)
    status              text NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft','submitted','approved','posted','paid','rejected','reversed','cancelled')),
    submitted_by        uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    submitted_at        timestamptz,
    approved_by         uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    approved_at         timestamptz,
    posted_by           uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    posted_at           timestamptz,
    rejected_by         uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    rejected_at         timestamptz,
    rejection_reason    text,
    reversed_by         uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    reversed_at         timestamptz,
    reversal_reason     text,
    reverses_expense_id uuid,

    notes               text,
    version             integer NOT NULL DEFAULT 1,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_by          uuid,
    deleted_at          timestamptz,

    CONSTRAINT uq_expenses_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_expenses_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT fk_expenses_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_expenses_cost_code FOREIGN KEY (company_id, cost_code_id)
        REFERENCES public.cost_codes (company_id, id) ON DELETE RESTRICT,
    -- project-scoped: a WBS node or BOQ item from another project is structurally impossible
    CONSTRAINT fk_expenses_wbs FOREIGN KEY (company_id, project_id, wbs_node_id)
        REFERENCES public.wbs_nodes (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_expenses_boq_item FOREIGN KEY (company_id, project_id, boq_item_id)
        REFERENCES public.boq_items (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_expenses_supplier FOREIGN KEY (company_id, supplier_id)
        REFERENCES public.suppliers (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_expenses_subcontractor FOREIGN KEY (company_id, subcontractor_id)
        REFERENCES public.subcontractors (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_expenses_reverses FOREIGN KEY (company_id, id)
        REFERENCES public.expenses (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_expenses_one_payee CHECK (num_nonnulls(supplier_id, subcontractor_id, payee_name_manual) <= 1),
    CONSTRAINT ck_expenses_vat_identity CHECK (vat_amount = round(net_amount * vat_rate_bp / 10000.0, 2)),
    CONSTRAINT ck_expenses_paid_le_gross CHECK (paid_amount <= gross_amount),
    CONSTRAINT ck_expenses_posted_evidence CHECK (
        status NOT IN ('posted','paid') OR (posted_by IS NOT NULL AND posted_at IS NOT NULL)
    ),
    CONSTRAINT ck_expenses_approved_evidence CHECK (
        status NOT IN ('approved','posted','paid') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)
    ),
    CONSTRAINT ck_expenses_reversal_coherent CHECK (
        status <> 'reversed' OR (reversed_at IS NOT NULL AND reversal_reason IS NOT NULL)
    )
);
CREATE UNIQUE INDEX uq_expenses_company_number ON public.expenses (company_id, expense_number) WHERE deleted_at IS NULL;
CREATE INDEX idx_expenses_project_date ON public.expenses (company_id, project_id, expense_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_expenses_cost_code    ON public.expenses (company_id, cost_code_id, posting_date);
CREATE INDEX idx_expenses_open         ON public.expenses (company_id, project_id)
    WHERE status IN ('submitted','approved') AND deleted_at IS NULL;
COMMENT ON TABLE public.expenses IS
    'Actual cost. Feeds the "Actual Cost" concept; never mixed with budget (intent) or committed (legal obligation). See docs I §3.';

-- Optional split of an expense across cost codes / WBS nodes (one row = the simple case).
CREATE TABLE public.expense_allocations (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL,
    project_id    uuid NOT NULL,
    expense_id    uuid NOT NULL,
    cost_code_id  uuid NOT NULL,
    wbs_node_id   uuid,
    boq_item_id   uuid,
    allocation_pct numeric(9,4) CHECK (allocation_pct > 0 AND allocation_pct <= 100),
    amount        numeric(20,2) NOT NULL CHECK (amount >= 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    CONSTRAINT uq_expense_allocations_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_expense_allocations_expense FOREIGN KEY (company_id, project_id, expense_id)
        REFERENCES public.expenses (company_id, project_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_expense_allocations_cost_code FOREIGN KEY (company_id, cost_code_id)
        REFERENCES public.cost_codes (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_allocations_wbs FOREIGN KEY (company_id, project_id, wbs_node_id)
        REFERENCES public.wbs_nodes (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_allocations_boq_item FOREIGN KEY (company_id, project_id, boq_item_id)
        REFERENCES public.boq_items (company_id, project_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_expense_allocations_expense ON public.expense_allocations (company_id, expense_id);

CREATE TABLE public.expense_status_history (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL,
    expense_id    uuid NOT NULL,
    from_status   text,
    to_status     text NOT NULL,
    actor_user_id uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    changed_at    timestamptz NOT NULL DEFAULT now(),
    comment       text,
    request_id    text,
    CONSTRAINT fk_expense_status_history FOREIGN KEY (company_id, expense_id)
        REFERENCES public.expenses (company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_expense_status_history ON public.expense_status_history (company_id, expense_id, changed_at);

-- -------------------------------------------------------------------------------------
-- 2. Cost commitments — SCHEMA ONLY in V1 (procurement is out of scope)
--    Present so the "Committed Cost" concept has a home and so V1 dashboards can read 0,
--    rather than a future migration having to rewrite the cost model.
-- -------------------------------------------------------------------------------------
CREATE TABLE public.cost_commitments (
    id               uuid PRIMARY KEY,
    company_id       uuid NOT NULL,
    project_id       uuid NOT NULL,
    cost_code_id     uuid NOT NULL,
    wbs_node_id      uuid,
    commitment_type  text NOT NULL CHECK (commitment_type IN ('purchase_order','subcontract','letter_of_intent','other')),
    reference        text,
    supplier_id      uuid,
    subcontractor_id uuid,
    committed_amount numeric(20,2) NOT NULL CHECK (committed_amount >= 0),
    consumed_amount  numeric(20,2) NOT NULL DEFAULT 0 CHECK (consumed_amount >= 0),
    commitment_date  date NOT NULL,
    status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','partially_consumed','closed','cancelled')),
    source_module    text NOT NULL DEFAULT 'external' CHECK (source_module IN ('v2_procurement','external','manual')),
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT uq_cost_commitments_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_cost_commitments_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_cost_commitments_cost_code FOREIGN KEY (company_id, cost_code_id)
        REFERENCES public.cost_codes (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_cost_commitments_wbs FOREIGN KEY (company_id, project_id, wbs_node_id)
        REFERENCES public.wbs_nodes (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_cost_commitments_consumed CHECK (consumed_amount <= committed_amount)
);
CREATE INDEX idx_cost_commitments_project ON public.cost_commitments (company_id, project_id, status);
COMMENT ON TABLE public.cost_commitments IS
    'V1 writes nothing here (procurement is out of scope). Dashboards read committed cost from this table, so V1 shows genuine 0 rather than an unknown.';

-- -------------------------------------------------------------------------------------
-- 3. Collections — cash received and its allocation
-- -------------------------------------------------------------------------------------
CREATE TABLE public.collections (
    id                  uuid PRIMARY KEY,
    company_id          uuid NOT NULL,
    project_id          uuid NOT NULL,
    contract_id         uuid NOT NULL,
    client_id           uuid NOT NULL,
    collection_number   text NOT NULL,
    receipt_date        date NOT NULL,
    value_date          date,                     -- bank value date
    currency_code       char(3) NOT NULL DEFAULT 'SAR' REFERENCES public.currencies(code),
    amount              numeric(20,2) NOT NULL CHECK (amount > 0),
    allocated_amount    numeric(20,2) NOT NULL DEFAULT 0 CHECK (allocated_amount >= 0),
    unallocated_amount  numeric(20,2)
                            GENERATED ALWAYS AS (amount - allocated_amount) STORED,
    payment_method      text NOT NULL DEFAULT 'bank_transfer'
                            CHECK (payment_method IN ('bank_transfer','cheque','cash','letter_of_credit','other')),
    bank_reference      text,
    cheque_number       text,
    is_advance_receipt  boolean NOT NULL DEFAULT false,   -- mobilisation advance, not yet earned
    status              text NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft','posted','reconciled','reversed','cancelled')),
    posted_by           uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    posted_at           timestamptz,
    reversed_by         uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    reversed_at         timestamptz,
    reversal_reason     text,
    reverses_collection_id uuid,
    notes               text,
    version             integer NOT NULL DEFAULT 1,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_by          uuid,
    deleted_at          timestamptz,
    CONSTRAINT uq_collections_company_id_id UNIQUE (company_id, id),
    -- project-scoped parent key: allocations reference (company_id, project_id, id)
    CONSTRAINT uq_collections_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT fk_collections_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_collections_contract FOREIGN KEY (company_id, project_id, contract_id)
        REFERENCES public.contracts (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_collections_client FOREIGN KEY (company_id, client_id)
        REFERENCES public.clients (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_collections_reverses FOREIGN KEY (company_id, id)
        REFERENCES public.collections (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_collections_allocated_le_amount CHECK (allocated_amount <= amount),
    CONSTRAINT ck_collections_posted_evidence CHECK (status <> 'posted' OR (posted_by IS NOT NULL AND posted_at IS NOT NULL))
);
CREATE UNIQUE INDEX uq_collections_company_number ON public.collections (company_id, collection_number) WHERE deleted_at IS NULL;
-- A bank reference may only be posted once: prevents double-keying the same receipt.
CREATE UNIQUE INDEX uq_collections_bank_reference
    ON public.collections (company_id, bank_reference)
    WHERE bank_reference IS NOT NULL AND status <> 'cancelled';
CREATE INDEX idx_collections_project ON public.collections (company_id, project_id, receipt_date DESC);
CREATE INDEX idx_collections_client  ON public.collections (company_id, client_id, receipt_date DESC);

CREATE TABLE public.collection_allocations (
    id             uuid PRIMARY KEY,
    company_id     uuid NOT NULL,
    project_id     uuid NOT NULL,
    collection_id  uuid NOT NULL,
    ipc_id         uuid,                          -- NULL = unapplied / on-account / advance
    allocation_type text NOT NULL DEFAULT 'ipc_settlement'
                       CHECK (allocation_type IN ('ipc_settlement','advance','retention_release','on_account','other')),
    amount         numeric(20,2) NOT NULL CHECK (amount > 0),
    allocated_at   timestamptz NOT NULL DEFAULT now(),
    allocated_by   uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_collection_allocations_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_collection_allocations_collection FOREIGN KEY (company_id, project_id, collection_id)
        REFERENCES public.collections (company_id, project_id, id) ON DELETE CASCADE,
    -- project-scoped: a collection can never settle another project's certificate
    CONSTRAINT fk_collection_allocations_ipc FOREIGN KEY (company_id, project_id, ipc_id)
        REFERENCES public.ipcs (company_id, project_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_collection_allocations_collection ON public.collection_allocations (company_id, collection_id);
CREATE INDEX idx_collection_allocations_ipc        ON public.collection_allocations (company_id, ipc_id) WHERE ipc_id IS NOT NULL;

-- -------------------------------------------------------------------------------------
-- 4. Aggregates maintained by the database
--    Collections must never modify a certificate's earned amounts (INV-33): the only header
--    columns they touch are amount_received / outstanding_amount.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.recalculate_collection_state()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_company uuid := coalesce(NEW.company_id, OLD.company_id);
    v_collection uuid := coalesce(NEW.collection_id, OLD.collection_id);
    v_ipc uuid := coalesce(NEW.ipc_id, OLD.ipc_id);
    v_allocated numeric(20,2);
BEGIN
    -- 4.1 keep collections.allocated_amount in step with its allocations
    SELECT coalesce(sum(a.amount), 0) INTO v_allocated
      FROM public.collection_allocations a
     WHERE a.company_id = v_company AND a.collection_id = v_collection;

    UPDATE public.collections
       SET allocated_amount = v_allocated, updated_at = now()
     WHERE company_id = v_company AND id = v_collection;

    -- 4.2 keep the certificate's received/outstanding figures in step
    IF v_ipc IS NOT NULL THEN
        SELECT coalesce(sum(a.amount), 0) INTO v_allocated
          FROM public.collection_allocations a
          JOIN public.collections c
            ON c.company_id = a.company_id AND c.id = a.collection_id AND c.status IN ('posted','reconciled')
         WHERE a.company_id = v_company AND a.ipc_id = v_ipc;

        UPDATE public.ipcs i
           SET amount_received = least(v_allocated, i.total_payable_incl_vat),
               outstanding_amount = i.total_payable_incl_vat - least(v_allocated, i.total_payable_incl_vat),
               updated_at = now()
         WHERE i.company_id = v_company AND i.id = v_ipc;
    END IF;

    RETURN NULL;   -- AFTER trigger
END;
$$;

CREATE OR REPLACE FUNCTION app.enforce_collection_allocation_limits()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_amount numeric(20,2);
    v_already numeric(20,2);
    v_payable numeric(20,2);
BEGIN
    SELECT amount INTO v_amount FROM public.collections
     WHERE company_id = NEW.company_id AND id = NEW.collection_id FOR UPDATE;

    SELECT coalesce(sum(a.amount), 0) INTO v_already
      FROM public.collection_allocations a
     WHERE a.company_id = NEW.company_id AND a.collection_id = NEW.collection_id
       AND a.id <> coalesce(NEW.id, gen_random_uuid());

    IF v_already + NEW.amount > v_amount THEN
        RAISE EXCEPTION 'ALLOCATION_EXCEEDS_COLLECTION: % already allocated, % + % > receipt %',
            v_already, v_already, NEW.amount, v_amount USING ERRCODE = '23514';
    END IF;

    IF NEW.ipc_id IS NOT NULL THEN
        SELECT total_payable_incl_vat INTO v_payable FROM public.ipcs
         WHERE company_id = NEW.company_id AND id = NEW.ipc_id FOR UPDATE;
        IF v_payable IS NOT NULL AND NEW.amount > v_payable THEN
            RAISE EXCEPTION 'ALLOCATION_EXCEEDS_CERTIFICATE: % > certificate %', NEW.amount, v_payable
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- -------------------------------------------------------------------------------------
-- 5. Triggers
--    (helper functions are defined before the triggers that bind them)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.enforce_expense_allocation_editability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM public.expenses
     WHERE company_id = coalesce(NEW.company_id, OLD.company_id)
       AND id = coalesce(NEW.expense_id, OLD.expense_id);

    IF v_status IS NULL THEN
        RETURN coalesce(NEW, OLD);
    END IF;
    IF v_status <> 'draft' THEN
        RAISE EXCEPTION 'EXPENSE_FROZEN: allocations of a % expense cannot be modified', v_status
            USING ERRCODE = '42501';
    END IF;
    RETURN coalesce(NEW, OLD);
END;
$$;


CREATE TRIGGER trg_expense_allocations_editable_in_draft
    BEFORE INSERT OR UPDATE OR DELETE ON public.expense_allocations
    FOR EACH ROW EXECUTE FUNCTION app.enforce_expense_allocation_editability();

CREATE TRIGGER trg_expenses_tenant_guard
    BEFORE INSERT OR UPDATE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_collections_tenant_guard
    BEFORE INSERT OR UPDATE ON public.collections
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

-- Posted expenses are frozen: correct by reversal, never by editing.
CREATE OR REPLACE FUNCTION app.enforce_expense_freeze()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'draft' THEN
        RETURN NEW;         -- drafts are freely editable
    END IF;

    IF (NEW.project_id, NEW.expense_date, NEW.category, NEW.description, NEW.cost_code_id,
        NEW.wbs_node_id, NEW.boq_item_id, NEW.supplier_id, NEW.subcontractor_id, NEW.payee_name_manual,
        NEW.net_amount, NEW.vat_rate_bp, NEW.vat_amount, NEW.currency_code, NEW.quantity,
        NEW.unit_id, NEW.unit_cost, NEW.supplier_invoice_no, NEW.is_rechargeable)
       IS DISTINCT FROM
       (OLD.project_id, OLD.expense_date, OLD.category, OLD.description, OLD.cost_code_id,
        OLD.wbs_node_id, OLD.boq_item_id, OLD.supplier_id, OLD.subcontractor_id, OLD.payee_name_manual,
        OLD.net_amount, OLD.vat_rate_bp, OLD.vat_amount, OLD.currency_code, OLD.quantity,
        OLD.unit_id, OLD.unit_cost, OLD.supplier_invoice_no, OLD.is_rechargeable)
    THEN
        RAISE EXCEPTION 'EXPENSE_FROZEN: a % expense cannot be edited; reverse and re-record', OLD.status
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_expenses_freeze_after_draft
    BEFORE UPDATE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION app.enforce_expense_freeze();

CREATE TRIGGER trg_expenses_no_delete
    BEFORE DELETE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION app.enforce_no_delete();


CREATE TRIGGER trg_collection_allocations_limits
    BEFORE INSERT OR UPDATE ON public.collection_allocations
    FOR EACH ROW EXECUTE FUNCTION app.enforce_collection_allocation_limits();

CREATE TRIGGER trg_collection_allocations_recalculate
    AFTER INSERT OR UPDATE OR DELETE ON public.collection_allocations
    FOR EACH ROW EXECUTE FUNCTION app.recalculate_collection_state();

-- Receipts are frozen once posted; reversal is the only correction path.
CREATE OR REPLACE FUNCTION app.enforce_collection_freeze()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IN ('posted','reconciled') THEN
        IF (NEW.project_id, NEW.contract_id, NEW.client_id, NEW.receipt_date, NEW.amount,
            NEW.currency_code, NEW.payment_method, NEW.bank_reference, NEW.cheque_number,
            NEW.is_advance_receipt)
           IS DISTINCT FROM
           (OLD.project_id, OLD.contract_id, OLD.client_id, OLD.receipt_date, OLD.amount,
            OLD.currency_code, OLD.payment_method, OLD.bank_reference, OLD.cheque_number,
            OLD.is_advance_receipt)
        THEN
            RAISE EXCEPTION 'COLLECTION_FROZEN: a % receipt cannot be edited; post a reversal', OLD.status
                USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_collections_freeze_after_post
    BEFORE UPDATE ON public.collections
    FOR EACH ROW EXECUTE FUNCTION app.enforce_collection_freeze();

CREATE TRIGGER trg_collections_no_delete
    BEFORE DELETE ON public.collections
    FOR EACH ROW EXECUTE FUNCTION app.enforce_no_delete();
