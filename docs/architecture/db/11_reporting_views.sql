-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 11 of 15
-- Reporting read models: curated views and materialized views (no user-authored SQL)
--
-- PRINCIPLES
--  * Every number is derived from documents, using SNAPSHOTTED rates, never from current
--    configuration (INV-52).
--  * Dashboards read materialized views refreshed on a schedule, with a "as of" timestamp
--    shown to the user; drill-down views read live data and are project-scope filtered.
--  * Every read model is company-scoped by construction. Reporting never broadens a
--    caller's scope: the application adds its own project filter on top.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Certified position per BOQ item (the basis for "previous cumulative" and progress)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_boq_item_certified AS
SELECT
    i.company_id,
    i.project_id,
    i.boq_id,
    i.boq_section_id,
    i.id                         AS boq_item_id,
    i.item_code,
    i.description_en,
    i.unit_id,
    i.quantity                   AS boq_quantity,
    i.unit_rate,
    i.amount                     AS boq_amount,
    coalesce(vo.approved_vo_quantity, 0)                        AS approved_vo_quantity,
    coalesce(vo.approved_vo_amount, 0)                          AS approved_vo_amount,
    i.quantity + coalesce(vo.approved_vo_quantity, 0)           AS revised_quantity,
    coalesce(cert.certified_quantity, 0)                        AS certified_quantity,
    coalesce(cert.certified_amount, 0)                          AS certified_amount,
    CASE WHEN (i.quantity + coalesce(vo.approved_vo_quantity, 0)) > 0
         THEN round(100 * coalesce(cert.certified_quantity, 0)
                        / (i.quantity + coalesce(vo.approved_vo_quantity, 0)), 4)
         ELSE 0
    END                                                         AS certified_pct,
    (i.quantity + coalesce(vo.approved_vo_quantity, 0)) - coalesce(cert.certified_quantity, 0)
                                                                AS remaining_quantity,
    (i.amount + coalesce(vo.approved_vo_amount, 0)) - coalesce(cert.certified_amount, 0)
                                                                AS remaining_amount
FROM public.boq_items i
LEFT JOIN LATERAL (
    SELECT sum(l.amount)  AS approved_vo_amount,
           sum(l.quantity_delta) AS approved_vo_quantity
      FROM public.variation_order_lines l
      JOIN public.variation_orders v
        ON v.company_id = l.company_id AND v.id = l.variation_order_id
     WHERE l.company_id = i.company_id
       AND l.boq_item_id = i.id
       AND v.status = 'approved'
) vo ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(il.current_quantity)                                        AS certified_quantity,
           sum(round(il.current_quantity * il.certified_rate, 2))          AS certified_amount
      FROM public.ipc_lines il
      JOIN public.ipcs p ON p.company_id = il.company_id AND p.id = il.ipc_id
     WHERE il.company_id = i.company_id
       AND il.boq_item_id = i.id
       AND p.status IN ('certified','approved','posted','partially_paid','paid','closed')
) cert ON TRUE
WHERE i.deleted_at IS NULL;

-- -------------------------------------------------------------------------------------
-- 2. Contract value summary (ledger is the authority, not the cached column)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_contract_value_summary AS
SELECT
    c.company_id,
    c.project_id,
    c.id                        AS contract_id,
    c.contract_number,
    c.status,
    c.original_value,
    coalesce(l.approved_variation_amount, 0)                    AS approved_variation_amount,
    coalesce(l.other_adjustments, 0)                            AS other_adjustments,
    c.original_value + coalesce(l.net_delta, 0)                 AS revised_contract_value,
    c.current_value                                             AS cached_current_value,
    (c.original_value + coalesce(l.net_delta, 0)) <> c.current_value AS cache_needs_reconcile,
    coalesce(pending.pending_vo_count, 0)                       AS pending_vo_count,
    coalesce(pending.pending_vo_amount, 0)                      AS pending_vo_amount_not_yet_in_rcv,
    coalesce(cert.certified_work_value, 0)                      AS certified_work_value_to_date,
    coalesce(cert.certified_retention, 0)                       AS retention_withheld_to_date,
    coalesce(cert.certified_advance_recovered, 0)               AS advance_recovered_to_date,
    greatest(c.advance_amount - coalesce(cert.certified_advance_recovered, 0), 0) AS advance_outstanding,
    coalesce(coll.collected_amount, 0)                          AS collected_amount,
    coalesce(cert.certified_net_outstanding, 0)                 AS outstanding_receivable
