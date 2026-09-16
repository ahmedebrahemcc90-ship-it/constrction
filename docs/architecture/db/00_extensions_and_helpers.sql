-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION
-- Comprehensive Construction SaaS — schema specification, file 00 of 13
-- Target: PostgreSQL 16
--
-- This file is the *specification* that Phase 1 migrations (Django migration + RunSQL)
-- will be generated from. Do not execute files in /docs/architecture/db against a
-- production database. They are reviewed, versioned design artifacts.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Required extensions
-- -------------------------------------------------------------------------------------
-- pgcrypto is deliberately NOT required: gen_random_uuid() and sha256() are built in since
-- PostgreSQL 13/11 respectively. Fewer extensions means fewer privileges and a smaller surface.
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- partial text search on names/descriptions
CREATE EXTENSION IF NOT EXISTS "btree_gist"; -- EXCLUDE constraints combining = and ranges
CREATE EXTENSION IF NOT EXISTS "citext";     -- case-insensitive email / codes

-- -------------------------------------------------------------------------------------
-- 2. Schemas
-- -------------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS app;        -- helper functions, procedures, internal tooling
CREATE SCHEMA IF NOT EXISTS reporting;  -- read models, materialized views
CREATE SCHEMA IF NOT EXISTS archive;    -- pruned audit partitions, archived imports

COMMENT ON SCHEMA app       IS 'Internal helper functions (tenant context, immutability guards, hash chain, numbering).';
COMMENT ON SCHEMA reporting IS 'Derived read models and drill-down views. No business writes.';
COMMENT ON SCHEMA archive   IS 'Cold storage schema for pruned partitions. Still encrypted and backed up.';

-- -------------------------------------------------------------------------------------
-- 3. Schema version / capability registry
--    Lets the application assert that the DB is at the expected structural level, and
--    lets a restore be validated against expected migration state.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.schema_version (
    version          integer      PRIMARY KEY,
    description      text         NOT NULL,
    applied_at       timestamptz  NOT NULL DEFAULT now(),
    app_min_version  text         NOT NULL
);

-- -------------------------------------------------------------------------------------
-- 4. Tenant context helpers
--    The application sets these per transaction with set_config(..., true) i.e. SET LOCAL.
--    They are the ONLY source of truth for tenant scope inside the database.
-- -------------------------------------------------------------------------------------

-- Current company for this transaction; NULL when unset (connection pool leak-guard).
CREATE OR REPLACE FUNCTION app.current_company_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.current_company_id', true), '')::uuid;
$$;

-- Current membership (used by policies/triggers that need the acting membership).
CREATE OR REPLACE FUNCTION app.current_membership_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.current_membership_id', true), '')::uuid;
$$;

-- Acting user (global identity), used for audit triggers and *_by column defaults.
CREATE OR REPLACE FUNCTION app.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.current_user_id', true), '')::uuid;
$$;

-- Correlation id, propagated to audit and outbox rows for tracing.
CREATE OR REPLACE FUNCTION app.current_request_id()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.request_id', true), '');
$$;

-- True when the platform operator has performed an audited elevation for this transaction.
CREATE OR REPLACE FUNCTION app.platform_elevation_active()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(current_setting('app.platform_elevation', true), 'off') = 'on';
$$;

-- -------------------------------------------------------------------------------------
-- 5. Generic trigger helpers
-- -------------------------------------------------------------------------------------

-- 5.1 Maintain updated_at / updated_by on UPDATE.
CREATE OR REPLACE FUNCTION app.touch_row()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    IF NEW.updated_by IS NULL AND app.current_user_id() IS NOT NULL THEN
        NEW.updated_by := app.current_user_id();
    END IF;
    RETURN NEW;
END;
$$;

-- 5.2 Stamp created_by / updated_by on INSERT when the caller did not supply them.
CREATE OR REPLACE FUNCTION app.stamp_actor()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.created_by IS NULL THEN
        NEW.created_by := app.current_user_id();
    END IF;
    NEW.updated_by := coalesce(NEW.updated_by, app.current_user_id());
    RETURN NEW;
END;
$$;

-- 5.3 Guard used on financial tables: refuse writes when the transaction carries no
--     tenant context, or when the row's company_id does not match it. This is a second
--     line of defence behind RLS (defence in depth), and it also protects against a
--     misconfigured worker that forgets to set the GUC.
CREATE OR REPLACE FUNCTION app.enforce_tenant_context()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    ctx uuid := app.current_company_id();
BEGIN
    IF ctx IS NULL THEN
        RAISE EXCEPTION 'TENANT_CONTEXT_MISSING: refusing to write % without app.current_company_id', TG_TABLE_NAME
            USING ERRCODE = '42501';
    END IF;
    IF NEW.company_id IS DISTINCT FROM ctx THEN
        RAISE EXCEPTION 'TENANT_MISMATCH: % row company_id % does not match transaction context %',
            TG_TABLE_NAME, NEW.company_id, ctx
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

