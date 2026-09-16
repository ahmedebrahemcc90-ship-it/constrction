-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 04 of 13
-- WBS, Cost Codes, Project cost-code scoping, Budgets, Budget lines, Transfers
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. WBS — project-specific execution breakdown tree
-- -------------------------------------------------------------------------------------
CREATE TABLE public.wbs_nodes (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL,
    project_id    uuid NOT NULL,
    parent_id     uuid,
    code          text NOT NULL,                 -- e.g. '1.2.3'
    name_en       text NOT NULL,
    name_ar       text NOT NULL,
    node_type     text NOT NULL DEFAULT 'work_package'
                      CHECK (node_type IN ('phase','stage','area','work_package','sub_package')),
    level         smallint NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 12),
    path          text NOT NULL DEFAULT '',      -- materialized path '/1/1.2/' for subtree queries
    sort_order    integer NOT NULL DEFAULT 0,
    planned_start date,
    planned_end   date,
    weight_pct    numeric(9,4) CHECK (weight_pct BETWEEN 0 AND 100),  -- progress weighting
    status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','closed')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_by    uuid,
    deleted_at    timestamptz,
    CONSTRAINT uq_wbs_nodes_company_id_id UNIQUE (company_id, id),
    -- project-scoped parent key (composite FK target for budget lines, expenses, ...)
    CONSTRAINT uq_wbs_nodes_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT uq_wbs_nodes_code UNIQUE (company_id, project_id, code),
    CONSTRAINT fk_wbs_nodes_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_wbs_nodes_parent FOREIGN KEY (company_id, project_id, parent_id)
        REFERENCES public.wbs_nodes (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_wbs_nodes_not_self CHECK (parent_id IS NULL OR parent_id <> id)
);
CREATE INDEX idx_wbs_nodes_tree ON public.wbs_nodes (company_id, project_id, parent_id, sort_order) WHERE deleted_at IS NULL;
CREATE INDEX idx_wbs_nodes_path ON public.wbs_nodes (company_id, path text_pattern_ops);
COMMENT ON TABLE public.wbs_nodes IS
    'Project execution breakdown. Distinct from CostCode (company-wide accounting classification) and from BOQ (priced revenue structure).';

-- -------------------------------------------------------------------------------------
-- 2. Cost codes — company-wide standard cost classification tree (CBS)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.cost_codes (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    parent_id     uuid,
    code          text NOT NULL,                 -- e.g. '01.02.003'
    name_en       text NOT NULL,
    name_ar       text NOT NULL,
    code_type     text NOT NULL DEFAULT 'cost'
                      CHECK (code_type IN ('cost','resource','overhead','labour','material','plant','subcontract')),
    level         smallint NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 12),
    path          text NOT NULL DEFAULT '',
    is_postable   boolean NOT NULL DEFAULT true,  -- only leaf-ish codes accept postings (enforced in service)
    is_system     boolean NOT NULL DEFAULT false,
    sort_order    integer NOT NULL DEFAULT 0,
    status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_by    uuid,
    deleted_at    timestamptz,
    CONSTRAINT uq_cost_codes_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_cost_codes_parent FOREIGN KEY (company_id, parent_id)
        REFERENCES public.cost_codes (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_cost_codes_not_self CHECK (parent_id IS NULL OR parent_id <> id)
);
CREATE UNIQUE INDEX uq_cost_codes_company_code ON public.cost_codes (company_id, code) WHERE deleted_at IS NULL;
CREATE INDEX idx_cost_codes_parent ON public.cost_codes (company_id, parent_id, sort_order) WHERE deleted_at IS NULL;
CREATE INDEX idx_cost_codes_path   ON public.cost_codes (company_id, path text_pattern_ops);

-- Optional project-level selection/restriction of the company cost-code tree.
CREATE TABLE public.project_cost_codes (
    company_id   uuid NOT NULL,
    project_id   uuid NOT NULL,
    cost_code_id uuid NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_id, project_id, cost_code_id),
    CONSTRAINT fk_pcc_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_pcc_cost_code FOREIGN KEY (company_id, cost_code_id)
        REFERENCES public.cost_codes (company_id, id) ON DELETE RESTRICT
);