FROM public.contracts c
LEFT JOIN LATERAL (
    SELECT sum(CASE WHEN entry_type = 'variation_approved' THEN amount_delta END)  AS approved_variation_amount,
           sum(CASE WHEN entry_type NOT IN ('original_contract','variation_approved') THEN amount_delta END) AS other_adjustments,
           sum(amount_delta)                                                       AS net_delta
      FROM public.contract_value_ledger
     WHERE company_id = c.company_id AND contract_id = c.id
) l ON TRUE
LEFT JOIN LATERAL (
    SELECT count(*) AS pending_vo_count, sum(addition_amount - omission_amount) AS pending_vo_amount
      FROM public.variation_orders v
     WHERE v.company_id = c.company_id AND v.contract_id = c.id
       AND v.status IN ('submitted','under_review')
       AND v.deleted_at IS NULL
) pending ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(p.cumulative_work_value)         AS certified_work_value,
           sum(p.cumulative_retention)          AS certified_retention,
           sum(p.cumulative_advance_recovered)  AS certified_advance_recovered,
           sum(p.total_payable_incl_vat) - sum(p.amount_received) AS certified_net_outstanding
      FROM public.ipcs p
     WHERE p.company_id = c.company_id AND p.contract_id = c.id
       AND p.status IN ('certified','approved','posted','partially_paid','paid','closed')
) cert ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(cl.amount) AS collected_amount
      FROM public.collections cl
     WHERE cl.company_id = c.company_id AND cl.contract_id = c.id
       AND cl.status IN ('posted','reconciled')
) coll ON TRUE
WHERE c.deleted_at IS NULL;