-- 5.4 Row immutability guard. Attached to certified/posted documents.
--     `allowed_columns` is the only set of columns that may still change (lifecycle
--     fields such as status/*_at/*_by), and only when `is_allowed` returns true.
CREATE OR REPLACE FUNCTION app.enforce_immutable_row()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    changed text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        -- Deletion is never allowed through application roles for these tables.
        RAISE EXCEPTION 'IMMUTABLE_ROW_DELETE: % rows cannot be deleted; use cancellation/reversal', TG_TABLE_NAME
            USING ERRCODE = '42501';
    END IF;

    -- Compare every column except the explicitly whitelisted lifecycle columns.
    -- IMPORTANT: PostgreSQL reports TG_ARGV as NULL (not as an empty array) when the trigger was
    -- created with no arguments. Coalescing is therefore mandatory: without it,
    -- `column <> ALL(NULL)` yields NULL for every row, the loop never runs, and the guard would
    -- be silently vacuous.
    FOR changed IN
        SELECT c.column_name
        FROM information_schema.columns c
        WHERE c.table_schema = TG_TABLE_SCHEMA
          AND c.table_name   = TG_TABLE_NAME
          AND c.column_name  <> ALL (coalesce(TG_ARGV, '{}'::text[]))
    LOOP
        IF (to_jsonb(NEW) -> changed) IS DISTINCT FROM (to_jsonb(OLD) -> changed) THEN
            RAISE EXCEPTION 'IMMUTABLE_FIELD: %.% cannot be modified (row state %)',
                TG_TABLE_NAME, changed, coalesce(to_jsonb(OLD) ->> 'status', 'immutable')
                USING ERRCODE = '42501';
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;

-- 5.5 Cycle prevention for tree tables (WBS, cost codes, BOQ sections, BOQ items).
--     Requires the name of the parent column as a trigger argument, because tree tables do not
--     all use the same column name (parent_id / parent_section_id / parent_item_id):
--         CREATE TRIGGER ... EXECUTE FUNCTION app.forbid_tree_cycle('parent_section_id');
CREATE OR REPLACE FUNCTION app.forbid_tree_cycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    parent_col text := TG_ARGV[0];
    root       uuid;
    node_id    uuid := (to_jsonb(NEW) ->> 'id')::uuid;
    guard      integer := 0;
BEGIN
    IF parent_col IS NULL THEN
        RAISE EXCEPTION 'forbid_tree_cycle() requires the parent column name as a trigger argument'
            USING ERRCODE = '42601';
    END IF;

    root := (to_jsonb(NEW) ->> parent_col)::uuid;
    IF root IS NULL THEN
        RETURN NEW;
    END IF;
    IF root = node_id THEN
        RAISE EXCEPTION 'TREE_CYCLE: node cannot be its own parent' USING ERRCODE = '23514';
    END IF;

    WHILE root IS NOT NULL LOOP
        guard := guard + 1;
        IF guard > 100 THEN
            RAISE EXCEPTION 'TREE_DEPTH_EXCEEDED: depth limit 100 reached' USING ERRCODE = '23514';
        END IF;
        IF root = node_id THEN
            RAISE EXCEPTION 'TREE_CYCLE: moving node under its own descendant' USING ERRCODE = '23514';
        END IF;
        EXECUTE format('SELECT (to_jsonb(t) ->> $2)::uuid FROM public.%I t WHERE t.id = $1', TG_TABLE_NAME)
           INTO root USING root, parent_col;
    END LOOP;

    RETURN NEW;
END;
$$;

-- 5.6 Refuse deletes outright (used by tables whose rows must be cancelled/reversed, not removed).
CREATE OR REPLACE FUNCTION app.enforce_no_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'DELETE_FORBIDDEN: % rows cannot be deleted; use cancellation or reversal', TG_TABLE_NAME
        USING ERRCODE = '42501';
END;
$$;

-- -------------------------------------------------------------------------------------
-- 6. Document numbering (gap-free-enough per company, per document type)
--    Allocated inside the same transaction as the document insert; row lock on the
--    series row serialises concurrent allocations.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.next_document_number(
    p_company_id uuid,
    p_doc_type   text,
    p_year       integer DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_prefix      text;
    v_padding     integer;
    v_next        bigint;
    v_year        integer := coalesce(p_year, EXTRACT(YEAR FROM (now() AT TIME ZONE 'Asia/Riyadh'))::integer);
    v_year_mode   text;
BEGIN
    SELECT prefix, padding, year_mode
      INTO v_prefix, v_padding, v_year_mode
      FROM public.number_series
     WHERE company_id = p_company_id
       AND doc_type   = p_doc_type
       FOR UPDATE;                               -- serialises concurrent allocation

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NUMBER_SERIES_MISSING: % / %', p_company_id, p_doc_type USING ERRCODE = '23503';
    END IF;

    UPDATE public.number_series
       SET next_value = next_value + 1
     WHERE company_id = p_company_id
       AND doc_type   = p_doc_type
    RETURNING next_value - 1 INTO v_next;

    IF v_year_mode = 'yearly' THEN
        RETURN v_prefix || '-' || v_year::text || '-' || lpad(v_next::text, v_padding, '0');
    ELSE
        RETURN v_prefix || '-' || lpad(v_next::text, v_padding, '0');
    END IF;
END;
$$;

-- -------------------------------------------------------------------------------------
-- 7. Audit hash chain helper
--    row_hash = sha256(prev_hash || canonical_payload). Chain is per company, strictly
--    serialised by a unique (company_id, chain_seq) constraint plus a row lock, so a
--    tamper attempt either breaks verification or blocks. See docs L §4.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.audit_row_hash(
    p_company_id uuid,
    p_chain_seq  bigint,
    p_prev_hash  bytea,
    p_payload    jsonb
)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT sha256(
             coalesce(p_prev_hash, ''::bytea) ||
             convert_to(p_company_id::text || '|' || p_chain_seq::text || '|' || p_payload::text, 'UTF8')
           );
$$;

-- -------------------------------------------------------------------------------------
-- 8. Money helper to keep rounding policy in one place (half-up on the document's
--    currency minor unit — see docs I §2). Kept as a function so the policy is testable
--    and greppable rather than re-implemented per query.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.round_money(p_amount numeric, p_scale integer DEFAULT 2)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT round(p_amount, p_scale);   -- PostgreSQL round() on numeric is half-away-from-zero
$$;
