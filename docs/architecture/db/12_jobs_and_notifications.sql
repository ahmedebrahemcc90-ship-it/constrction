-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 12 of 15
-- Background job plumbing (transactional outbox, idempotency) and notifications
--
-- WHY AN OUTBOX RATHER THAN "JUST CALL CELERY"
--  * The queue is not transactional and the database is. Publishing to the broker inside a
--    database transaction can lose or duplicate work on a rollback, and calling the broker
--    after commit can lose it on a crash between the two.
--  * An outbox row is written in the SAME transaction as the business change. A dispatcher then
--    publishes it after commit (at-least-once). Handlers are idempotent, and a unique key on the
--    outbox row makes double-publishing harmless.
-- =====================================================================================

CREATE TABLE public.job_outbox (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    job_type          text NOT NULL,               -- 'generate_ipc_pdf', 'send_email', 'refresh_mv',
                                                   -- 'scan_document', 'export_report', 'notify_approver'
    payload           jsonb NOT NULL,
    -- Idempotency of the logical job (not of the delivery attempt)
    dedupe_key        text,
    status            text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','dispatching','published','failed','dead_lettered','cancelled')),
    priority          smallint NOT NULL DEFAULT 100,
    attempts          smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts      smallint NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
    available_at      timestamptz NOT NULL DEFAULT now(),
    locked_at         timestamptz,
    locked_by         text,
    published_at      timestamptz,
    completed_at      timestamptz,
    last_error        text,
    -- Correlation carried into the worker so worker-side auditing looks identical to request-side
    actor_user_id     uuid,
    request_id        text,
    project_id        uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_job_outbox_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_job_outbox_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_job_outbox_attempts CHECK (attempts <= max_attempts)
);
CREATE UNIQUE INDEX uq_job_outbox_dedupe ON public.job_outbox (company_id, job_type, dedupe_key)
    WHERE dedupe_key IS NOT NULL AND status <> 'cancelled';
CREATE INDEX idx_job_outbox_claimable ON public.job_outbox (available_at, priority)
    WHERE status IN ('pending','failed') AND attempts < max_attempts;
CREATE INDEX idx_job_outbox_project ON public.job_outbox (company_id, project_id) WHERE project_id IS NOT NULL;
COMMENT ON TABLE public.job_outbox IS
    'Written in the same transaction as the business change; a dispatcher publishes to the broker after commit. See docs N §3.';

-- Claim the next batch of jobs without two workers taking the same row.
CREATE OR REPLACE FUNCTION app.claim_outbox_jobs(p_worker_id text, p_batch integer DEFAULT 20)
RETURNS SETOF public.job_outbox
LANGUAGE sql
AS $$
    UPDATE public.job_outbox o
       SET status = 'dispatching', locked_at = now(), locked_by = p_worker_id, attempts = o.attempts + 1
     WHERE o.id IN (
        SELECT id FROM public.job_outbox
         WHERE status IN ('pending','failed')
           AND attempts < max_attempts
           AND available_at <= now()
         ORDER BY priority, available_at
         LIMIT p_batch
         FOR UPDATE SKIP LOCKED
     )
    RETURNING o.*;
$$;

-- -------------------------------------------------------------------------------------
-- Client-supplied idempotency for state-changing API calls (payments, expenses, imports)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.job_idempotency_keys (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    idempotency_key   text NOT NULL,
    endpoint          text NOT NULL,
    request_method    text NOT NULL,
    request_hash      text NOT NULL,               -- sha256 of the canonical request body
    response_status   integer,
    response_body     jsonb,
    resource_type     text,
    resource_id       uuid,
    status            text NOT NULL DEFAULT 'in_progress'
                          CHECK (status IN ('in_progress','completed','failed')),
    actor_user_id     uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),
    expires_at        timestamptz NOT NULL DEFAULT now() + interval '24 hours',
    CONSTRAINT uq_idempotency_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_idempotency_key UNIQUE (company_id, endpoint, idempotency_key)
);
CREATE INDEX idx_idempotency_expiry ON public.job_idempotency_keys (expires_at);
COMMENT ON TABLE public.job_idempotency_keys IS
    'Replay protection: the same Idempotency-Key returns the original response instead of posting a second collection/expense. A key reused with a different body is rejected with 409.';

-- -------------------------------------------------------------------------------------
-- Notifications (approval requests, failures, SLA escalations)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.notification_preferences (
    company_id     uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    user_id        uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    event_code     text NOT NULL,                  -- 'approval.requested', 'ipc.certified', 'import.failed', ...
    in_app         boolean NOT NULL DEFAULT true,
    email          boolean NOT NULL DEFAULT true,
    digest_mode    text NOT NULL DEFAULT 'immediate' CHECK (digest_mode IN ('immediate','daily','off')),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_id, user_id, event_code)
);

CREATE TABLE public.notifications (
    id              uuid PRIMARY KEY,
    company_id      uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    user_id         uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    event_code      text NOT NULL,
    title_en        text NOT NULL,
    title_ar        text NOT NULL,
    body_en         text,
    body_ar         text,
    entity_type     text,
    entity_id       uuid,
    project_id      uuid,
    link_path       text,                          -- relative SPA route, no absolute URLs
    severity        text NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','critical')),
    read_at         timestamptz,
    emailed_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_notifications_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_notifications_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_notifications_user_unread ON public.notifications (company_id, user_id, created_at DESC)
    WHERE read_at IS NULL;