-- -------------------------------------------------------------------------------------
-- 3. Forecast cost inputs (explicit, auditable overrides for expected profitability)
--    V1 default method: forecast = actual + (remaining RCV x budget cost ratio)
--    A project manager may override the estimate to complete, with a reason.
-- -------------------------------------------------------------------------------------
CREATE TABLE public.project_forecast_overrides (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL,
    project_id        uuid NOT NULL,
    as_of_date        date NOT NULL,
    forecast_cost_amount numeric(20,2) NOT NULL CHECK (forecast_cost_amount >= 0),
    method            text NOT NULL DEFAULT 'manual_etc'
                          CHECK (method IN ('manual_etc','manual_total','budget_ratio')),
    reason            text NOT NULL,
    entered_by        uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    created_at        timestamptz NOT NULL DEFAULT now(),
    superseded_by_id  uuid,
    CONSTRAINT uq_project_forecast_overrides_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_pfo_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_pfo_one_current_per_project
    ON public.project_forecast_overrides (company_id, project_id)
    WHERE superseded_by_id IS NULL;
COMMENT ON TABLE public.project_forecast_overrides IS
    'Latest non-superseded row per project is the current forecast. Historical rows are kept so a change in expected profitability is explainable.';

-- -------------------------------------------------------------------------------------
-- 4. Project financial position (materialized view; refreshed by the scheduler)
-- -------------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW reporting.mv_project_financial_position AS
SELECT
    p.company_id,
    p.id                                    AS project_id,
    p.code                                  AS project_code,
    p.name_en,
    p.name_ar,
    p.status                                AS project_status,
    p.branch_id,
    c.id                                    AS contract_id,
    c.currency_code,
    -- Revenue side
    coalesce(cvs.revised_contract_value, 0) AS revised_contract_value,
    coalesce(cvs.certified_work_value_to_date, 0) AS certified_revenue_to_date,
    coalesce(cvs.outstanding_receivable, 0) AS outstanding_receivable,
    coalesce(cvs.collected_amount, 0)       AS collected_amount,
    coalesce(cvs.retention_withheld_to_date, 0) AS retention_withheld,
    coalesce(cvs.advance_outstanding, 0)    AS advance_outstanding,
    -- Cost side: four distinct concepts, never conflated (docs I §3)
    coalesce(b.budget_amount, 0)            AS approved_budget,
    coalesce(cm.committed_amount, 0)        AS committed_cost,
    coalesce(ex.actual_amount, 0)           AS actual_cost,
    -- Forecast: explicit override when present, otherwise remaining-value x budget cost ratio
    CASE
        WHEN fo.forecast_cost_amount IS NOT NULL THEN fo.forecast_cost_amount
        WHEN coalesce(b.budget_amount, 0) = 0 OR coalesce(b.budget_revenue_basis, 0) = 0
            THEN coalesce(ex.actual_amount, 0)
        ELSE round(
                coalesce(ex.actual_amount, 0)
                + (coalesce(cvs.revised_contract_value, 0) - coalesce(cvs.certified_work_value_to_date, 0))
                  * (coalesce(b.budget_amount, 0) / nullif(b.budget_revenue_basis, 0))
             , 2)
    END                                     AS forecast_cost,
    -- Profitability
    round(coalesce(cvs.certified_work_value_to_date, 0)
          - coalesce(ex.actual_amount, 0), 2)                AS margin_to_date,
    round(coalesce(cvs.revised_contract_value, 0)
          - CASE
                WHEN fo.forecast_cost_amount IS NOT NULL THEN fo.forecast_cost_amount
                WHEN coalesce(b.budget_amount, 0) = 0 OR coalesce(b.budget_revenue_basis, 0) = 0
                    THEN coalesce(ex.actual_amount, 0)
                ELSE round(
                        coalesce(ex.actual_amount, 0)
                        + (coalesce(cvs.revised_contract_value, 0) - coalesce(cvs.certified_work_value_to_date, 0))
                          * (coalesce(b.budget_amount, 0) / nullif(b.budget_revenue_basis, 0))
                     , 2)
            END, 2)                                          AS expected_final_margin,
    CASE WHEN coalesce(cvs.revised_contract_value, 0) > 0
         THEN round(100 * (coalesce(cvs.revised_contract_value, 0)
              - CASE
                    WHEN fo.forecast_cost_amount IS NOT NULL THEN fo.forecast_cost_amount
                    WHEN coalesce(b.budget_amount, 0) = 0 OR coalesce(b.budget_revenue_basis, 0) = 0
                        THEN coalesce(ex.actual_amount, 0)
                    ELSE round(coalesce(ex.actual_amount, 0)
                         + (coalesce(cvs.revised_contract_value, 0) - coalesce(cvs.certified_work_value_to_date, 0))
                           * (coalesce(b.budget_amount, 0) / nullif(b.budget_revenue_basis, 0)), 2)
                END)
              / coalesce(cvs.revised_contract_value, 0), 4)
         ELSE 0
    END                                     AS expected_margin_pct,
    -- Progress
    coalesce(prog.certified_value_pct, 0)   AS certified_value_pct,
    prog.last_certified_period_to           AS last_certified_period_to,
    prog.open_ipc_count                     AS open_ipc_count,
    fo.forecast_cost_amount IS NOT NULL     AS forecast_is_manually_overridden,
    now()                                   AS refreshed_at
FROM public.projects p
LEFT JOIN LATERAL (
    SELECT ct.* FROM public.contracts ct
     WHERE ct.company_id = p.company_id AND ct.project_id = p.id
       AND ct.deleted_at IS NULL
     ORDER BY ct.is_primary DESC, ct.created_at
     LIMIT 1
) c ON TRUE
LEFT JOIN reporting.v_contract_value_summary cvs
       ON cvs.company_id = p.company_id AND cvs.contract_id = c.id
LEFT JOIN LATERAL (
    SELECT sum(bl.amount) AS budget_amount,
           -- revenue basis: contract value as known when the budget was approved
           (SELECT coalesce(sum(l.amount_delta), 0)
              FROM public.contract_value_ledger l
             WHERE l.company_id = b.company_id
               AND l.contract_id = c.id
               AND l.effective_date <= b.effective_from)         AS budget_revenue_basis
      FROM public.budgets b
      LEFT JOIN public.budget_lines bl
             ON bl.company_id = b.company_id AND bl.budget_id = b.id AND bl.deleted_at IS NULL
     WHERE b.company_id = p.company_id AND b.project_id = p.id AND b.status = 'approved'
     GROUP BY b.id, b.company_id, b.effective_from
     ORDER BY b.version_no DESC
     LIMIT 1
) b ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(cc.committed_amount - cc.consumed_amount) AS committed_amount
      FROM public.cost_commitments cc
     WHERE cc.company_id = p.company_id AND cc.project_id = p.id AND cc.status IN ('open','partially_consumed')
) cm ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(e.net_amount) AS actual_amount
      FROM public.expenses e
     WHERE e.company_id = p.company_id AND e.project_id = p.id
       AND e.status IN ('posted','paid')
       AND e.deleted_at IS NULL
) ex ON TRUE
LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE i.status IN ('submitted','under_review')) AS open_ipc_count,
           max(i.period_to) FILTER (WHERE i.status IN ('certified','approved','posted','partially_paid','paid','closed')) AS last_certified_period_to,
           CASE WHEN cvs.revised_contract_value > 0
                THEN round(100 * coalesce(cvs.certified_work_value_to_date,0) / cvs.revised_contract_value, 4)
           END AS certified_value_pct
      FROM public.ipcs i
     WHERE i.company_id = p.company_id AND i.project_id = p.id AND i.deleted_at IS NULL
) prog ON TRUE
LEFT JOIN public.project_forecast_overrides fo
       ON fo.company_id = p.company_id AND fo.project_id = p.id AND fo.superseded_by_id IS NULL
