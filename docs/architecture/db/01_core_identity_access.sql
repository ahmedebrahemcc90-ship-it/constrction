-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 01 of 13
-- Core tenancy, identity, sessions, roles/permissions, project-scoped access
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 0. Platform reference data (GLOBAL, not tenant-owned, read-only to tenants)
--    Seeded by migration. Reference tables are the only tables without company_id.
-- -------------------------------------------------------------------------------------
CREATE TABLE public.currencies (
    code          char(3) PRIMARY KEY,             -- ISO 4217
    name_en       text NOT NULL,
    name_ar       text NOT NULL,
    minor_units   smallint NOT NULL DEFAULT 2 CHECK (minor_units BETWEEN 0 AND 4),
    is_active     boolean NOT NULL DEFAULT true
);

CREATE TABLE public.units_of_measure (
    id            uuid PRIMARY KEY,
    code          text NOT NULL,                   -- m, m2, m3, kg, ton, nr, ls, day, month
    name_en       text NOT NULL,
    name_ar       text NOT NULL,
    uom_type      text NOT NULL DEFAULT 'quantity' CHECK (uom_type IN ('quantity','time','lump_sum')),
    decimal_places smallint NOT NULL DEFAULT 3 CHECK (decimal_places BETWEEN 0 AND 6),
    is_active     boolean NOT NULL DEFAULT true,
    CONSTRAINT uq_units_of_measure_code UNIQUE (code)
);

CREATE TABLE public.regions (
    id            uuid PRIMARY KEY,
    country_code  char(2) NOT NULL DEFAULT 'SA',
    name_en       text NOT NULL,
    name_ar       text NOT NULL
);

CREATE TABLE public.cities (
    id            uuid PRIMARY KEY,
    region_id     uuid NOT NULL REFERENCES public.regions(id) ON DELETE RESTRICT,
    name_en       text NOT NULL,
    name_ar       text NOT NULL
);
CREATE INDEX idx_cities_region ON public.cities (region_id);

-- -------------------------------------------------------------------------------------
-- 1. Companies (TENANT ROOT)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.companies (
    id                    uuid PRIMARY KEY,
    legal_name_en         text NOT NULL,
    legal_name_ar         text NOT NULL,
    trade_name_en         text,
    trade_name_ar         text,
    cr_number             text,                     -- commercial registration (data only)
    vat_number            text,                     -- 15-digit KSA VAT registration (format checked)
    national_address      jsonb,                    -- stored as data only; no external validation
    default_currency_code char(3) NOT NULL DEFAULT 'SAR' REFERENCES public.currencies(code),
    timezone              text NOT NULL DEFAULT 'Asia/Riyadh',
    status                text NOT NULL DEFAULT 'active'
                              CHECK (status IN ('provisioning','active','suspended','closed')),
    plan_code             text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid,
    updated_by            uuid,
    deleted_at            timestamptz,
    CONSTRAINT ck_companies_vat_format CHECK (vat_number IS NULL OR vat_number ~ '^3[0-9]{13}3$')
);
COMMENT ON TABLE public.companies IS 'Tenant root. Every tenant-owned table carries company_id and is protected by RLS.';