-- -------------------------------------------------------------------------------------
-- 3. Budgets — versioned, approved spending plan (COST space, never revenue)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.budgets (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL,
    project_id        uuid NOT NULL,
    version_no        integer NOT NULL CHECK (version_no > 0),
    title_en          text NOT NULL,
    title_ar          text NOT NULL,
    budget_type       text NOT NULL DEFAULT 'original'
                          CHECK (budget_type IN ('original','revised','forecast','reallocation')),
    -- Derived cache of SUM(budget_lines.amount); authoritative value is the lines.
    total_amount      numeric(20,2) NOT NULL DEFAULT 0,
    status            text NOT NULL DEFAULT 'draft'
                          CHECK (status IN ('draft','submitted','under_review','approved','rejected','superseded','archived')),
    based_on_budget_id uuid,
    submitted_by      uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    submitted_at      timestamptz,
    approved_by       uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    approved_at       timestamptz,
    rejected_reason   text,
    effective_from    date,
    effective_to      date,
    notes             text,
    version           integer NOT NULL DEFAULT 1,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid,
    updated_by        uuid,
    deleted_at        timestamptz,
    CONSTRAINT uq_budgets_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_budgets_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT uq_budgets_project_version UNIQUE (company_id, project_id, version_no),
    CONSTRAINT fk_budgets_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_budgets_based_on FOREIGN KEY (company_id, based_on_budget_id)
        REFERENCES public.budgets (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_budgets_approved_coherent CHECK ((status = 'approved') = (approved_at IS NOT NULL)),
    CONSTRAINT ck_budgets_period CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to > effective_from)
);
-- Exactly one approved budget per project is the active plan; revisions supersede it.
CREATE UNIQUE INDEX uq_budgets_one_approved_per_project
    ON public.budgets (company_id, project_id)
    WHERE status = 'approved' AND deleted_at IS NULL;

