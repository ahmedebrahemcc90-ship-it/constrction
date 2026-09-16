-- =====================================================================================
-- PHASE 0 SPECIFICATION — NOT A MIGRATION — file 02 of 13
-- Partners (clients / suppliers / subcontractors) and Projects
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Party masters — one table per party kind so FKs stay strongly typed.
--    Shared shape, deliberate duplication (a unified `parties` VIEW is provided for search).
-- -------------------------------------------------------------------------------------
CREATE TABLE public.clients (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    code               text NOT NULL,
    name_en            text NOT NULL,
    name_ar            text NOT NULL,
    legal_name_en      text,
    legal_name_ar      text,
    cr_number          text,
    vat_number         text,
    national_address   jsonb,
    contact_email      citext,
    contact_phone      text,
    payment_terms_days integer CHECK (payment_terms_days BETWEEN 0 AND 365),
    default_retention_pct numeric(9,4) CHECK (default_retention_pct BETWEEN 0 AND 100),
    status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','blacklisted')),
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_by         uuid,
    deleted_at         timestamptz,
    CONSTRAINT uq_clients_company_id_id UNIQUE (company_id, id),
    CONSTRAINT ck_clients_vat_format CHECK (vat_number IS NULL OR vat_number ~ '^3[0-9]{13}3$')
);
CREATE UNIQUE INDEX uq_clients_company_code ON public.clients (company_id, code) WHERE deleted_at IS NULL;
CREATE INDEX idx_clients_name_trgm ON public.clients USING gin (name_en gin_trgm_ops, name_ar gin_trgm_ops);

CREATE TABLE public.suppliers (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    code               text NOT NULL,
    name_en            text NOT NULL,
    name_ar            text NOT NULL,
    cr_number          text,
    vat_number         text,
    category           text,                       -- materials / services / rental (free text in V1)
    contact_email      citext,
    contact_phone      text,
    payment_terms_days integer CHECK (payment_terms_days BETWEEN 0 AND 365),
    bank_details       jsonb,                      -- sensitive: encrypted-at-rest volume + audit on read (docs L)
    status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','blacklisted')),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_by         uuid,
    deleted_at         timestamptz,
    CONSTRAINT uq_suppliers_company_id_id UNIQUE (company_id, id),
    CONSTRAINT ck_suppliers_vat_format CHECK (vat_number IS NULL OR vat_number ~ '^3[0-9]{13}3$')
);
CREATE UNIQUE INDEX uq_suppliers_company_code ON public.suppliers (company_id, code) WHERE deleted_at IS NULL;

CREATE TABLE public.subcontractors (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    code               text NOT NULL,
    name_en            text NOT NULL,
    name_ar            text NOT NULL,
    cr_number          text,
    vat_number         text,
    specialty          text,
    classification     text,                       -- e.g. contractor classification grade (data only)
    contact_email      citext,
    contact_phone      text,
    status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','blacklisted')),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_by         uuid,
    deleted_at         timestamptz,
    CONSTRAINT uq_subcontractors_company_id_id UNIQUE (company_id, id)
);
CREATE UNIQUE INDEX uq_subcontractors_company_code ON public.subcontractors (company_id, code) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.subcontractors IS
    'V1: party master only. Subcontracts and subcontractor IPC are explicitly OUT of V1 scope.';

