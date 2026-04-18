-- =============================================================================
-- AutoCDP V2 — Database DDL (Incremental from V1)
-- Aurora PostgreSQL Serverless v2
-- =============================================================================
-- V2 adds: sync_history, crm_writebacks, users, campaign_approvals
-- V2 alters: public.dealers (new columns for aggregator + CRM write-back)
-- V2 updates: provision_dealer_schema() to include new per-dealer tables
-- =============================================================================

-- =============================================================================
-- SECTION 1: V1 BASE (included for completeness — run V1 DDL first)
-- =============================================================================
-- All V1 tables (dealers, compliance_audit_log, set_updated_at trigger,
-- provision_dealer_schema with golden_records, vehicles, propensity_scores,
-- cooldown_ledger, campaign_ledger, qr_scans) must already exist.
-- See v1/database_schema.sql.

-- =============================================================================
-- SECTION 2: ALTER public.dealers — V2 COLUMNS
-- =============================================================================

ALTER TABLE public.dealers
    ADD COLUMN IF NOT EXISTS aggregator_source VARCHAR(50),
    ADD COLUMN IF NOT EXISTS aggregator_config_json JSONB NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS crm_writeback_email VARCHAR(255);

COMMENT ON COLUMN public.dealers.aggregator_source IS
    'Data aggregator vendor: authenticom, motive, manual';
COMMENT ON COLUMN public.dealers.aggregator_config_json IS
    'Aggregator-specific config: extraction schedule, file format preferences';
COMMENT ON COLUMN public.dealers.crm_writeback_email IS
    'CRM ADF XML lead intake email, e.g. leads-dealer104@cdkglobal.com';

-- =============================================================================
-- SECTION 3: NEW PUBLIC SCHEMA TABLES
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.users (
    user_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    cognito_sub     VARCHAR(255)    NOT NULL UNIQUE,
    dealer_id       INTEGER         NOT NULL REFERENCES public.dealers (dealer_id),
    email           VARCHAR(255)    NOT NULL,
    role            VARCHAR(20)     NOT NULL DEFAULT 'viewer',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    last_login_at   TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_users_role CHECK (role IN ('admin', 'manager', 'viewer'))
);

CREATE INDEX idx_users_dealer_id ON public.users (dealer_id);
CREATE INDEX idx_users_email ON public.users (email);

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.campaign_approvals (
    approval_id     UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    dealer_id       INTEGER         NOT NULL REFERENCES public.dealers (dealer_id),
    user_id         UUID            NOT NULL REFERENCES public.users (user_id),
    budget_amount   NUMERIC(12, 2)  NOT NULL CHECK (budget_amount > 0),
    budget_period   VARCHAR(20)     NOT NULL DEFAULT 'monthly',
    mail_pieces_approved INTEGER,
    approved_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ     NOT NULL,
    status          VARCHAR(20)     NOT NULL DEFAULT 'active',

    CONSTRAINT ck_approval_period CHECK (budget_period IN ('monthly', 'campaign')),
    CONSTRAINT ck_approval_status CHECK (status IN ('active', 'expired', 'revoked'))
);

CREATE INDEX idx_approvals_dealer_id ON public.campaign_approvals (dealer_id);
CREATE INDEX idx_approvals_status ON public.campaign_approvals (dealer_id, status);

-- =============================================================================
-- SECTION 4: UPDATED PROVISION FUNCTION — V2 TABLES
-- =============================================================================

CREATE OR REPLACE FUNCTION public.provision_dealer_schema_v2(p_dealer_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema_name VARCHAR(63);
BEGIN
    SELECT schema_name INTO v_schema_name
      FROM public.dealers WHERE dealer_id = p_dealer_id;

    IF v_schema_name IS NULL THEN
        RAISE EXCEPTION 'Dealer % not found', p_dealer_id;
    END IF;

    -- Run V1 provisioning first (idempotent)
    PERFORM public.provision_dealer_schema(p_dealer_id);

    -- sync_history: tracks every nightly aggregator sync
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.sync_history (
            sync_id             UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            source              VARCHAR(50)     NOT NULL,
            file_path           TEXT            NOT NULL,
            file_size_bytes     BIGINT,
            records_received    INTEGER         NOT NULL DEFAULT 0,
            records_processed   INTEGER         NOT NULL DEFAULT 0,
            records_failed      INTEGER         NOT NULL DEFAULT 0,
            records_new         INTEGER         NOT NULL DEFAULT 0,
            records_updated     INTEGER         NOT NULL DEFAULT 0,
            error_log           JSONB,
            started_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            completed_at        TIMESTAMPTZ,
            status              VARCHAR(20)     NOT NULL DEFAULT 'pending',

            CONSTRAINT ck_sync_status CHECK (status IN (
                'pending', 'processing', 'completed', 'failed', 'partial'
            ))
        )
    $tbl$, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_sync_history_status ON %I.sync_history (status)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_sync_history_started ON %I.sync_history (started_at DESC)', v_schema_name);

    -- crm_writebacks: tracks every ADF XML email sent to CRM
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.crm_writebacks (
            writeback_id        UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            campaign_id         UUID            NOT NULL REFERENCES %I.campaign_ledger (campaign_id),
            adf_xml_payload     TEXT            NOT NULL,
            ses_message_id      VARCHAR(100),
            crm_email_target    VARCHAR(255)    NOT NULL,
            sent_at             TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            delivery_status     VARCHAR(20)     NOT NULL DEFAULT 'sent',

            CONSTRAINT ck_writeback_status CHECK (delivery_status IN (
                'sent', 'delivered', 'bounced', 'failed'
            ))
        )
    $tbl$, v_schema_name, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_writebacks_campaign ON %I.crm_writebacks (campaign_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_writebacks_sent ON %I.crm_writebacks (sent_at DESC)', v_schema_name);

    RAISE NOTICE 'V2 schema extensions provisioned for dealer_id %', p_dealer_id;
END;
$$;