CREATE TABLE public.budget_lines (
    id             uuid PRIMARY KEY,
    company_id     uuid NOT NULL,
    project_id     uuid NOT NULL,
    budget_id      uuid NOT NULL,
    cost_code_id   uuid NOT NULL,
    wbs_node_id    uuid,
    boq_item_id    uuid,
    description_en text,
    description_ar text,
    amount         numeric(20,2) NOT NULL CHECK (amount >= 0),
    quantity       numeric(18,6) CHECK (quantity IS NULL OR quantity >= 0),
    unit_id        uuid,
    unit_cost      numeric(18,4) CHECK (unit_cost IS NULL OR unit_cost >= 0),
    contingency_pct numeric(9,4) CHECK (contingency_pct BETWEEN 0 AND 100),
    sort_order     integer NOT NULL DEFAULT 0,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid,
    updated_by     uuid,
    deleted_at     timestamptz,
    CONSTRAINT uq_budget_lines_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_budget_lines_budget FOREIGN KEY (company_id, project_id, budget_id)
        REFERENCES public.budgets (company_id, project_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_budget_lines_cost_code FOREIGN KEY (company_id, cost_code_id)
        REFERENCES public.cost_codes (company_id, id) ON DELETE RESTRICT,
    -- project-scoped: a WBS node or BOQ item from another project is STRUCTURALLY impossible
    CONSTRAINT fk_budget_lines_wbs FOREIGN KEY (company_id, project_id, wbs_node_id)
        REFERENCES public.wbs_nodes (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_budget_lines_boq_item FOREIGN KEY (company_id, project_id, boq_item_id)
        REFERENCES public.boq_items (company_id, project_id, id) ON DELETE RESTRICT
    ,
    CONSTRAINT fk_budget_lines_unit FOREIGN KEY (unit_id)
        REFERENCES public.units_of_measure(id) ON DELETE RESTRICT
);
CREATE INDEX idx_budget_lines_budget ON public.budget_lines (company_id, budget_id, cost_code_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_budget_lines_cost   ON public.budget_lines (company_id, cost_code_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_budget_lines_wbs    ON public.budget_lines (company_id, wbs_node_id) WHERE wbs_node_id IS NOT NULL;
COMMENT ON TABLE public.budget_lines IS
    'Budget is COST. A budget line may optionally be attributed to a WBS node and/or linked to a BOQ item for analysis, but never becomes revenue.';

CREATE TABLE public.budget_transfers (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL,
    budget_id          uuid NOT NULL,
    from_budget_line_id uuid NOT NULL,
    to_budget_line_id   uuid NOT NULL,
    amount             numeric(20,2) NOT NULL CHECK (amount > 0),
    reason             text NOT NULL,
    approved_by        uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    approved_at        timestamptz NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_budget_transfers_budget FOREIGN KEY (company_id, budget_id)
        REFERENCES public.budgets (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_budget_transfers_from FOREIGN KEY (company_id, from_budget_line_id)
        REFERENCES public.budget_lines (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_budget_transfers_to FOREIGN KEY (company_id, to_budget_line_id)
        REFERENCES public.budget_lines (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_budget_transfers_distinct CHECK (from_budget_line_id <> to_budget_line_id)
);
CREATE INDEX idx_budget_transfers_company_budget
    ON public.budget_transfers (company_id, budget_id, approved_at DESC);
CREATE INDEX idx_budget_transfers_company_line_from
    ON public.budget_transfers (company_id, from_budget_line_id);
CREATE INDEX idx_budget_transfers_company_line_to
    ON public.budget_transfers (company_id, to_budget_line_id);

COMMENT ON TABLE public.budget_transfers IS
    'Approved budget is never edited in place. Reallocation between lines is an explicit, approved, audited transfer (or a new budget version).';

-- -------------------------------------------------------------------------------------
-- 4. Triggers
-- -------------------------------------------------------------------------------------
CREATE TRIGGER trg_budgets_tenant_guard
    BEFORE INSERT OR UPDATE ON public.budgets
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_budget_lines_tenant_guard
    BEFORE INSERT OR UPDATE ON public.budget_lines
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_costs_codes_tenant_guard
    BEFORE INSERT OR UPDATE ON public.cost_codes
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_wbs_nodes_no_cycle
    BEFORE INSERT OR UPDATE OF parent_id ON public.wbs_nodes
    FOR EACH ROW EXECUTE FUNCTION app.forbid_tree_cycle('parent_id');

CREATE TRIGGER trg_cost_codes_no_cycle
    BEFORE INSERT OR UPDATE OF parent_id ON public.cost_codes
    FOR EACH ROW EXECUTE FUNCTION app.forbid_tree_cycle('parent_id');

-- Budget lines are editable only while the budget is draft or submitted (pre-approval).
CREATE OR REPLACE FUNCTION app.enforce_budget_line_editability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM public.budgets
     WHERE company_id = coalesce(NEW.company_id, OLD.company_id)
       AND id = coalesce(NEW.budget_id, OLD.budget_id);

    IF v_status IS NULL THEN
        RETURN coalesce(NEW, OLD);   -- missing parent: let the FK constraint report it
    END IF;

    IF v_status NOT IN ('draft','submitted') THEN
        RAISE EXCEPTION 'BUDGET_LOCKED: lines of a % budget cannot be modified; create a new version or a transfer', v_status
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_budget_lines_editable_preliminary
    BEFORE INSERT OR UPDATE OR DELETE ON public.budget_lines
    FOR EACH ROW EXECUTE FUNCTION app.enforce_budget_line_editability();

-- -------------------------------------------------------------------------------------
-- 5. Cross-reference coherence (project scope) — STRUCTURAL, not trigger-based
-- -------------------------------------------------------------------------------------
-- Budget references to WBS nodes and BOQ items are project-scoped composite FKs, so a reference
-- to another project's node/item cannot be inserted at all. No trigger is needed for this rule
-- on this table. The same pattern (carry `project_id` on the child, reference
-- (company_id, project_id, id) on the parent) is applied in files 06, 07 and 08 to
-- variation_order_lines, ipc_lines, ipc_deductions, ipc_additions, expenses and collections.
--
-- Rule of thumb: a table that references a PROJECT-SCOPED parent must carry `project_id` and use
-- the project-scoped parent key. A table that references a COMPANY-scoped parent (cost codes,
-- parties, roles) uses the company-scoped parent key. See ADR-0019.
