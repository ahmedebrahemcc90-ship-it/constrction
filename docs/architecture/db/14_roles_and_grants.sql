-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 14 of 15
-- Database roles and least-privilege grants. Credentials come from Docker secrets only.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Roles
--    app_rw       : the web/worker runtime. Tenant-scoped by RLS. No DDL, no BYPASSRLS.
--    app_ro       : reporting/exports/analytics read-only.
--    app_migrator : owns the schema; used ONLY by the migration job with a separate secret.
--    app_backup   : replication/backup privileges for pgBackRest.
--    (No application role is SUPERUSER, CREATEDB, CREATEROLE or BYPASSRLS.)
-- -------------------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_migrator') THEN
        CREATE ROLE app_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
        CREATE ROLE app_rw LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS
            CONNECTION LIMIT 200;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro') THEN
        CREATE ROLE app_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS
            CONNECTION LIMIT 40;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_backup') THEN
        CREATE ROLE app_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
END $$;

-- Ownership: the schema and every object are owned by app_migrator, never by app_rw.
-- (RLS FORCE in file 12 means even the owner cannot read across tenants by accident.)
ALTER SCHEMA public  OWNER TO app_migrator;
ALTER SCHEMA app     OWNER TO app_migrator;
ALTER SCHEMA reporting OWNER TO app_migrator;
ALTER SCHEMA archive OWNER TO app_migrator;

-- -------------------------------------------------------------------------------------
-- 2. Baseline: take away the defaults, then grant explicitly
-- -------------------------------------------------------------------------------------
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

GRANT USAGE ON SCHEMA public, app TO app_rw, app_ro;
GRANT USAGE ON SCHEMA reporting TO app_rw, app_ro;

-- Default privileges for objects created later by migrations
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA public
    GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO app_rw, app_ro;

-- -------------------------------------------------------------------------------------
-- 3. Ordinary runtime access
--    app_rw gets SELECT/INSERT/UPDATE broadly (RLS + triggers + CHECKs enforce the rules),
--    but NOT DELETE on business documents: deletion is replaced by cancellation/reversal.
-- -------------------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO app_rw;

-- Deletion is allowed only where a row is genuinely disposable operational state.
GRANT DELETE ON
    public.import_rows,
    public.import_validation_issues,
    public.document_upload_sessions,
    public.user_mfa_recovery_codes,
    public.password_reset_tokens,
    public.project_member_permissions,
    public.role_permissions,
    public.membership_roles,
    public.user_branch_scopes,
    public.budget_transfers,
    public.project_cost_codes
TO app_rw;

-- Audit: INSERT + SELECT only. No UPDATE, no DELETE, forever (INV-43).
REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_logs FROM app_rw;
GRANT INSERT, SELECT ON public.audit_logs TO app_rw;
REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_checkpoints FROM app_rw;
GRANT INSERT, SELECT ON public.audit_checkpoints TO app_rw;

-- Append-only financial evidence: no UPDATE/DELETE even if a trigger were dropped by mistake.
REVOKE UPDATE, DELETE, TRUNCATE ON public.contract_value_ledger FROM app_rw;
GRANT INSERT, SELECT ON public.contract_value_ledger TO app_rw;

REVOKE UPDATE, DELETE, TRUNCATE ON public.ipc_snapshots FROM app_rw;
GRANT INSERT, SELECT ON public.ipc_snapshots TO app_rw;

REVOKE UPDATE, DELETE, TRUNCATE ON public.variation_order_approvals FROM app_rw;
GRANT INSERT, SELECT ON public.variation_order_approvals TO app_rw;

REVOKE UPDATE, DELETE, TRUNCATE ON public.approval_actions FROM app_rw;
GRANT INSERT, SELECT ON public.approval_actions TO app_rw;

REVOKE UPDATE, DELETE, TRUNCATE ON public.ipc_status_history FROM app_rw;
GRANT INSERT, SELECT ON public.ipc_status_history TO app_rw;