-- Contacts use the same polymorphic-with-integrity pattern as project_parties.
CREATE TABLE public.party_contacts (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    client_id          uuid,
    supplier_id        uuid,
    subcontractor_id   uuid,
    party_kind         text GENERATED ALWAYS AS (
                           CASE WHEN client_id        IS NOT NULL THEN 'client'
                                WHEN supplier_id      IS NOT NULL THEN 'supplier'
                                WHEN subcontractor_id IS NOT NULL THEN 'subcontractor'
                           END
                       ) STORED,
    name               text NOT NULL,
    job_title          text,
    email              citext,
    phone              text,
    is_primary         boolean NOT NULL DEFAULT false,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz,
    CONSTRAINT fk_party_contacts_client FOREIGN KEY (company_id, client_id)
        REFERENCES public.clients (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_party_contacts_supplier FOREIGN KEY (company_id, supplier_id)
        REFERENCES public.suppliers (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_party_contacts_subcontractor FOREIGN KEY (company_id, subcontractor_id)
        REFERENCES public.subcontractors (company_id, id) ON DELETE CASCADE,
    CONSTRAINT ck_party_contacts_exactly_one
        CHECK (num_nonnulls(client_id, supplier_id, subcontractor_id) = 1),
    CONSTRAINT ck_party_contacts_has_reach
        CHECK (email IS NOT NULL OR phone IS NOT NULL)
);
CREATE INDEX idx_party_contacts_client        ON public.party_contacts (company_id, client_id)        WHERE deleted_at IS NULL;
CREATE INDEX idx_party_contacts_supplier      ON public.party_contacts (company_id, supplier_id)      WHERE deleted_at IS NULL;
CREATE INDEX idx_party_contacts_subcontractor ON public.party_contacts (company_id, subcontractor_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uq_party_contacts_one_primary
    ON public.party_contacts (company_id, party_kind, coalesce(client_id, supplier_id, subcontractor_id))
    WHERE is_primary AND deleted_at IS NULL;

-- -------------------------------------------------------------------------------------
-- 2. Projects
-- -------------------------------------------------------------------------------------
CREATE TABLE public.projects (
    id                uuid PRIMARY KEY,
    company_id        uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    branch_id         uuid,
    code              text NOT NULL,
    name_en           text NOT NULL,
    name_ar           text NOT NULL,
    client_id         uuid,                        -- convenience pointer to the primary client
    project_type      text,                        -- building / road / infrastructure / mep / other
    location_city_id  uuid,
    latitude          numeric(9,6),
    longitude         numeric(9,6),
    start_date        date,
    planned_end_date  date,
    actual_end_date   date,
    status            text NOT NULL DEFAULT 'draft'
                          CHECK (status IN ('draft','active','on_hold','substantially_completed','closed','cancelled')),
    is_confidential   boolean NOT NULL DEFAULT false,  -- hides commercial data from non-project roles
    description       text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid,
    updated_by        uuid,
    deleted_at        timestamptz,
    version           integer NOT NULL DEFAULT 1,
    CONSTRAINT uq_projects_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_projects_branch FOREIGN KEY (company_id, branch_id)
        REFERENCES public.branches (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_projects_client FOREIGN KEY (company_id, client_id)
        REFERENCES public.clients (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_projects_dates CHECK (planned_end_date IS NULL OR start_date IS NULL OR planned_end_date >= start_date)
);
CREATE UNIQUE INDEX uq_projects_company_code ON public.projects (company_id, code) WHERE deleted_at IS NULL;
CREATE INDEX idx_projects_company_status ON public.projects (company_id, status, created_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE public.project_settings (
    project_id                 uuid PRIMARY KEY REFERENCES public.projects(id) ON DELETE CASCADE,
    company_id                 uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    default_currency_code      char(3) NOT NULL DEFAULT 'SAR' REFERENCES public.currencies(code),
    vat_rate_bp_override       integer CHECK (vat_rate_bp_override BETWEEN 0 AND 10000),
    retention_pct_override     numeric(9,4) CHECK (retention_pct_override BETWEEN 0 AND 100),
    measurement_period_anchor  date,               -- e.g. 25th of each month
    allow_expense_without_wbs  boolean NOT NULL DEFAULT true,
    extra                      jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at                 timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_settings_company_id_id UNIQUE (company_id, project_id),
    CONSTRAINT fk_project_settings_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE CASCADE
);

-- Polymorphic-with-integrity pattern (used for every "link to one of N typed parents" case;
-- also in document_links and approval_requests):
--   * ONE nullable typed FK column per possible parent, each a real composite FK;
--   * a CHECK that exactly one of them is populated (num_nonnulls = 1);
--   * a GENERATED column deriving the type, so type and id can never disagree.
-- This is preferred over a bare (kind, id) pair because the database itself then guarantees
-- the referenced row exists and belongs to the same company.
CREATE TABLE public.project_parties (
    id                 uuid PRIMARY KEY,
    company_id         uuid NOT NULL,
    project_id         uuid NOT NULL,
    relationship       text,                       -- e.g. 'main_client', 'material_supplier'
    is_primary         boolean NOT NULL DEFAULT false,
    client_id          uuid,
    supplier_id        uuid,
    subcontractor_id   uuid,
    party_kind         text GENERATED ALWAYS AS (
                           CASE WHEN client_id        IS NOT NULL THEN 'client'
                                WHEN supplier_id      IS NOT NULL THEN 'supplier'
                                WHEN subcontractor_id IS NOT NULL THEN 'subcontractor'
                           END
                       ) STORED,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    CONSTRAINT fk_project_parties_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_project_parties_client FOREIGN KEY (company_id, client_id)
        REFERENCES public.clients (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_parties_supplier FOREIGN KEY (company_id, supplier_id)
        REFERENCES public.suppliers (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_parties_subcontractor FOREIGN KEY (company_id, subcontractor_id)
        REFERENCES public.subcontractors (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_project_parties_exactly_one
        CHECK (num_nonnulls(client_id, supplier_id, subcontractor_id) = 1)
);
COMMENT ON TABLE public.project_parties IS
    'Linking a company-level party to a project is explicit. Party masters never imply project access on their own.';
CREATE UNIQUE INDEX uq_project_parties_unique
    ON public.project_parties (company_id, project_id, party_kind,
                               coalesce(client_id, supplier_id, subcontractor_id));
CREATE INDEX idx_project_parties_client        ON public.project_parties (company_id, client_id)        WHERE client_id        IS NOT NULL;
CREATE INDEX idx_project_parties_supplier      ON public.project_parties (company_id, supplier_id)      WHERE supplier_id      IS NOT NULL;
CREATE INDEX idx_project_parties_subcontractor ON public.project_parties (company_id, subcontractor_id) WHERE subcontractor_id IS NOT NULL;

CREATE TABLE public.project_milestones (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL,
    project_id    uuid NOT NULL,
    code          text NOT NULL,
    name_en       text NOT NULL,
    name_ar       text NOT NULL,
    planned_date  date NOT NULL,
    actual_date   date,
    weight_pct    numeric(9,4) CHECK (weight_pct BETWEEN 0 AND 100),
    linked_ipc_id uuid,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_milestones_company_id_id UNIQUE (company_id, id),
    CONSTRAINT fk_project_milestones_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE CASCADE
);

CREATE TABLE public.project_status_history (
    id            uuid PRIMARY KEY,
    company_id    uuid NOT NULL,
    project_id    uuid NOT NULL,
    from_status   text,
    to_status     text NOT NULL,
    reason        text,
    changed_by    uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    changed_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_psh_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE CASCADE
);
CREATE INDEX idx_psh_project_time ON public.project_status_history (company_id, project_id, changed_at DESC);

-- -------------------------------------------------------------------------------------
-- 3. Project-level access (moved here: depends on projects)
-- -------------------------------------------------------------------------------------
CREATE TABLE public.project_members (
    id             uuid PRIMARY KEY,
    company_id     uuid NOT NULL,
    project_id     uuid NOT NULL,
    membership_id  uuid NOT NULL,
    is_project_admin boolean NOT NULL DEFAULT false,
    role_id        uuid,                       -- optional template role applied at project scope
    assigned_at    timestamptz NOT NULL DEFAULT now(),
    assigned_by    uuid REFERENCES public.users(id) ON DELETE RESTRICT,
    expires_at     timestamptz,                -- time-boxed access (temporary site staff)
    revoked_at     timestamptz,
    revoked_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_members_company_id_id UNIQUE (company_id, id),
    CONSTRAINT uq_project_members_unique UNIQUE (company_id, project_id, membership_id),
    CONSTRAINT fk_project_members_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_project_members_membership FOREIGN KEY (company_id, membership_id)
        REFERENCES public.memberships (company_id, id) ON DELETE CASCADE,
    CONSTRAINT fk_project_members_role FOREIGN KEY (company_id, role_id)
        REFERENCES public.roles (company_id, id) ON DELETE RESTRICT,
    CONSTRAINT ck_project_members_expiry CHECK (expires_at IS NULL OR expires_at > assigned_at)
);
CREATE INDEX idx_project_members_membership ON public.project_members (company_id, membership_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_project_members_project    ON public.project_members (company_id, project_id)    WHERE revoked_at IS NULL;

CREATE TABLE public.project_member_permissions (
    company_id        uuid NOT NULL,
    project_member_id uuid NOT NULL,
    permission_code   text NOT NULL REFERENCES public.permissions(code) ON DELETE RESTRICT,
    granted_at        timestamptz NOT NULL DEFAULT now(),
    granted_by        uuid,
    PRIMARY KEY (company_id, project_member_id, permission_code),
    CONSTRAINT fk_pmp_project_member FOREIGN KEY (company_id, project_member_id)
        REFERENCES public.project_members (company_id, id) ON DELETE CASCADE
);
COMMENT ON TABLE public.project_member_permissions IS
    'Project-scoped grants. Object-level enforcement happens in the application, and every query is additionally filtered by these grants (docs G §4).';

