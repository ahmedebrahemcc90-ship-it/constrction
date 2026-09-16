-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 10 of 15
-- Audit log: append-only, per-tenant hash-chained, partitioned, off-site checkpointed
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Audit log (partitioned by month)
--    Two complementary sources, both landing in this one table:
--      (a) ROW-LEVEL audit written by database triggers  -> "what changed"
--      (b) SERVICE-LEVEL audit written by the application -> "what was requested/done"
--          (login, permission change, export, download, break-glass, approval decisions)
--    (b) alone is not sufficient: an application bug can forget to call it. That is why the
--    most financially sensitive tables also carry trigger-based auditing that cannot be
--    bypassed from the application layer.
-- -------------------------------------------------------------------------------------
CREATE TABLE public.audit_logs (
    id                  uuid NOT NULL,
    occurred_at         timestamptz NOT NULL DEFAULT now(),
    company_id          uuid NOT NULL,
    -- Actor is stored WITHOUT a foreign key: audit history must survive user anonymisation.
    actor_user_id       uuid,
    actor_membership_id uuid,
    actor_role_codes    text[],
    actor_kind          text NOT NULL DEFAULT 'user'
                            CHECK (actor_kind IN ('user','platform_operator','system','integration','migration')),
    action              text NOT NULL,             -- e.g. 'ipc.certified', 'role.permissions_changed'
    entity_type         text NOT NULL,
    entity_id           uuid,
    entity_label        text,                      -- human-readable reference (e.g. 'IPC-2026-000317')
    project_id          uuid,
    source              text NOT NULL DEFAULT 'web' CHECK (source IN ('web','api','worker','system','migration')),
    before_data         jsonb,
    after_data          jsonb,
    changed_fields      text[],
    reason              text,                      -- mandatory for break-glass and reversals
    ip_address          inet,
    user_agent          text,
    session_id          uuid,
    request_id          text,
    correlation_id      text,
    -- Tamper evidence
    chain_seq           bigint NOT NULL,
    prev_hash           bytea,
    row_hash            bytea NOT NULL,
    hash_key_version    smallint NOT NULL DEFAULT 1,
    PRIMARY KEY (occurred_at, id),
    CONSTRAINT uq_audit_logs_chain UNIQUE (company_id, chain_seq, occurred_at),
    CONSTRAINT ck_audit_logs_breakglass_reason CHECK (
        actor_kind <> 'platform_operator' OR (reason IS NOT NULL AND length(reason) >= 10)
    )
) PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE public.audit_logs IS
    'Append-only audit trail. No application role holds UPDATE or DELETE (see file 13). Row hashes chain per company; checkpoints are exported off-site (see docs L §4).';

CREATE INDEX idx_audit_logs_company_time ON public.audit_logs (company_id, occurred_at DESC);
CREATE INDEX idx_audit_logs_entity       ON public.audit_logs (company_id, entity_type, entity_id, occurred_at DESC);
CREATE INDEX idx_audit_logs_actor        ON public.audit_logs (company_id, actor_user_id, occurred_at DESC);
CREATE INDEX idx_audit_logs_action       ON public.audit_logs (company_id, action, occurred_at DESC);
CREATE INDEX idx_audit_logs_project      ON public.audit_logs (company_id, project_id, occurred_at DESC) WHERE project_id IS NOT NULL;
-- Full-text-ish search on the JSON payload without indexing financial values
CREATE INDEX idx_audit_logs_reason_trgm  ON public.audit_logs USING gin (reason gin_trgm_ops) WHERE reason IS NOT NULL;

-- Monthly partitions. A scheduler job (docs N) pre-creates the next 3 months and detaches
-- old ones for archival. Retention default is 7 years (company-configurable, owner decision D-06).
CREATE TABLE public.audit_logs_2026_09 PARTITION OF public.audit_logs
    FOR VALUES FROM ('2026-09-01+03') TO ('2026-10-01+03');
CREATE TABLE public.audit_logs_2026_10 PARTITION OF public.audit_logs
    FOR VALUES FROM ('2026-10-01+03') TO ('2026-11-01+03');
CREATE TABLE public.audit_logs_2026_11 PARTITION OF public.audit_logs
    FOR VALUES FROM ('2026-11-01+03') TO ('2026-12-01+03');
CREATE TABLE public.audit_logs_2026_12 PARTITION OF public.audit_logs
    FOR VALUES FROM ('2026-12-01+03') TO ('2027-01-01+03');
-- Phase 1 creates partitions programmatically: app.ensure_audit_partitions(months_ahead int)

CREATE OR REPLACE FUNCTION app.ensure_audit_partitions(p_months_ahead integer DEFAULT 3)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_month date := date_trunc('month', (now() AT TIME ZONE 'Asia/Riyadh'))::date;
    v_name  text;
    v_i     integer;
    v_created integer := 0;
