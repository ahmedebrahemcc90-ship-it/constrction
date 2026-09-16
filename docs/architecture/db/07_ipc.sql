-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 07 of 13
-- Client IPCs (interim payment certificates / progress certificates)
--
-- DESIGN NOTES THAT MATTER:
--  * The header carries EXPLICIT previous / cumulative / current triples because that is how
--    an IPC is legally read. "Previous" values are NEVER taken from a client request: they are
--    read from the authoritative certified history inside the certification transaction
--    (function app.certify_ipc) and then validated by a trigger (app.validate_ipc_previous_values).
--  * Line amounts, cumulative quantities and current-period values are all generated or
--    certified by the server. A client may only send measured quantities (and even those are
--    re-validated against BOQ/VO limits).
--  * All amounts: numeric(20,2). No floating point anywhere (INV-50).
-- =====================================================================================

CREATE TABLE public.ipcs (
    id                       uuid PRIMARY KEY,
    company_id               uuid NOT NULL,
    project_id               uuid NOT NULL,
    contract_id              uuid NOT NULL,
    ipc_number               text NOT NULL,
    revision_no              integer NOT NULL DEFAULT 0 CHECK (revision_no >= 0),
    supersedes_ipc_id        uuid,

    period_from              date NOT NULL,
    period_to                date NOT NULL,
    certificate_date         date,
    submission_date          date,
    due_date                 date,                     -- certificate_date + payment terms
    currency_code            char(3) NOT NULL DEFAULT 'SAR' REFERENCES public.currencies(code),

    -- ---- work value: previous / cumulative / current -----------------------------------
    previous_work_value      numeric(20,2) NOT NULL DEFAULT 0 CHECK (previous_work_value >= 0),
    cumulative_work_value    numeric(20,2) NOT NULL DEFAULT 0 CHECK (cumulative_work_value >= 0),
    current_work_value       numeric(20,2)
                                GENERATED ALWAYS AS (cumulative_work_value - previous_work_value) STORED,

    -- ---- retention: previous / cumulative / current ------------------------------------
    retention_pct            numeric(9,4) NOT NULL DEFAULT 0 CHECK (retention_pct BETWEEN 0 AND 100),
    previous_retention       numeric(20,2) NOT NULL DEFAULT 0 CHECK (previous_retention >= 0),
    cumulative_retention     numeric(20,2) NOT NULL DEFAULT 0 CHECK (cumulative_retention >= 0),
    current_retention        numeric(20,2)
                                GENERATED ALWAYS AS (cumulative_retention - previous_retention) STORED,

    -- ---- advance recovery: previous / cumulative / current -----------------------------
    previous_advance_recovered numeric(20,2) NOT NULL DEFAULT 0 CHECK (previous_advance_recovered >= 0),
    cumulative_advance_recovered numeric(20,2) NOT NULL DEFAULT 0 CHECK (cumulative_advance_recovered >= 0),
    current_advance_recovered numeric(20,2)
                                GENERATED ALWAYS AS (cumulative_advance_recovered - previous_advance_recovered) STORED,

    -- ---- other deductions (retention/advance excluded; those are above and itemised in
    --      ipc_deductions) ---------------------------------------------------------------
    previous_other_deductions numeric(20,2) NOT NULL DEFAULT 0 CHECK (previous_other_deductions >= 0),
    cumulative_other_deductions numeric(20,2) NOT NULL DEFAULT 0 CHECK (cumulative_other_deductions >= 0),
    current_other_deductions numeric(20,2)
                                GENERATED ALWAYS AS (cumulative_other_deductions - previous_other_deductions) STORED,

    -- ---- additions (approved claims, price adjustment, escalation) ---------------------
    previous_additions       numeric(20,2) NOT NULL DEFAULT 0 CHECK (previous_additions >= 0),
    cumulative_additions     numeric(20,2) NOT NULL DEFAULT 0 CHECK (cumulative_additions >= 0),
    current_additions        numeric(20,2)
                                GENERATED ALWAYS AS (cumulative_additions - previous_additions) STORED,

    -- ---- net payable -------------------------------------------------------------------
    current_net_payable      numeric(20,2) GENERATED ALWAYS AS (
                                 (cumulative_work_value - previous_work_value)
                                 + (cumulative_additions - previous_additions)
                                 - (cumulative_retention - previous_retention)
                                 - (cumulative_advance_recovered - previous_advance_recovered)
                                 - (cumulative_other_deductions - previous_other_deductions)
                             ) STORED,
    previous_net_payable     numeric(20,2) NOT NULL DEFAULT 0,
    -- NOTE: PostgreSQL forbids a generated column from referencing another generated column, so the
    -- derived header figures below are stored columns whose arithmetic is enforced by CHECK
    -- identities instead. Same enforcement strength, one expression written out (docs I §5).
    cumulative_net_payable   numeric(20,2) NOT NULL DEFAULT 0,

    -- ---- VAT (stored explicitly, validated against the rate by trigger) ----------------
    vat_rate_bp              integer NOT NULL DEFAULT 1500 CHECK (vat_rate_bp BETWEEN 0 AND 10000),
    vat_base_amount          numeric(20,2) NOT NULL DEFAULT 0,
    vat_amount               numeric(20,2) NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
    total_payable_incl_vat   numeric(20,2) NOT NULL DEFAULT 0,

    -- ---- settlement ---------------------------------------------------------------------
    amount_received          numeric(20,2) NOT NULL DEFAULT 0 CHECK (amount_received >= 0),
    outstanding_amount       numeric(20,2) NOT NULL DEFAULT 0,

    -- ---- lifecycle ----------------------------------------------------------------------
    status                   text NOT NULL DEFAULT 'draft' CHECK (status IN (
                                 'draft','submitted','under_review','certified','approved',
                                 'posted','partially_paid','paid','closed','rejected','cancelled','reversed'
                             )),
    submitted_by             uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    submitted_at             timestamptz,
    certified_by             uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    certified_at             timestamptz,
    approved_by              uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    approved_at              timestamptz,
    posted_by                uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    posted_at                timestamptz,
    rejected_by              uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    rejected_at              timestamptz,
    rejection_reason         text,
    cancelled_by             uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    cancelled_at             timestamptz,
    reversed_by              uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    reversed_at              timestamptz,
    reversal_reason          text,
    reverses_ipc_id          uuid REFERENCES public.ipcs(id) ON DELETE RESTRICT,

    -- ---- provenance ----------------------------------------------------------------------
    client_reference         text,                     -- client's certificate/valuation number
    client_received_date     date,                     -- when the client issued/returned the certificate
    measurement_method       text NOT NULL DEFAULT 'joint' CHECK (measurement_method IN ('joint','contractor_only','client')),
    notes                    text,
    snapshot_id              uuid,                     -- ipc_snapshots.id, set at certification
    version                  integer NOT NULL DEFAULT 1,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid,
    updated_by               uuid,
    deleted_at               timestamptz,

    CONSTRAINT uq_ipcs_company_id_id UNIQUE (company_id, id),
    -- project-scoped parent key: IPC lines, deductions, additions and snapshots reference
    -- (company_id, project_id, id) so a line can never be attached to another project's IPC.
    CONSTRAINT uq_ipcs_company_project_id UNIQUE (company_id, project_id, id),
    CONSTRAINT uq_ipc_number UNIQUE (company_id, contract_id, ipc_number, revision_no),
    CONSTRAINT fk_ipcs_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ipcs_contract FOREIGN KEY (company_id, project_id, contract_id)
        REFERENCES public.contracts (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ipcs_supersedes FOREIGN KEY (company_id, id) REFERENCES public.ipcs (company_id, id) ON DELETE RESTRICT,
    -- Arithmetic identities for the stored derived figures (INV-25 / INV-51).
    CONSTRAINT ck_ipcs_net_payable_identity CHECK (
        current_net_payable = (
            (cumulative_work_value - previous_work_value)
            + (cumulative_additions - previous_additions)
            - (cumulative_retention - previous_retention)
            - (cumulative_advance_recovered - previous_advance_recovered)
            - (cumulative_other_deductions - previous_other_deductions)
        )
    ),
    CONSTRAINT ck_ipcs_cumulative_net_payable_identity CHECK (
        cumulative_net_payable = previous_net_payable + current_net_payable
    ),
    CONSTRAINT ck_ipcs_vat_identity CHECK (
        vat_amount = round(vat_base_amount * vat_rate_bp / 10000.0, 2)
    ),
    CONSTRAINT ck_ipcs_total_identity CHECK (
        total_payable_incl_vat = current_net_payable + vat_amount
    ),
    CONSTRAINT ck_ipcs_outstanding_identity CHECK (
        outstanding_amount = round(total_payable_incl_vat, 2) - amount_received
    ),
    CONSTRAINT ck_ipcs_period CHECK (period_to > period_from),
    -- Monotonic cumulative values: a cumulative can never be below the previous cumulative.
    CONSTRAINT ck_ipcs_monotonic CHECK (
        cumulative_work_value >= previous_work_value
        AND cumulative_retention >= previous_retention
        AND cumulative_advance_recovered >= previous_advance_recovered
        AND cumulative_other_deductions >= previous_other_deductions
        AND cumulative_additions >= previous_additions
        AND cumulative_net_payable >= previous_net_payable
    ),
    -- Certification evidence is mandatory and coherent.
    CONSTRAINT ck_ipcs_certified_evidence CHECK (
        status NOT IN ('certified','approved','posted','partially_paid','paid','closed')
        OR (certified_by IS NOT NULL AND certified_at IS NOT NULL AND snapshot_id IS NOT NULL)
    ),
    CONSTRAINT ck_ipcs_submitted_evidence CHECK (status <> 'submitted' OR submitted_at IS NOT NULL),
    CONSTRAINT ck_ipcs_rejected_evidence CHECK (
        status <> 'rejected' OR (rejection_reason IS NOT NULL AND rejected_at IS NOT NULL)
    ),
    CONSTRAINT ck_ipcs_reversal_coherent CHECK (
        status <> 'reversed' OR (reverses_ipc_id IS NOT NULL AND reversed_at IS NOT NULL AND reversal_reason IS NOT NULL)
    ),
    CONSTRAINT ck_ipcs_reversal_not_self CHECK (reverses_ipc_id IS NULL OR reverses_ipc_id <> id),
    CONSTRAINT ck_ipcs_received_le_payable CHECK (amount_received <= total_payable_incl_vat)
);
CREATE INDEX idx_ipcs_contract_status ON public.ipcs (company_id, contract_id, status, period_to DESC);
CREATE INDEX idx_ipcs_project_period  ON public.ipcs (company_id, project_id, period_to DESC);
CREATE INDEX idx_ipcs_receivable      ON public.ipcs (company_id, status)
    WHERE status IN ('certified','approved','posted','partially_paid') AND deleted_at IS NULL;

-- No two non-cancelled IPCs of the same contract may cover overlapping measurement periods.
ALTER TABLE public.ipcs
    ADD CONSTRAINT ex_ipcs_no_period_overlap
    EXCLUDE USING gist (
        company_id WITH =,
        contract_id WITH =,
        daterange(period_from, period_to, '[]') WITH &&
    ) WHERE (status NOT IN ('cancelled','reversed'));

-- -------------------------------------------------------------------------------------
-- IPC lines: measured revenue per BOQ item
-- -------------------------------------------------------------------------------------
CREATE TABLE public.ipc_lines (
    id                        uuid PRIMARY KEY,
    company_id                uuid NOT NULL,
    project_id                uuid NOT NULL,
    ipc_id                    uuid NOT NULL,
    line_no                   integer NOT NULL CHECK (line_no > 0),
    boq_item_id               uuid NOT NULL,
    boq_id_snapshot           uuid NOT NULL,
    boq_revision_no_snapshot  integer NOT NULL,
    item_code_snapshot        text NOT NULL,
    description_en_snapshot   text NOT NULL,
    description_ar_snapshot   text,
    unit_code_snapshot        text NOT NULL,
    boq_quantity_snapshot     numeric(18,6) NOT NULL CHECK (boq_quantity_snapshot >= 0),
    approved_vo_quantity      numeric(18,6) NOT NULL DEFAULT 0,   -- from approved VOs for this item

    -- The authoritative triple. previous_* is filled from certified history, never from input.
    previous_cumulative_quantity numeric(18,6) NOT NULL DEFAULT 0 CHECK (previous_cumulative_quantity >= 0),
    current_quantity          numeric(18,6) NOT NULL CHECK (current_quantity <> 0),
    cumulative_quantity       numeric(18,6)
                                 GENERATED ALWAYS AS (previous_cumulative_quantity + current_quantity) STORED,

    -- Rate is SNAPSHOTTED at certification so a later BOQ revision cannot change history.
    certified_rate            numeric(18,4) NOT NULL CHECK (certified_rate >= 0),
    previous_cumulative_amount numeric(20,2) NOT NULL DEFAULT 0 CHECK (previous_cumulative_amount >= 0),
    current_amount            numeric(20,2)
                                 GENERATED ALWAYS AS (round(current_quantity * certified_rate, 2)) STORED,
    cumulative_amount         numeric(20,2)
                                 GENERATED ALWAYS AS (round((previous_cumulative_quantity + current_quantity) * certified_rate, 2)) STORED,

    is_from_variation         boolean NOT NULL DEFAULT false,
    variation_order_line_id   uuid,
    measurement_reference     text,                -- site measurement sheet / joint measurement ref
    measurement_date          date,
    notes                     text,
    sort_order                integer NOT NULL DEFAULT 0,
    created_at                timestamptz NOT NULL DEFAULT now(),
    updated_at                timestamptz NOT NULL DEFAULT now(),
    created_by                uuid,
    updated_by                uuid,

    CONSTRAINT uq_ipc_lines_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_ipc_lines_item UNIQUE (company_id, ipc_id, boq_item_id),
    CONSTRAINT uq_ipc_lines_no   UNIQUE (company_id, ipc_id, line_no),
    CONSTRAINT fk_ipc_lines_ipc FOREIGN KEY (company_id, project_id, ipc_id)
        REFERENCES public.ipcs (company_id, project_id, id) ON DELETE CASCADE,
    -- project-scoped: a BOQ item of another project cannot be certified on this IPC
    CONSTRAINT fk_ipc_lines_boq_item FOREIGN KEY (company_id, project_id, boq_item_id)
        REFERENCES public.boq_items (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ipc_lines_vo_line FOREIGN KEY (company_id, project_id, variation_order_line_id)
        REFERENCES public.variation_order_lines (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_ipc_lines_vo_coherent CHECK (
        (variation_order_line_id IS NOT NULL) = is_from_variation
    )
);
CREATE INDEX idx_ipc_lines_ipc  ON public.ipc_lines (company_id, ipc_id, sort_order);
-- The index that answers "cumulative certified quantity for this BOQ item as of date X".
CREATE INDEX idx_ipc_lines_item_history ON public.ipc_lines (company_id, boq_item_id, ipc_id);
COMMENT ON TABLE public.ipc_lines IS
    'Measured quantities per BOQ item. previous_cumulative_quantity is derived from certified IPCs of the same contract, never supplied by a client (INV-20).';

-- -------------------------------------------------------------------------------------
-- Deductions and additions (itemised detail behind the header aggregates)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.ipc_deductions (
    id                       uuid PRIMARY KEY,
    company_id               uuid NOT NULL,
    project_id               uuid NOT NULL,
    ipc_id                   uuid NOT NULL,
    deduction_type           text NOT NULL CHECK (deduction_type IN (
                                 'retention','advance_recovery','material_on_site_recovery',
                                 'liquidated_damages','penalty','utility','insurance','other'
                             )),
    description              text NOT NULL,
    computation_basis        text NOT NULL DEFAULT 'percent_of_certified'
                                 CHECK (computation_basis IN ('percent_of_certified','fixed_amount','contract_term','manual_approved')),
    rate_pct                 numeric(9,4) CHECK (rate_pct IS NULL OR rate_pct BETWEEN 0 AND 100),
    contract_term_reference  text,
    previous_cumulative_amount numeric(20,2) NOT NULL DEFAULT 0 CHECK (previous_cumulative_amount >= 0),
    cumulative_amount        numeric(20,2) NOT NULL CHECK (cumulative_amount >= 0),
    current_amount           numeric(20,2)
                                 GENERATED ALWAYS AS (cumulative_amount - previous_cumulative_amount) STORED,
    is_system_generated      boolean NOT NULL DEFAULT true,
    approved_by              uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    document_id              uuid,
    sort_order               integer NOT NULL DEFAULT 0,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid,
    CONSTRAINT uq_ipc_deductions_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_ipc_deductions_ipc FOREIGN KEY (company_id, project_id, ipc_id)
        REFERENCES public.ipcs (company_id, project_id, id) ON DELETE CASCADE,
    -- Only one system retention line and one advance-recovery line per IPC.
    CONSTRAINT ck_ipc_deductions_amounts CHECK (cumulative_amount >= previous_cumulative_amount)
);
CREATE UNIQUE INDEX uq_ipc_deductions_system_singleton
    ON public.ipc_deductions (company_id, ipc_id, deduction_type)
    WHERE is_system_generated AND deduction_type IN ('retention','advance_recovery');

CREATE TABLE public.ipc_additions (
    id                       uuid PRIMARY KEY,
    company_id               uuid NOT NULL,
    project_id               uuid NOT NULL,
    ipc_id                   uuid NOT NULL,
    addition_type            text NOT NULL CHECK (addition_type IN (
                                 'approved_claim','price_adjustment','material_escalation',
                                 'provisional_sum_adjustment','other'
                             )),
    description              text NOT NULL,
    previous_cumulative_amount numeric(20,2) NOT NULL DEFAULT 0 CHECK (previous_cumulative_amount >= 0),
    cumulative_amount        numeric(20,2) NOT NULL CHECK (cumulative_amount >= 0),
    current_amount           numeric(20,2)
                                 GENERATED ALWAYS AS (cumulative_amount - previous_cumulative_amount) STORED,
    approved_by              uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    document_id              uuid,
    sort_order               integer NOT NULL DEFAULT 0,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid,
    CONSTRAINT uq_ipc_additions_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_ipc_additions_ipc FOREIGN KEY (company_id, project_id, ipc_id)
        REFERENCES public.ipcs (company_id, project_id, id) ON DELETE CASCADE,
    CONSTRAINT ck_ipc_additions_amounts CHECK (cumulative_amount >= previous_cumulative_amount)
);

-- -------------------------------------------------------------------------------------
-- Certification snapshot — the legal/audit anchor for every certified IPC.
-- Records the commercial terms in force at the moment of certification so the certificate is
-- fully reproducible years later even if the contract is later amended (INV-52).
-- -------------------------------------------------------------------------------------
CREATE TABLE public.ipc_snapshots (
    id                       uuid PRIMARY KEY,
    company_id               uuid NOT NULL,
    project_id               uuid NOT NULL,
    ipc_id                   uuid NOT NULL,
    contract_id              uuid NOT NULL,
    contract_version_snapshot integer NOT NULL,
    contract_value_at_certification numeric(20,2) NOT NULL,
    original_contract_value_snapshot numeric(20,2) NOT NULL,
    approved_vo_total_snapshot numeric(20,2) NOT NULL,

    boq_id_snapshot          uuid NOT NULL,
    boq_revision_no_snapshot integer NOT NULL,
    boq_total_snapshot       numeric(20,2) NOT NULL,

    retention_pct_snapshot   numeric(9,4) NOT NULL,
    retention_cap_pct_snapshot numeric(9,4),
    advance_amount_snapshot  numeric(20,2) NOT NULL,
    advance_recovery_pct_snapshot numeric(9,4) NOT NULL,
    advance_recovery_mode_snapshot text NOT NULL,
    vat_rate_bp_snapshot     integer NOT NULL,
    currency_code_snapshot   char(3) NOT NULL,

    -- Provenance of the previous/ cumulative values actually used.
    previous_ipc_id          uuid,
    previous_period_to       date,
    source_of_previous_values text NOT NULL DEFAULT 'certified_history'
                                CHECK (source_of_previous_values = 'certified_history'),

    payload                  jsonb NOT NULL,     -- canonical payload that was hashed
    payload_sha256           text NOT NULL CHECK (payload_sha256 ~ '^[0-9a-f]{64}$'),
    computed_by_user_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    computed_at              timestamptz NOT NULL DEFAULT now(),
    certification_request_id text,
    engine_version           text NOT NULL,      -- calculation engine version, for reproducibility
    created_at               timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_ipc_snapshots_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_ipc_snapshots_one_per_ipc UNIQUE (company_id, ipc_id),
    CONSTRAINT fk_ipc_snapshots_ipc FOREIGN KEY (company_id, project_id, ipc_id)
        REFERENCES public.ipcs (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ipc_snapshots_contract FOREIGN KEY (company_id, project_id, contract_id)
        REFERENCES public.contracts (company_id, project_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_ipc_snapshots_boq FOREIGN KEY (company_id, boq_id_snapshot)
        REFERENCES public.boqs (company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_ipc_snapshots_ipc ON public.ipc_snapshots (company_id, ipc_id);

-- -------------------------------------------------------------------------------------
-- Generated certificate documents
-- -------------------------------------------------------------------------------------
CREATE TABLE public.ipc_certificates (
    id             uuid PRIMARY KEY,
    company_id     uuid NOT NULL,
    ipc_id         uuid NOT NULL,
    document_id    uuid NOT NULL,                    -- documents.id (file 09)
    kind           text NOT NULL CHECK (kind IN ('system_pdf','signed_scan','client_issued','supporting')),
    locale         text NOT NULL DEFAULT 'ar' CHECK (locale IN ('ar','en')),
    template_code  text NOT NULL,
    generated_at   timestamptz NOT NULL DEFAULT now(),
    generated_by   uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    sha256         text,
    CONSTRAINT fk_ipc_certificates_ipc FOREIGN KEY (company_id, ipc_id)
        REFERENCES public.ipcs (company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_ipc_certificates_ipc ON public.ipc_certificates (company_id, ipc_id);

CREATE TABLE public.ipc_status_history (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL,
    ipc_id        uuid NOT NULL,
    from_status   text,
    to_status     text NOT NULL,
    actor_user_id uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    changed_at    timestamptz NOT NULL DEFAULT now(),
    comment       text,
    approval_request_id uuid,
    ip_address    inet,
    request_id    text,
    CONSTRAINT fk_ipc_status_history_ipc FOREIGN KEY (company_id, ipc_id)
        REFERENCES public.ipcs (company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_ipc_status_history ON public.ipc_status_history (company_id, ipc_id, changed_at);

-- -------------------------------------------------------------------------------------
-- Previous-value validation trigger
--   Any INSERT/UPDATE that claims a set of previous_* values on a certification path must agree
--   with the authoritative certified history of the same contract. This is the database's own
--   check that the application did not, for example, read a "previous" value from the last
--   certificate of a DIFFERENT contract, or skip a missing certificate.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.validate_ipc_previous_values()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev record;
BEGIN
    IF NEW.status NOT IN ('certified','approved','posted','partially_paid','paid','closed') THEN
        RETURN NEW;   -- only certifications carry authoritative previous/cumulative values
    END IF;

    SELECT i.id, i.period_to, i.cumulative_work_value, i.cumulative_retention,
           i.cumulative_advance_recovered, i.cumulative_other_deductions,
           i.cumulative_additions, i.cumulative_net_payable
      INTO v_prev
      FROM public.ipcs i
     WHERE i.company_id = NEW.company_id
       AND i.contract_id = NEW.contract_id
       AND i.id <> NEW.id
       AND i.status IN ('certified','approved','posted','partially_paid','paid','closed')
       AND i.period_to < NEW.period_from
     ORDER BY i.period_to DESC, i.revision_no DESC
     LIMIT 1;

    IF v_prev.id IS NULL THEN
        -- First certificate of the contract: every previous value must be zero.
        IF NEW.previous_work_value <> 0 OR NEW.previous_retention <> 0
           OR NEW.previous_advance_recovered <> 0 OR NEW.previous_other_deductions <> 0
           OR NEW.previous_additions <> 0 OR NEW.previous_net_payable <> 0 THEN
            RAISE EXCEPTION 'IPC_PREVIOUS_VALUES_INVALID: no prior certified IPC exists but previous values are non-zero'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    -- Identity checks: the claimed previous values must equal the prior certificate's cumulative values.
    IF (NEW.previous_work_value, NEW.previous_retention, NEW.previous_advance_recovered,
        NEW.previous_other_deductions, NEW.previous_additions, NEW.previous_net_payable)
       IS DISTINCT FROM
       (v_prev.cumulative_work_value, v_prev.cumulative_retention, v_prev.cumulative_advance_recovered,
        v_prev.cumulative_other_deductions, v_prev.cumulative_additions, v_prev.cumulative_net_payable)
    THEN
        RAISE EXCEPTION 'IPC_PREVIOUS_VALUES_MISMATCH: previous values do not match certified IPC % (period_to %)',
            v_prev.id, v_prev.period_to USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

-- -------------------------------------------------------------------------------------
-- Certification service contract (implemented in Phase 1, specified here because the
-- transactional guarantees are load-bearing)
-- -------------------------------------------------------------------------------------
-- app.certify_ipc(p_company_id, p_ipc_id, p_actor_user_id, p_request_id)
--   BEGIN
--     SET LOCAL app.current_company_id / app.current_user_id
--     SELECT pg_advisory_xact_lock(hashtext('ipc_certify:' || <contract_id>::text));   <-- INV-28
--     lock the IPC row FOR UPDATE
--     assert status IN ('draft','submitted','under_review')  and BOQ status = 'approved'  (INV-27)
--     assert contract.status = 'active'
--     assert no overlapping non-cancelled IPC for this contract period                      (INV-26)
--     read prior certified IPC  -> previous_* (invariant INV-20; DB re-checks via trigger)
--     recompute each line's previous_cumulative_quantity/-amount from certified ipc_lines
--       (aggregate over certified IPCs of the same contract ordered by period)
--     assert cumulative_quantity <= boq_quantity + approved_vo_quantity                     (INV-21)
--     recompute line current_amount from SNAPSHOTTED rate                                   (INV-22)
--     recompute retention / advance recovery / other deductions                             (INV-23/24)
--     recompute header aggregates and VAT; assert header == Σ lines (reconciliation check)
--     INSERT ipc_snapshots (terms in force, payload + sha256, engine_version)
--     UPDATE ipcs SET status='certified', certified_by/at, snapshot_id, cumulative_*, previous_*
--     INSERT ipc_status_history
--     INSERT audit_logs payload (before/after, request_id)
--   COMMIT
-- Any failure: nothing is certified, and the IPC remains in its prior state.

-- -------------------------------------------------------------------------------------
-- Freeze functions for certified documents
-- -------------------------------------------------------------------------------------
-- After certification an IPC is a financial record. Only lifecycle/settlement columns may
-- change; every commercial figure is frozen and corrections go through reversal + re-issue.
CREATE OR REPLACE FUNCTION app.enforce_ipc_header_freeze()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IN ('certified','approved','posted','partially_paid','paid','closed','reversed') THEN
        -- allowed mutable columns after certification:
        --   status, approval/settlement stamps, amount_received, version, updated_at/by,
        --   client_reference, client_received_date, notes
        IF (NEW.period_from, NEW.period_to, NEW.contract_id, NEW.ipc_number, NEW.revision_no,
            NEW.previous_work_value, NEW.cumulative_work_value,
            NEW.previous_retention, NEW.cumulative_retention, NEW.retention_pct,
            NEW.previous_advance_recovered, NEW.cumulative_advance_recovered,
            NEW.previous_other_deductions, NEW.cumulative_other_deductions,
            NEW.previous_additions, NEW.cumulative_additions,
            NEW.previous_net_payable, NEW.vat_rate_bp, NEW.vat_base_amount, NEW.vat_amount,
            NEW.snapshot_id, NEW.certified_by, NEW.certified_at, NEW.currency_code)
           IS DISTINCT FROM
           (OLD.period_from, OLD.period_to, OLD.contract_id, OLD.ipc_number, OLD.revision_no,
            OLD.previous_work_value, OLD.cumulative_work_value,
            OLD.previous_retention, OLD.cumulative_retention, OLD.retention_pct,
            OLD.previous_advance_recovered, OLD.cumulative_advance_recovered,
            OLD.previous_other_deductions, OLD.cumulative_other_deductions,
            OLD.previous_additions, OLD.cumulative_additions,
            OLD.previous_net_payable, OLD.vat_rate_bp, OLD.vat_base_amount, OLD.vat_amount,
            OLD.snapshot_id, OLD.certified_by, OLD.certified_at, OLD.currency_code)
        THEN
            RAISE EXCEPTION 'IPC_FROZEN: certified IPC commercial values cannot be modified; reverse and re-issue'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.enforce_ipc_line_freeze()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status text;
    v_ipc_id uuid := coalesce(NEW.ipc_id, OLD.ipc_id);
    v_company uuid := coalesce(NEW.company_id, OLD.company_id);
BEGIN
    SELECT status INTO v_status FROM public.ipcs
     WHERE company_id = v_company AND id = v_ipc_id;

    IF v_status IS NULL THEN
        RETURN coalesce(NEW, OLD);   -- missing parent: let the FK constraint report it
    END IF;

    IF v_status IS DISTINCT FROM 'draft' AND v_status IS DISTINCT FROM 'submitted'
       AND v_status IS DISTINCT FROM 'under_review' THEN
        RAISE EXCEPTION 'IPC_LINES_FROZEN: lines, deductions and additions of a % IPC cannot be modified; reverse and re-issue', v_status
            USING ERRCODE = '42501';
    END IF;
    RETURN coalesce(NEW, OLD);
END;
$$;

-- Deferred FK from the IPC header to its certification snapshot (snapshots are defined below).
ALTER TABLE public.ipcs
    ADD CONSTRAINT fk_ipcs_snapshot FOREIGN KEY (company_id, snapshot_id)
        REFERENCES public.ipc_snapshots (company_id, id) ON DELETE RESTRICT;

-- -------------------------------------------------------------------------------------
-- Triggers
-- -------------------------------------------------------------------------------------
CREATE TRIGGER trg_ipcs_tenant_guard
    BEFORE INSERT OR UPDATE ON public.ipcs
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_ipcs_previous_values
    BEFORE INSERT OR UPDATE ON public.ipcs
    FOR EACH ROW EXECUTE FUNCTION app.validate_ipc_previous_values();

CREATE TRIGGER trg_ipc_lines_tenant_guard
    BEFORE INSERT OR UPDATE ON public.ipc_lines
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

-- Certified/posted IPC headers: only lifecycle and settlement columns may change afterwards.
CREATE TRIGGER trg_ipcs_frozen_after_certification
    BEFORE UPDATE OR DELETE ON public.ipcs
    FOR EACH ROW EXECUTE FUNCTION app.enforce_ipc_header_freeze();

CREATE TRIGGER trg_ipc_lines_frozen_after_certification
    BEFORE INSERT OR UPDATE OR DELETE ON public.ipc_lines
    FOR EACH ROW EXECUTE FUNCTION app.enforce_ipc_line_freeze();

CREATE TRIGGER trg_ipc_snapshots_immutable
    BEFORE UPDATE OR DELETE ON public.ipc_snapshots
    FOR EACH ROW EXECUTE FUNCTION app.enforce_immutable_row();   -- no args: every column protected

-- Deductions and additions are part of the certified arithmetic: retention, advance recovery and
-- additions must be as immutable as the lines they were computed from. Same guard function (it
-- resolves the parent IPC and refuses changes once that IPC leaves the editable states).
CREATE TRIGGER trg_ipc_deductions_frozen_after_certification
    BEFORE INSERT OR UPDATE OR DELETE ON public.ipc_deductions
    FOR EACH ROW EXECUTE FUNCTION app.enforce_ipc_line_freeze();

CREATE TRIGGER trg_ipc_additions_frozen_after_certification
    BEFORE INSERT OR UPDATE OR DELETE ON public.ipc_additions
    FOR EACH ROW EXECUTE FUNCTION app.enforce_ipc_line_freeze();

-- Tenant guard on both child tables (kept next to the freeze guards so they are added together).
CREATE TRIGGER trg_ipc_deductions_tenant_guard
    BEFORE INSERT OR UPDATE ON public.ipc_deductions
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

CREATE TRIGGER trg_ipc_additions_tenant_guard
    BEFORE INSERT OR UPDATE ON public.ipc_additions
    FOR EACH ROW EXECUTE FUNCTION app.enforce_tenant_context();

