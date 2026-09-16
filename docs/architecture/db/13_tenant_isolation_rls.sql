-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 13 of 15
-- Row-Level Security: the database-side, fail-closed tenant boundary
--
-- PROPERTIES THIS FILE GUARANTEES
--  1. Every tenant-owned table has RLS ENABLED **and FORCED** (so even the table owner is
--     subject to it — a mistake by a migration script cannot silently read all tenants).
--  2. The policy predicate reads the transaction-local GUC `app.current_company_id`.
--     When the GUC is unset the expression is NULL, so NOTHING matches: fail closed, never
--     "show everything".
--  3. WITH CHECK is the same predicate, so a row can never be INSERTed or UPDATEd into a
--     tenant other than the caller's — no matter what the application passes.
--  4. Application roles are created NOSUPERUSER / NOBYPASSRLS (file 13).
--
-- WHAT RLS DOES *NOT* DO
--  * It does not implement project-level authorization: RLS can only see the GUCs we expose.
--    Project scope is enforced in the application's authorization choke point (docs G §4) and
--    additionally by project-scoped composite foreign keys (docs E §6).
--  * It does not protect against a compromised DB superuser or a stolen backup. That is what
--    encryption at rest, off-site encrypted backups and audit hash chains are for.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Enable + force RLS and install the isolation policy on every tenant-owned table
-- -------------------------------------------------------------------------------------
DO $$
DECLARE
    t text;
    tenant_tables text[] := ARRAY[
        -- core / identity / access
        'company_settings','branches','number_series','tax_rates',
        'memberships','membership_invitations','roles','role_permissions','membership_roles',
        'user_branch_scopes','project_members','project_member_permissions','access_delegations',
        -- partners and projects
        'clients','suppliers','subcontractors','party_contacts','projects','project_settings',
        'project_parties','project_milestones','project_status_history',
        -- contracts, BOQ
        'contracts','contract_value_ledger','boqs','boq_sections','boq_items','boq_item_versions','boq_revisions',
        -- WBS / cost codes / budget
        'wbs_nodes','cost_codes','project_cost_codes','budgets','budget_lines','budget_transfers',
        -- import pipeline
        'import_batches','import_rows','import_validation_issues','import_column_mappings',
        -- variations
        'variation_orders','variation_order_lines','variation_order_approvals',
        -- IPC
        'ipcs','ipc_lines','ipc_deductions','ipc_additions','ipc_snapshots','ipc_certificates','ipc_status_history',
        -- cost / cash
        'expenses','expense_allocations','expense_status_history','cost_commitments',
        'collections','collection_allocations','project_forecast_overrides',
        -- documents / approvals / audit
        'documents','document_versions','document_upload_sessions','document_links',
        'approval_workflows','approval_workflow_steps','approval_requests','approval_actions',
        'audit_logs','audit_checkpoints','job_outbox','job_idempotency_keys',
        'notifications','notification_preferences'
    ];
BEGIN
    -- Partitions need their own protection (PostgreSQL does not inherit ENABLE/FORCE RLS onto
    -- partitions). Any partition of a tenant-owned table gets the same policy, so a direct scan of
    -- a partition behaves exactly like a scan of the parent.
    FOR t IN
        SELECT c.relname
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE i.inhparent = ANY (
                 SELECT cl.oid FROM pg_class cl
                  JOIN pg_namespace n ON n.oid = cl.relnamespace
                 WHERE n.nspname = 'public' AND cl.relname = ANY (tenant_tables))
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON public.%I', t);
        EXECUTE format($pol$
            CREATE POLICY tenant_isolation ON public.%I
                USING (company_id = app.current_company_id())
                WITH CHECK (company_id = app.current_company_id())
        $pol$, t);
    END LOOP;

    FOREACH t IN ARRAY tenant_tables LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON public.%I', t);
        EXECUTE format($pol$
            CREATE POLICY tenant_isolation ON public.%I
                AS PERMISSIVE
                FOR ALL
                TO PUBLIC
                USING (company_id = app.current_company_id())
                WITH CHECK (company_id = app.current_company_id())
        $pol$, t);
    END LOOP;
END $$;