BEGIN
    FOR v_i IN 0..p_months_ahead LOOP
        v_name := format('audit_logs_%s', to_char(v_month + (v_i || ' month')::interval, 'YYYY_MM'));
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_name AND relnamespace = 'public'::regnamespace) THEN
            EXECUTE format(
                'CREATE TABLE public.%I PARTITION OF public.audit_logs FOR VALUES FROM (%L) TO (%L)',
                v_name,
                to_char(v_month + (v_i || ' month')::interval, 'YYYY-MM-01'),
                to_char(v_month + ((v_i + 1) || ' month')::interval, 'YYYY-MM-01')
            );
            -- A new partition must be protected in its own right: PostgreSQL does not inherit
            -- ENABLE ROW LEVEL SECURITY onto partitions, and a partition reached directly (or by
            -- a planner path that does not visit the parent policy) must not be readable across
            -- tenants. The CI lint in db/14 §8 fails the build when a company_id table lacks RLS.
            EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', v_name);
            EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', v_name);
            EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON public.%I', v_name);
            EXECUTE format(
                'CREATE POLICY tenant_isolation ON public.%I USING (company_id = app.current_company_id()) '
                'WITH CHECK (company_id = app.current_company_id())', v_name);
            v_created := v_created + 1;
        END IF;
    END LOOP;
    RETURN v_created;
END;
$$;