WHERE p.deleted_at IS NULL;

CREATE UNIQUE INDEX uq_mv_pfp ON reporting.mv_project_financial_position (company_id, project_id);
CREATE INDEX idx_mv_pfp_company ON reporting.mv_project_financial_position (company_id, project_status);

-- -------------------------------------------------------------------------------------
-- 5. Cost by cost code (budget vs committed vs actual), for cost-control screens
-- -------------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW reporting.mv_project_cost_by_costcode AS
WITH cc AS (
    SELECT c.id AS company_id, cc.id AS cost_code_id, cc.code, cc.name_en, cc.name_ar, cc.parent_id
      FROM public.cost_codes cc JOIN public.companies c ON c.id = cc.company_id
     WHERE cc.deleted_at IS NULL
)
SELECT
    p.company_id,
    p.project_id,
    cc.cost_code_id,
    cc.code   AS cost_code,
    cc.name_en,
    cc.name_ar,
    coalesce(bud.budget_amount, 0)      AS budget_amount,
    coalesce(comm.committed_amount, 0)  AS committed_amount,
    coalesce(act.actual_amount, 0)      AS actual_cost,
    coalesce(bud.budget_amount, 0) - coalesce(act.actual_amount, 0) AS budget_variance,
    coalesce(act.actual_amount, 0) - coalesce(comm.committed_amount, 0) AS uncommitted_cost
FROM (
    SELECT company_id, id AS project_id FROM public.projects WHERE deleted_at IS NULL
) p
CROSS JOIN LATERAL (
    SELECT DISTINCT bl.cost_code_id
      FROM public.budget_lines bl
      JOIN public.budgets b ON b.company_id = bl.company_id AND b.id = bl.budget_id
     WHERE b.company_id = p.company_id AND b.project_id = p.project_id
    UNION
    SELECT DISTINCT e.cost_code_id
      FROM public.expenses e
     WHERE e.company_id = p.company_id AND e.project_id = p.project_id
    UNION
    SELECT DISTINCT cm.cost_code_id
      FROM public.cost_commitments cm
     WHERE cm.company_id = p.company_id AND cm.project_id = p.project_id
) used
JOIN cc ON cc.company_id = p.company_id AND cc.cost_code_id = used.cost_code_id
LEFT JOIN LATERAL (
    SELECT sum(bl.amount) AS budget_amount
      FROM public.budget_lines bl
      JOIN public.budgets b ON b.company_id = bl.company_id AND b.id = bl.budget_id
     WHERE b.company_id = p.company_id AND b.project_id = p.project_id
       AND b.status = 'approved' AND bl.cost_code_id = cc.cost_code_id AND bl.deleted_at IS NULL
) bud ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(cm.committed_amount - cm.consumed_amount) AS committed_amount
      FROM public.cost_commitments cm
     WHERE cm.company_id = p.company_id AND cm.project_id = p.project_id
       AND cm.cost_code_id = cc.cost_code_id AND cm.status IN ('open','partially_consumed')
) comm ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(e.net_amount) AS actual_amount
      FROM public.expenses e
     WHERE e.company_id = p.company_id AND e.project_id = p.project_id
       AND e.cost_code_id = cc.cost_code_id AND e.status IN ('posted','paid') AND e.deleted_at IS NULL
) act ON TRUE;
CREATE INDEX idx_mv_cost_cc ON reporting.mv_project_cost_by_costcode (company_id, project_id, cost_code);