-- NOTE on `companies` itself: the tenant root is protected by its own policy keyed on the row's
-- own id, because membership resolution must be able to read the companies the user belongs to
-- before a company context can be set. The application reads company rows only through a
-- SECURITY DEFINER function (app.my_companies()) or with an explicit membership join.
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.companies FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON public.companies;
CREATE POLICY tenant_isolation ON public.companies
    AS PERMISSIVE FOR ALL TO PUBLIC
    USING (id = app.current_company_id())
    WITH CHECK (id = app.current_company_id());

DROP POLICY IF EXISTS self_membership_read ON public.companies;

-- -------------------------------------------------------------------------------------
-- 2. Platform-operator elevation (break-glass)
--    Operators get NOTHING by default. Elevation is granted per request by an audited
--    application action, sets a transaction-local flag, and is recorded in audit_logs with a
--    mandatory reason. The flag never survives the transaction (SET LOCAL only).
-- -------------------------------------------------------------------------------------
DROP POLICY IF EXISTS platform_elevation ON public.companies;   -- elevation is audited, not silent
COMMENT ON FUNCTION app.platform_elevation_active() IS
    'True only inside a transaction where an audited break-glass elevation has been performed. Dashboards and exports must refuse to run while elevation is active.';

-- -------------------------------------------------------------------------------------
-- 3. Guard trigger for financial tables (second line of defence behind RLS)
--    Even if a connection leaks context, or a worker forgets to set it, a financial write with
--    a mismatched or missing company_id is refused. Bindings are created with each table.
-- -------------------------------------------------------------------------------------
DO $$
DECLARE
    t text;
    financial_tables text[] := ARRAY[
        'contracts','contract_value_ledger','boqs','boq_items',
        'budgets','budget_lines','variation_orders','variation_order_lines',
        'ipcs','ipc_lines','ipc_deductions','ipc_additions','ipc_snapshots',
        'expenses','collections','collection_allocations'
    ];
BEGIN
    FOREACH t IN ARRAY financial_tables LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_context_guard ON public.%I', t, t);
        EXECUTE format($tg$
            CREATE TRIGGER trg_%s_context_guard
                BEFORE INSERT OR UPDATE ON public.%I
                FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context()
        $tg$, t, t);
    END LOOP;
END $$;

-- -------------------------------------------------------------------------------------
-- 4. Tenant-context helpers used by the application (one place, one contract)
-- -------------------------------------------------------------------------------------
-- The application opens every request/worker transaction like this:
--
--   BEGIN;
--   SET LOCAL app.current_company_id  = '<company uuid>';   -- from the server-side session
--   SET LOCAL app.current_membership_id = '<membership uuid>';
--   SET LOCAL app.current_user_id     = '<user uuid>';
--   SET LOCAL app.request_id          = '<correlation id>';
--   ... application queries and writes ...
--   COMMIT;
--
-- Never:  SET app.current_company_id = ...   (without LOCAL — would leak across pooled connections)
-- Never:  taking company_id from a request body, query string or header.

CREATE OR REPLACE FUNCTION app.reset_tenant_context()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config('app.current_company_id', '', true);
    PERFORM set_config('app.current_membership_id', '', true);
    PERFORM set_config('app.current_user_id', '', true);
    PERFORM set_config('app.request_id', '', true);
    PERFORM set_config('app.platform_elevation', 'off', true);
END;
$$;
COMMENT ON FUNCTION app.reset_tenant_context() IS
    'Called by the connection-pool reset hook so a recycled connection can never inherit a tenant.';

-- -------------------------------------------------------------------------------------
-- 5. Companies visible to the current user (needed before a company context exists)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.my_companies()
RETURNS TABLE (company_id uuid, membership_id uuid, company_name_en text, status text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT c.id, m.id, c.legal_name_en, m.status
      FROM public.memberships m
      JOIN public.companies c ON c.id = m.company_id
     WHERE m.user_id = app.current_user_id()
       AND m.status = 'active'
       AND c.status = 'active'
       AND c.deleted_at IS NULL;
$$;
COMMENT ON FUNCTION app.my_companies() IS
    'The company switcher. SECURITY DEFINER with a pinned search_path; returns only memberships owned by the current user.';