-- -------------------------------------------------------------------------------------
-- 2. Append helper — the ONLY supported way to write audit rows
--    Serialises per company (row lock on the chain head) so chain_seq is gap-free and the
--    hash chain is linear. Called from the same transaction as the business change (INV-42).
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.audit_append(
    p_company_id    uuid,
    p_action        text,
    p_entity_type   text,
    p_entity_id     uuid,
    p_entity_label  text DEFAULT NULL,
    p_project_id    uuid DEFAULT NULL,
    p_before        jsonb DEFAULT NULL,
    p_after         jsonb DEFAULT NULL,
    p_reason        text DEFAULT NULL,
    p_actor_kind    text DEFAULT 'user',
    p_source        text DEFAULT 'web'
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_seq       bigint;
    v_prev      bytea;
    v_payload   jsonb;
    v_id        uuid := gen_random_uuid();
    v_now       timestamptz := now();
    v_changed   text[];
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'AUDIT_TENANT_REQUIRED: audit rows must carry a company_id' USING ERRCODE = '42501';
    END IF;

    -- Serialise the chain for this company for the remainder of the transaction.
    PERFORM pg_advisory_xact_lock(hashtext('audit_chain:' || p_company_id::text));

    SELECT chain_seq, row_hash
      INTO v_seq, v_prev
      FROM public.audit_logs
     WHERE company_id = p_company_id
     ORDER BY chain_seq DESC
     LIMIT 1;

    v_seq := coalesce(v_seq, 0) + 1;

    IF p_before IS NOT NULL AND p_after IS NOT NULL THEN
        SELECT array_agg(key ORDER BY key)
          INTO v_changed
          FROM jsonb_each(p_after) a
         WHERE a.value IS DISTINCT FROM (p_before -> a.key);
    END IF;

    v_payload := jsonb_build_object(
        'company_id',   p_company_id,
        'actor_user_id',    app.current_user_id(),
        'actor_membership_id', app.current_membership_id(),
        'actor_kind',   p_actor_kind,
        'action',       p_action,
        'entity_type',  p_entity_type,
        'entity_id',    p_entity_id,
        'entity_label', p_entity_label,
        'project_id',   p_project_id,
        'before',       p_before,
        'after',        p_after,
        'changed',      v_changed,
        'reason',       p_reason,
        'source',       p_source,
        'request_id',   app.current_request_id()
    );

    INSERT INTO public.audit_logs (
        id, occurred_at, company_id, actor_user_id, actor_membership_id, actor_kind, action,
        entity_type, entity_id, entity_label, project_id, source, before_data, after_data,
        changed_fields, reason, request_id, chain_seq, prev_hash, row_hash
    ) VALUES (
        v_id, v_now, p_company_id, app.current_user_id(), app.current_membership_id(), p_actor_kind, p_action,
        p_entity_type, p_entity_id, p_entity_label, p_project_id, p_source, p_before, p_after,
        v_changed, p_reason, app.current_request_id(), v_seq, v_prev,
        app.audit_row_hash(p_company_id, v_seq, v_prev, v_payload)
    );

    RETURN v_id;
END;
$$;

-- -------------------------------------------------------------------------------------
-- 3. Generic row-change auditing for the sensitive tables
--    Bound in Phase 1 to: contracts, contract_value_ledger, boqs, boq_items, variation_orders,
--    ipcs, ipc_lines, ipc_deductions, ipc_additions, expenses, collections, collection_allocations,
--    memberships, membership_roles, role_permissions, project_members, roles, documents,
--    document_versions, approval_actions, company_settings, tax_rates, number_series.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.audit_row_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_company uuid;
    v_entity_id uuid;
    v_action text;
    v_before jsonb;
    v_after jsonb;
    v_label text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_company := OLD.company_id;
        v_entity_id := OLD.id;
        v_action := TG_ARGV[0] || '.deleted';
        v_before := to_jsonb(OLD);
        v_after := NULL;
    ELSIF TG_OP = 'INSERT' THEN
        v_company := NEW.company_id;
        v_entity_id := NEW.id;
        v_action := coalesce(TG_ARGV[0], TG_TABLE_NAME) || '.created';
        v_before := NULL;
        v_after := to_jsonb(NEW);
    ELSE
        v_company := NEW.company_id;
        v_entity_id := NEW.id;
        v_action := TG_ARGV[0] || '.updated';
        v_before := to_jsonb(OLD);
        v_after := to_jsonb(NEW);
    END IF;

    v_label := coalesce(v_after ->> 'number', v_after ->> 'ipc_number', v_after ->> 'vo_number',
                        v_after ->> 'expense_number', v_after ->> 'collection_number',
                        v_after ->> 'name_en', v_after ->> 'title_en', v_before ->> 'name_en');

    PERFORM app.audit_append(
        p_company_id  => v_company,
        p_action      => v_action,
        p_entity_type => TG_TABLE_NAME,
        p_entity_id   => v_entity_id,
        p_entity_label=> v_label,
        p_project_id  => coalesce((v_after ->> 'project_id')::uuid, (v_before ->> 'project_id')::uuid),
        p_before      => v_before,
        p_after       => v_after,
        p_actor_kind  => CASE WHEN app.current_user_id() IS NULL THEN 'system' ELSE 'user' END,
        p_source      => CASE WHEN app.current_request_id() IS NULL THEN 'system' ELSE 'web' END
    );

    RETURN NULL;   -- AFTER trigger
END;
$$;

-- -------------------------------------------------------------------------------------
-- 4. Checkpoints: prove the chain off-site without exporting every row
-- -------------------------------------------------------------------------------------
CREATE TABLE public.audit_checkpoints (
    id              uuid PRIMARY KEY,
    company_id      uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    from_seq        bigint NOT NULL,
    to_seq          bigint NOT NULL,
    row_count       bigint NOT NULL CHECK (row_count > 0),
    last_row_hash   bytea NOT NULL,
    head_row_id     uuid NOT NULL,
    head_occurred_at timestamptz NOT NULL,
    exported_at     timestamptz NOT NULL DEFAULT now(),
    exported_by     text NOT NULL DEFAULT 'scheduler',
    storage_object_key text,              -- encrypted JSONL of the covered rows in object storage
    manifest_sha256 text CHECK (manifest_sha256 IS NULL OR manifest_sha256 ~ '^[0-9a-f]{64}$'),
    verify_status   text NOT NULL DEFAULT 'not_verified'
                        CHECK (verify_status IN ('not_verified','verified','mismatch','restore_tested')),
    verified_at     timestamptz,
    notes           text,
    CONSTRAINT uq_audit_checkpoints UNIQUE (company_id, to_seq)
);
CREATE INDEX idx_audit_checkpoints_company ON public.audit_checkpoints (company_id, to_seq DESC);

-- Verify a chain segment: recompute every row hash and compare with the stored ones.
CREATE OR REPLACE FUNCTION app.verify_audit_chain(
    p_company_id uuid,
    p_from_seq   bigint DEFAULT 1,
    p_to_seq     bigint DEFAULT NULL
)
RETURNS TABLE (bad_seq bigint, reason text)
LANGUAGE plpgsql
AS $$
DECLARE
    r       record;
    v_prev  bytea;
    v_payload jsonb;
    v_expect bytea;
BEGIN
    FOR r IN
        SELECT * FROM public.audit_logs
         WHERE company_id = p_company_id
           AND chain_seq >= p_from_seq
           AND (p_to_seq IS NULL OR chain_seq <= p_to_seq)
         ORDER BY chain_seq
    LOOP
        IF r.prev_hash IS DISTINCT FROM v_prev THEN
            bad_seq := r.chain_seq; reason := 'prev_hash does not match the previous row';
            RETURN NEXT;
        END IF;

        v_payload := jsonb_build_object(
            'company_id',   r.company_id,
            'actor_user_id', r.actor_user_id,
            'actor_membership_id', r.actor_membership_id,
            'actor_kind',   r.actor_kind,
            'action',       r.action,
            'entity_type',  r.entity_type,
            'entity_id',    r.entity_id,
            'entity_label', r.entity_label,
            'project_id',   r.project_id,
            'before',       r.before_data,
            'after',        r.after_data,
            'changed',      r.changed_fields,
            'reason',       r.reason,
            'source',       r.source,
            'request_id',   r.request_id
        );
        v_expect := app.audit_row_hash(r.company_id, r.chain_seq, r.prev_hash, v_payload);

        IF v_expect IS DISTINCT FROM r.row_hash THEN
            bad_seq := r.chain_seq; reason := 'row_hash mismatch (content altered)';
            RETURN NEXT;
        END IF;

        v_prev := r.row_hash;
    END LOOP;

    RETURN;
END;
$$;
COMMENT ON FUNCTION app.verify_audit_chain(uuid, bigint, bigint) IS
    'Scheduled integrity check. Any returned row means tampering or corruption and must raise a P1 alert.';