-- -------------------------------------------------------------------------------------
-- 6. Receivable aging (live view: must reflect today's allocations)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_ipc_receivable_aging AS
SELECT
    i.company_id,
    i.project_id,
    i.contract_id,
    i.id AS ipc_id,
    i.ipc_number,
    i.period_to,
    i.status,
    i.total_payable_incl_vat,
    i.amount_received,
    i.outstanding_amount,
    coalesce(i.posted_at, i.certified_at)::date          AS basis_date,
    (current_date - coalesce(i.posted_at, i.certified_at)::date) AS days_outstanding,
    CASE
        WHEN (current_date - coalesce(i.posted_at, i.certified_at)::date) <= 30  THEN '0-30'
        WHEN (current_date - coalesce(i.posted_at, i.certified_at)::date) <= 60  THEN '31-60'
        WHEN (current_date - coalesce(i.posted_at, i.certified_at)::date) <= 90  THEN '61-90'
        WHEN (current_date - coalesce(i.posted_at, i.certified_at)::date) <= 180 THEN '91-180'
        ELSE '180+'
    END                                                   AS aging_bucket
FROM public.ipcs i
WHERE i.status IN ('certified','approved','posted','partially_paid')
  AND i.deleted_at IS NULL
  AND i.outstanding_amount > 0;

-- -------------------------------------------------------------------------------------
-- 7. Variation register and budget-vs-actual drill-downs
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_variation_register AS
SELECT
    v.company_id, v.project_id, v.contract_id, v.id AS variation_order_id,
    v.vo_number, v.title_en, v.title_ar, v.vo_category, v.status,
    v.instruction_date, v.submitted_at::date AS submitted_on, v.approved_at::date AS approved_on,
    v.addition_amount, v.omission_amount, v.net_amount,
    (v.status = 'approved')                    AS affects_contract_value,
    v.value_posted_at IS NOT NULL              AS posted_to_ledger,
    (v.status IN ('submitted','under_review')) AS awaiting_decision,
    now() - v.submitted_at                     AS time_in_workflow,
    ar.id                                      AS approval_request_id,
    ar.current_step_no
FROM public.variation_orders v
LEFT JOIN public.approval_requests ar
       ON ar.company_id = v.company_id AND ar.variation_order_id = v.id AND ar.status = 'pending'
WHERE v.deleted_at IS NULL;

CREATE OR REPLACE VIEW reporting.v_boq_vs_budget AS
SELECT
    b.company_id, b.project_id, b.boq_id, b.id AS boq_item_id, b.item_code, b.description_en,
    b.quantity AS boq_quantity, b.unit_rate, b.amount AS boq_amount,
    coalesce(bud.budget_amount, 0) AS linked_budget_amount,
    coalesce(bud.budget_amount, 0) - b.amount AS gross_margin_on_item,
    CASE WHEN b.amount > 0
         THEN round(100 * (b.amount - coalesce(bud.budget_amount, 0)) / b.amount, 4)
         ELSE 0 END AS gross_margin_pct
FROM public.boq_items b
LEFT JOIN LATERAL (
    SELECT sum(bl.amount) AS budget_amount
      FROM public.budget_lines bl
     WHERE bl.company_id = b.company_id AND bl.boq_item_id = b.id AND bl.deleted_at IS NULL
) bud ON TRUE
WHERE b.deleted_at IS NULL;

-- -------------------------------------------------------------------------------------
-- 8. Company dashboard roll-up
-- -------------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW reporting.mv_company_dashboard AS
SELECT
    f.company_id,
    count(*)                                                    AS project_count,
    count(*) FILTER (WHERE f.project_status = 'active')          AS active_project_count,
    sum(f.revised_contract_value)                               AS total_revised_contract_value,
    sum(f.certified_revenue_to_date)                            AS total_certified_revenue,
    sum(f.collected_amount)                                      AS total_collected,
    sum(f.outstanding_receivable)                                AS total_outstanding_receivable,
    sum(f.retention_withheld)                                    AS total_retention_withheld,
    sum(f.approved_budget)                                       AS total_approved_budget,
    sum(f.committed_cost)                                        AS total_committed_cost,
    sum(f.actual_cost)                                           AS total_actual_cost,
    sum(f.forecast_cost)                                         AS total_forecast_cost,
    sum(f.expected_final_margin)                                 AS total_expected_margin,
    CASE WHEN sum(f.revised_contract_value) > 0
         THEN round(100 * sum(f.expected_final_margin) / sum(f.revised_contract_value), 4)
         ELSE 0 END                                              AS portfolio_margin_pct,
    count(*) FILTER (WHERE f.forecast_cost > f.revised_contract_value) AS loss_making_project_count,
    now()                                                        AS refreshed_at
FROM reporting.mv_project_financial_position f
GROUP BY f.company_id;

-- -------------------------------------------------------------------------------------
-- 9. Refresh strategy (executed by the scheduler, docs N)
-- -------------------------------------------------------------------------------------
-- REFRESH MATERIALIZED VIEW CONCURRENTLY reporting.mv_project_financial_position;
-- REFRESH MATERIALIZED VIEW CONCURRENTLY reporting.mv_project_cost_by_costcode;
-- REFRESH MATERIALIZED VIEW CONCURRENTLY reporting.mv_company_dashboard;
-- CONCURRENTLY requires the unique indexes above. Refresh runs after the nightly close-of-day
-- job and on demand after certification/posting events (debounced), and always records the
-- refresh timestamp shown on dashboards as "as of".