-- Sessions and operational tables
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sessions TO app_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.login_attempts TO app_rw;
GRANT USAGE, SELECT ON SEQUENCE public.login_attempts_id_seq TO app_rw;

-- -------------------------------------------------------------------------------------
-- 4. Read-only role (dashboards, exports, BI)
-- -------------------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_ro;
REVOKE SELECT ON public.audit_logs FROM app_ro;   -- audit is read through a curated view only
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO app_ro;

CREATE OR REPLACE VIEW reporting.v_audit_trail AS
SELECT company_id, occurred_at, actor_user_id, actor_kind, action, entity_type, entity_id,
       entity_label, project_id, reason, request_id, changed_fields
  FROM public.audit_logs;             -- payload details (before/after) are NOT exposed here
GRANT SELECT ON reporting.v_audit_trail TO app_ro;

-- -------------------------------------------------------------------------------------
-- 5. Functions
-- -------------------------------------------------------------------------------------
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO app_rw, app_ro;
REVOKE EXECUTE ON FUNCTION app.audit_append(uuid,text,text,uuid,text,uuid,jsonb,jsonb,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.audit_append(uuid,text,text,uuid,text,uuid,jsonb,jsonb,text,text,text) TO app_rw;

-- -------------------------------------------------------------------------------------
-- 6. Backup / replication role
-- -------------------------------------------------------------------------------------
ALTER ROLE app_backup WITH REPLICATION;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_backup;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO app_backup;

-- -------------------------------------------------------------------------------------
-- 7. Credentials and connection security (operational, enforced at deploy time)
-- -------------------------------------------------------------------------------------
-- * One credential per role, generated at deploy time, stored in Docker secrets, never in Git,
--   never in the image, never echoed by CI.
-- * Rotated on a schedule and on any suspicion; `ALTER ROLE x PASSWORD` performed by the
--   deployment job, never interactively by a human on the production host.
-- * `pg_hba.conf`: local socket + scram-sha-256 for the app network only; NO `host all all 0.0.0.0/0`.
-- * `ssl = on` (or the private Docker network only) plus `listen_addresses` restricted to the
--   container network; PostgreSQL port is NEVER published to the host (docs P §5).
-- * `ALTER SYSTEM SET` changes are made through migrations, not by hand, so they are reviewable.
--
-- Recommended settings for the runtime connection (set at deploy time):
--   ALTER ROLE app_rw SET statement_timeout = '30s';
--   ALTER ROLE app_rw SET idle_in_transaction_session_timeout = '60s';
--   ALTER ROLE app_rw SET lock_timeout = '5s';
--   ALTER ROLE app_rw SET search_path = public, app, pg_catalog;
--   ALTER ROLE app_rw SET default_transaction_isolation = 'read committed';

-- -------------------------------------------------------------------------------------
-- 8. Schema-lint assertions (run in CI; a failure blocks the build)
-- -------------------------------------------------------------------------------------
-- Executable, not aspirational: running this block against a migrated database raises an
-- exception naming the offending objects. CI runs it as the last step of the migration
-- (and again on a restored backup during the monthly drill, [O §6]).
--
--   1. No numeric column of type real/double precision anywhere in public (money must never float).
--   2. Every table with a company_id column has RLS enabled AND forced, and a tenant_isolation policy.
--   3. Every table referenced by a composite foreign key exposes a matching unique key.
--   4. No application role holds SUPERUSER, BYPASSRLS, CREATEROLE or CREATEDB.
--   5. app_rw holds no UPDATE/DELETE on the append-only tables listed in §3.
--   6. Every table with a company_id column has an index whose first column is company_id.
DO $$
DECLARE
    n      bigint;
    detail text;
BEGIN
    -- 1. floating-point columns -------------------------------------------------------
    SELECT count(*), string_agg(format('%I.%I', c.relname, a.attname), ', ')
      INTO n, detail
      FROM pg_class c
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     WHERE ns.nspname = 'public' AND c.relkind = 'r'
       AND format_type(a.atttypid, a.atttypmod) IN ('real', 'double precision');
    IF n > 0 THEN
        RAISE EXCEPTION 'SCHEMA_LINT_1: floating-point column(s) in the financial schema: %', detail;
    END IF;

    -- 2. RLS coverage (partitions included: PostgreSQL does not inherit ENABLE/FORCE) ----
    SELECT count(*), string_agg(c.relname, ', ')
      INTO n, detail
      FROM pg_class c
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'company_id'
                          AND a.attnum > 0 AND NOT a.attisdropped
     WHERE ns.nspname = 'public' AND c.relkind = 'r'
       AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity
            OR NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid));
    IF n > 0 THEN
        RAISE EXCEPTION 'SCHEMA_LINT_2: tenant table(s) without enabled+forced RLS and a policy: %', detail;
    END IF;

    -- 3. composite FK parents expose a matching unique key -----------------------------
    SELECT count(*), string_agg(fk.conrelid::regclass::text || '.' || fk.conname, ', ')
      INTO n, detail
      FROM pg_constraint fk
     WHERE fk.contype = 'f'
       AND fk.connamespace = 'public'::regnamespace
       AND array_length(fk.conkey, 1) >= 2
       AND EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = fk.conrelid AND a.attnum = ANY (fk.conkey)
                      AND a.attname = 'company_id')
       AND NOT EXISTS (
            SELECT 1 FROM pg_index i
             WHERE i.indrelid = fk.confrelid AND i.indisunique
               AND (SELECT array_agg(k ORDER BY k) FROM unnest(i.indkey::int2[]) k)
                 = (SELECT array_agg(y ORDER BY y) FROM unnest(fk.confkey) y));
    IF n > 0 THEN
        RAISE EXCEPTION 'SCHEMA_LINT_3: composite FK(s) without a matching unique key on the parent: %', detail;
    END IF;

    -- 4. application roles are not privileged ------------------------------------------
    SELECT count(*), string_agg(rolname, ', ')
      INTO n, detail
      FROM pg_roles
     WHERE rolname IN ('app_rw', 'app_ro', 'app_migrator', 'app_backup')
       AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb);
    IF n > 0 THEN
        RAISE EXCEPTION 'SCHEMA_LINT_4: application role(s) with elevated attributes: %', detail;
    END IF;

    -- 5. append-only tables cannot be updated or deleted by the runtime role -----------
    SELECT count(*), string_agg(format('%s:%s%s', t.t,
                CASE WHEN has_table_privilege('app_rw', format('public.%I', t.t), 'UPDATE') THEN 'UPDATE ' ELSE '' END,
                CASE WHEN has_table_privilege('app_rw', format('public.%I', t.t), 'DELETE') THEN 'DELETE' ELSE '' END), ', ')
      INTO n, detail
      FROM unnest(ARRAY['audit_logs', 'audit_checkpoints', 'contract_value_ledger', 'ipc_snapshots',
                        'variation_order_approvals', 'approval_actions', 'ipc_status_history']) AS t(t)
     WHERE has_table_privilege('app_rw', format('public.%I', t.t), 'UPDATE')
        OR has_table_privilege('app_rw', format('public.%I', t.t), 'DELETE');
    IF n > 0 THEN
        RAISE EXCEPTION 'SCHEMA_LINT_5: append-only table(s) writable by app_rw: %', detail;
    END IF;

    -- 6. company_id leads an index on every tenant table -------------------------------
    SELECT count(*), string_agg(c.relname, ', ')
      INTO n, detail
      FROM pg_class c
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'company_id'
                          AND a.attnum > 0 AND NOT a.attisdropped
     WHERE ns.nspname = 'public' AND c.relkind = 'r'
       AND NOT EXISTS (SELECT 1 FROM pg_index i
                        WHERE i.indrelid = c.oid AND i.indisvalid AND i.indkey[0] = a.attnum);
    IF n > 0 THEN
        RAISE EXCEPTION 'SCHEMA_LINT_6: tenant table(s) without an index leading with company_id: %', detail;
    END IF;

    RAISE NOTICE 'SCHEMA_LINT: all 6 assertions passed';
END $$;