-- -------------------------------------------------------------------------------------
-- 2. Company settings (typed columns, not free-form, for values the app must reason about)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.company_settings (
    company_id                      uuid PRIMARY KEY REFERENCES public.companies(id) ON DELETE RESTRICT,
    default_vat_rate_bp             integer NOT NULL DEFAULT 1500 CHECK (default_vat_rate_bp BETWEEN 0 AND 10000),
    default_retention_pct           numeric(9,4) NOT NULL DEFAULT 5.0 CHECK (default_retention_pct BETWEEN 0 AND 100),
    default_advance_recovery_pct    numeric(9,4) NOT NULL DEFAULT 0 CHECK (default_advance_recovery_pct BETWEEN 0 AND 100),
    ipc_allow_overcertification     boolean NOT NULL DEFAULT false,
    fiscal_year_start_month         smallint NOT NULL DEFAULT 1 CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
    approval_sod_required           boolean NOT NULL DEFAULT true,   -- submitter cannot approve own document
    audit_retention_months          integer NOT NULL DEFAULT 84,     -- 7 years, owner-confirmable (D-06)
    invoice_numbering_mode          text NOT NULL DEFAULT 'company'
                                       CHECK (invoice_numbering_mode IN ('company','branch')),
    locale_default                  text NOT NULL DEFAULT 'ar' CHECK (locale_default IN ('ar','en')),
    numerals_style                  text NOT NULL DEFAULT 'western'
                                       CHECK (numerals_style IN ('western','arabic_indic')),
    extra                           jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at                      timestamptz NOT NULL DEFAULT now(),
    updated_at                      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN public.company_settings.ipc_allow_overcertification IS
    'When false (default) cumulative certified qty may not exceed BOQ qty + approved VO qty. INV-21.';

-- -------------------------------------------------------------------------------------
-- 3. Branches
-- -------------------------------------------------------------------------------------
CREATE TABLE public.branches (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    code          text NOT NULL,
    name_en       text NOT NULL,
    name_ar       text NOT NULL,
    city_id       uuid,
    is_head_office boolean NOT NULL DEFAULT false,
    status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_by    uuid,
    deleted_at    timestamptz,
    CONSTRAINT uq_branches_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_branches_company_code  UNIQUE (company_id, code)
);
CREATE UNIQUE INDEX uq_branches_one_head_office
    ON public.branches (company_id)
    WHERE is_head_office AND deleted_at IS NULL;
CREATE INDEX idx_branches_company ON public.branches (company_id) WHERE deleted_at IS NULL;

-- -------------------------------------------------------------------------------------
-- 4. Number series (per company, per document type)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.number_series (
    id           uuid PRIMARY KEY,
    company_id   uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    doc_type     text NOT NULL CHECK (doc_type IN ('IPC','VO','EXP','COLL','BOQ','CONTRACT','PROJECT','DOC','BUDGET')),
    prefix       text NOT NULL,
    padding      smallint NOT NULL DEFAULT 4 CHECK (padding BETWEEN 3 AND 10),
    year_mode    text NOT NULL DEFAULT 'yearly' CHECK (year_mode IN ('none','yearly')),
    next_value   bigint NOT NULL DEFAULT 1 CHECK (next_value > 0),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_number_series_company_type UNIQUE (company_id, doc_type)
);

-- -------------------------------------------------------------------------------------
-- 5. Effective-dated tax rates (VAT stays reproducible for historical documents)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.tax_rates (
    id               uuid PRIMARY KEY,
    company_id       uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    tax_code         text NOT NULL DEFAULT 'VAT',
    rate_bp          integer NOT NULL CHECK (rate_bp BETWEEN 0 AND 10000),
    effective_from   date NOT NULL,
    effective_to     date,
    is_default       boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT ck_tax_rates_period CHECK (effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT uq_tax_rates_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_tax_rates_company_code_from UNIQUE (company_id, tax_code, effective_from)
);
COMMENT ON TABLE public.tax_rates IS
    'Effective-dated rates. Documents snapshot the basis points in force at their own date (INV-52).';

-- -------------------------------------------------------------------------------------
-- 6. Users, credentials, MFA  (GLOBAL identity — not tenant-owned)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.users (
    id                 uuid PRIMARY KEY,
    email              citext NOT NULL,
    email_verified_at  timestamptz,
    full_name_en       text,
    full_name_ar       text,
    phone              text,
    preferred_locale   text NOT NULL DEFAULT 'ar' CHECK (preferred_locale IN ('ar','en')),
    preferred_timezone text NOT NULL DEFAULT 'Asia/Riyadh',
    is_active          boolean NOT NULL DEFAULT true,
    is_platform_operator boolean NOT NULL DEFAULT false,  -- internal staff; never a tenant role
    last_login_at      timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz
);
CREATE UNIQUE INDEX uq_users_email_active ON public.users (email) WHERE deleted_at IS NULL;
COMMENT ON COLUMN public.users.is_platform_operator IS
    'Platform staff flag. Grants nothing by itself: all tenant access goes through an audited elevation grant.';

CREATE TABLE public.user_credentials (
    user_id        uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    password_hash  text NOT NULL,                 -- Argon2id encoded string (algorithm embedded)
    algorithm      text NOT NULL DEFAULT 'argon2id',
    password_changed_at timestamptz NOT NULL DEFAULT now(),
    must_change_password boolean NOT NULL DEFAULT false,
    failed_login_count  integer NOT NULL DEFAULT 0,
    locked_until   timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN public.user_credentials.password_hash IS
    'Argon2id via a vetted library (argon2-cffi). Never a custom hash, never reversible, never logged.';

CREATE TABLE public.user_mfa_totp (
    user_id       uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    secret_encrypted bytea NOT NULL,              -- encrypted at rest with an app-level key (KMS/env secret)
    confirmed_at  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.user_mfa_recovery_codes (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    code_hash  text NOT NULL,                     -- one-way hash
    used_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_mfa_recovery_user ON public.user_mfa_recovery_codes (user_id);

-- -------------------------------------------------------------------------------------
-- 7. Memberships (User ↔ Company) and invitations
-- -------------------------------------------------------------------------------------
CREATE TABLE public.memberships (
    id             uuid PRIMARY KEY,
    company_id     uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    user_id        uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    status         text NOT NULL DEFAULT 'invited'
                       CHECK (status IN ('invited','active','suspended','revoked')),
    employee_no    text,
    job_title      text,
    is_company_owner boolean NOT NULL DEFAULT false,
    default_branch_id uuid,
    -- default_branch_id FK is declared with the branch table below (composite, tenant-safe)
    joined_at      timestamptz,
    revoked_at     timestamptz,
    revoked_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid,
    updated_by     uuid,
    CONSTRAINT uq_memberships_company_id_id  UNIQUE (company_id, id),
    CONSTRAINT uq_memberships_company_user   UNIQUE (company_id, user_id),
    CONSTRAINT fk_memberships_default_branch FOREIGN KEY (company_id, default_branch_id)
        REFERENCES public.branches (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_memberships_revoked_coherent
        CHECK ((status = 'revoked') = (revoked_at IS NOT NULL))
);
CREATE INDEX idx_memberships_user    ON public.memberships (user_id) WHERE status = 'active';
CREATE INDEX idx_memberships_company ON public.memberships (company_id, status);

CREATE TABLE public.membership_invitations (
    id             uuid PRIMARY KEY,
    company_id     uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    email          citext NOT NULL,
    invited_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
    invited_by     uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    token_hash     text NOT NULL,                 -- only the hash is stored
    role_ids       uuid[] NOT NULL DEFAULT '{}',
    branch_ids     uuid[] NOT NULL DEFAULT '{}',
    expires_at     timestamptz NOT NULL,
    accepted_at    timestamptz,
    revoked_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_membership_invitations_company_id_id UNIQUE (company_id, id)
);
CREATE INDEX idx_membership_invitations_email ON public.membership_invitations (email) WHERE accepted_at IS NULL;

-- -------------------------------------------------------------------------------------
-- 8. Roles & permissions
--    permissions is a GLOBAL catalogue (code-defined by the application); roles are
--    company-owned copies of templates so a company can tune them without cross-tenant effect.
-- -------------------------------------------------------------------------------------
CREATE TABLE public.permissions (
    code         text PRIMARY KEY,                -- e.g. 'ipc.certify', 'boq.edit'
    scope        text NOT NULL CHECK (scope IN ('company','project')),
    module       text NOT NULL,
    description_en text NOT NULL,
    description_ar text NOT NULL,
    is_sensitive boolean NOT NULL DEFAULT false    -- requires step-up MFA + audit
);
COMMENT ON TABLE public.permissions IS 'Fixed catalogue shipped with the application. Tenants cannot invent permissions.';

CREATE TABLE public.roles (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    code          text NOT NULL,
    name_en       text NOT NULL,
    name_ar       text NOT NULL,
    is_system     boolean NOT NULL DEFAULT false,  -- provisioned template, may be cloned but not deleted
    is_project_role boolean NOT NULL DEFAULT false, -- usable as a project membership template
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_by    uuid,
    deleted_at    timestamptz,
    CONSTRAINT uq_roles_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_roles_company_code  UNIQUE (company_id, code)
);
CREATE INDEX idx_roles_company ON public.roles (company_id) WHERE deleted_at IS NULL;

CREATE TABLE public.role_permissions (
    company_id      uuid NOT NULL,
    role_id         uuid NOT NULL,
    permission_code text NOT NULL REFERENCES public.permissions(code) ON DELETE RESTRICT,
    granted_at      timestamptz NOT NULL DEFAULT now(),
    granted_by      uuid,
    PRIMARY KEY (company_id, role_id, permission_code),
    CONSTRAINT fk_role_permissions_role FOREIGN KEY (company_id, role_id)
        REFERENCES public.roles (company_id, id) ON DELETE CASCADE
);

CREATE TABLE public.membership_roles (
    company_id    uuid NOT NULL,
    membership_id uuid NOT NULL,
    role_id       uuid NOT NULL,
    assigned_at   timestamptz NOT NULL DEFAULT now(),
    assigned_by   uuid,
    PRIMARY KEY (company_id, membership_id, role_id),
    CONSTRAINT fk_membership_roles_membership FOREIGN KEY (company_id, membership_id)
        REFERENCES public.memberships (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_membership_roles_role FOREIGN KEY (company_id, role_id)
        REFERENCES public.roles (company_id, id) ON DELETE RESTRICT
);

CREATE TABLE public.user_branch_scopes (
    company_id    uuid NOT NULL,
    membership_id uuid NOT NULL,
    branch_id     uuid NOT NULL,
    PRIMARY KEY (company_id, membership_id, branch_id),
    CONSTRAINT fk_ubs_membership FOREIGN KEY (company_id, membership_id)
        REFERENCES public.memberships (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_ubs_branch FOREIGN KEY (company_id, branch_id)
        REFERENCES public.branches (company_id, id) ON DELETE CASCADE
);
COMMENT ON TABLE public.user_branch_scopes IS
    'Empty set means company-wide scope. Non-empty restricts the membership to the listed branches.';

-- -------------------------------------------------------------------------------------
-- 9. Sessions (opaque, DB-backed, revocable) — see docs H
-- -------------------------------------------------------------------------------------
CREATE TABLE public.sessions (
    id                  uuid PRIMARY KEY,
    user_id             uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    active_company_id   uuid REFERENCES public.companies(id) ON DELETE SET NULL,
    active_membership_id uuid,
    token_hash          text NOT NULL,            -- sha256 of the cookie value; the raw value is never stored
    csrf_secret_hash    text NOT NULL,
    auth_level          smallint NOT NULL DEFAULT 1 CHECK (auth_level IN (1,2)),  -- 1 = password, 2 = MFA/step-up
    ip_address          inet,
    user_agent          text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    last_seen_at        timestamptz NOT NULL DEFAULT now(),
    absolute_expires_at timestamptz NOT NULL,
    idle_expires_at     timestamptz NOT NULL,
    revoked_at          timestamptz,
    revoked_reason      text,
    CONSTRAINT uq_sessions_token_hash UNIQUE (token_hash),
    CONSTRAINT fk_sessions_active_membership FOREIGN KEY (active_company_id, active_membership_id)
        REFERENCES public.memberships (company_id, id) ON DELETE SET NULL
);
CREATE INDEX idx_sessions_user_active ON public.sessions (user_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_sessions_expiry      ON public.sessions (absolute_expires_at) WHERE revoked_at IS NULL;

CREATE TABLE public.login_attempts (
    id            bigserial PRIMARY KEY,
    user_id       uuid REFERENCES public.users(id) ON DELETE SET NULL,
    email_attempted citext,
    company_hint  uuid,
    succeeded     boolean NOT NULL,
    failure_reason text,
    ip_address    inet,
    user_agent    text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_login_attempts_email_time ON public.login_attempts (email_attempted, created_at DESC);
CREATE INDEX idx_login_attempts_ip_time    ON public.login_attempts (ip_address, created_at DESC);

CREATE TABLE public.password_reset_tokens (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    token_hash text NOT NULL,
    expires_at timestamptz NOT NULL,
    used_at    timestamptz,
    requested_ip inet,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_password_reset_token_hash UNIQUE (token_hash)
);

-- -------------------------------------------------------------------------------------
-- 10. Access delegations (approver on leave) — explicitly bounded and audited
-- -------------------------------------------------------------------------------------
CREATE TABLE public.access_delegations (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL,
    from_membership_id uuid NOT NULL,
    to_membership_id   uuid NOT NULL,
    permission_codes  text[] NOT NULL,
    project_ids       uuid[] NOT NULL DEFAULT '{}',
    valid_from        timestamptz NOT NULL,
    valid_to          timestamptz NOT NULL,
    reason            text NOT NULL,
    created_by        uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    revoked_at        timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_deleg_from FOREIGN KEY (company_id, from_membership_id)
        REFERENCES public.memberships (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_deleg_to FOREIGN KEY (company_id, to_membership_id)
        REFERENCES public.memberships (company_id, id) ON DELETE CASCADE,
    CONSTRAINT ck_deleg_period CHECK (valid_to > valid_from)
);
CREATE INDEX idx_access_delegations_company_from
    ON public.access_delegations (company_id, from_membership_id, valid_to DESC);
CREATE INDEX idx_access_delegations_company_to
    ON public.access_delegations (company_id, to_membership_id) WHERE revoked_at IS NULL;

COMMENT ON TABLE public.access_delegations IS
    'Temporary, explicit, reasoned and audited. Delegation cannot exceed the delegator''s own permissions (checked in the service layer).';
