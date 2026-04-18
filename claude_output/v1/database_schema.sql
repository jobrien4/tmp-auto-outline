-- =============================================================================
-- AutoCDP V1 — Full Database DDL
-- Aurora PostgreSQL Serverless v2
-- =============================================================================
-- Conventions:
--   - All primary keys: UUID (gen_random_uuid()) except dealers (SERIAL)
--   - All timestamps: TIMESTAMPTZ, default NOW()
--   - Schema names follow the pattern: dealer_{dealer_id}
--   - Financial fields use NUMERIC for exact arithmetic (no FLOAT)
--   - Indexes named: idx_{table}_{column(s)}
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- SECTION 1: PUBLIC SCHEMA — SYSTEM-WIDE TABLES
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.dealers (
    dealer_id       SERIAL          PRIMARY KEY,
    name            VARCHAR(255)    NOT NULL,
    address_line1   VARCHAR(255)    NOT NULL,
    address_line2   VARCHAR(255),
    city            VARCHAR(100)    NOT NULL,
    state           CHAR(2)         NOT NULL,
    zip             VARCHAR(10)     NOT NULL,
    country         CHAR(2)         NOT NULL DEFAULT 'US',
    schema_name     VARCHAR(63)     NOT NULL UNIQUE,
    crm_type        VARCHAR(64),
    config_json     JSONB           NOT NULL DEFAULT '{}',
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_dealers_state CHECK (state ~ '^[A-Z]{2}$')
);

CREATE INDEX idx_dealers_is_active ON public.dealers (is_active);

CREATE TABLE IF NOT EXISTS public.compliance_audit_log (
    log_id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    dealer_id           INTEGER         NOT NULL REFERENCES public.dealers (dealer_id),
    record_id           UUID            NOT NULL,
    campaign_id         UUID            NOT NULL,
    event_type          VARCHAR(32)     NOT NULL,
    input_payload_json  JSONB           NOT NULL,
    output_payload_json JSONB           NOT NULL,
    result_json         JSONB           NOT NULL,
    llm_provider        VARCHAR(64)     NOT NULL,
    llm_model           VARCHAR(128)    NOT NULL,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_compliance_event_type
        CHECK (event_type IN ('COMPLIANCE_PASS', 'COMPLIANCE_FAIL'))
);

CREATE INDEX idx_compliance_audit_dealer_id   ON public.compliance_audit_log (dealer_id);
CREATE INDEX idx_compliance_audit_campaign_id ON public.compliance_audit_log (campaign_id);
CREATE INDEX idx_compliance_audit_event_type  ON public.compliance_audit_log (event_type);
CREATE INDEX idx_compliance_audit_created_at  ON public.compliance_audit_log (created_at DESC);

-- =============================================================================
-- SECTION 2: UPDATED_AT TRIGGER FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_dealers_updated_at
    BEFORE UPDATE ON public.dealers
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =============================================================================
-- SECTION 3: SCHEMA PROVISIONING FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION public.provision_dealer_schema(p_dealer_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema_name VARCHAR(63);
BEGIN
    SELECT schema_name
      INTO v_schema_name
      FROM public.dealers
     WHERE dealer_id = p_dealer_id;

    IF v_schema_name IS NULL THEN
        RAISE EXCEPTION 'Dealer % not found in public.dealers', p_dealer_id;
    END IF;

    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema_name);

    -- golden_records: one clean, deduplicated record per unique customer
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.golden_records (
            record_id       UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            first_name      VARCHAR(100)    NOT NULL,
            last_name       VARCHAR(100)    NOT NULL,
            email           VARCHAR(320),
            phone           VARCHAR(20),
            address_line1   VARCHAR(255)    NOT NULL,
            address_line2   VARCHAR(255),
            city            VARCHAR(100)    NOT NULL,
            state           CHAR(2)         NOT NULL,
            zip             VARCHAR(10)     NOT NULL,
            country         CHAR(2)         NOT NULL DEFAULT 'US',
            dob             DATE,
            source_hash     VARCHAR(64)     NOT NULL UNIQUE,
            merged_from     JSONB           NOT NULL DEFAULT '[]',
            created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
        )
    $tbl$, v_schema_name);

    EXECUTE format($trig$
        CREATE TRIGGER trg_%s_golden_records_updated_at
            BEFORE UPDATE ON %I.golden_records
            FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()
    $trig$, p_dealer_id, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_golden_records_email ON %I.golden_records (email) WHERE email IS NOT NULL', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_golden_records_last_name ON %I.golden_records (last_name)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_golden_records_state_zip ON %I.golden_records (state, zip)', v_schema_name);

    -- vehicles: ownership and service records linked to golden_records
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.vehicles (
            vehicle_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            record_id           UUID            NOT NULL REFERENCES %I.golden_records (record_id) ON DELETE CASCADE,
            vin                 CHAR(17),
            year                SMALLINT,
            make                VARCHAR(64),
            model               VARCHAR(64),
            trim                VARCHAR(128),
            transaction_type    VARCHAR(16)     NOT NULL,
            transaction_date    DATE,
            lease_start         DATE,
            lease_end           DATE,
            monthly_payment     NUMERIC(10, 2),
            estimated_equity    NUMERIC(10, 2),
            last_service_date   DATE,
            service_count       SMALLINT        NOT NULL DEFAULT 0,
            created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

            CONSTRAINT ck_vehicles_transaction_type CHECK (transaction_type IN ('purchase', 'lease')),
            CONSTRAINT ck_vehicles_vin_format CHECK (vin IS NULL OR vin ~ '^[A-HJ-NPR-Z0-9]{17}$')
        )
    $tbl$, v_schema_name, v_schema_name);

    EXECUTE format($trig$
        CREATE TRIGGER trg_%s_vehicles_updated_at
            BEFORE UPDATE ON %I.vehicles
            FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()
    $trig$, p_dealer_id, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_vehicles_record_id ON %I.vehicles (record_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_vehicles_vin ON %I.vehicles (vin) WHERE vin IS NOT NULL', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_vehicles_lease_end ON %I.vehicles (lease_end) WHERE lease_end IS NOT NULL', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_vehicles_transaction_type_date ON %I.vehicles (transaction_type, transaction_date DESC)', v_schema_name);

    -- propensity_scores: XGBoost scores per record per model version
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.propensity_scores (
            score_id            UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            record_id           UUID            NOT NULL REFERENCES %I.golden_records (record_id) ON DELETE CASCADE,
            model_version       VARCHAR(64)     NOT NULL,
            score               NUMERIC(4, 3)   NOT NULL CHECK (score >= 0 AND score <= 1),
            feature_vector_json JSONB           NOT NULL DEFAULT '{}',
            scored_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW()
        )
    $tbl$, v_schema_name, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_propensity_record_id ON %I.propensity_scores (record_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_propensity_score_desc ON %I.propensity_scores (score DESC)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_propensity_model_score ON %I.propensity_scores (model_version, score DESC)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_propensity_scored_at ON %I.propensity_scores (scored_at DESC)', v_schema_name);

    -- cooldown_ledger: per-customer, per-channel contact cooldown enforcement
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.cooldown_ledger (
            cooldown_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            record_id           UUID            NOT NULL REFERENCES %I.golden_records (record_id) ON DELETE CASCADE,
            channel             VARCHAR(16)     NOT NULL DEFAULT 'mail',
            last_contact_at     TIMESTAMPTZ     NOT NULL,
            cooldown_expires_at TIMESTAMPTZ     NOT NULL,
            created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

            CONSTRAINT uq_cooldown_record_channel UNIQUE (record_id, channel),
            CONSTRAINT ck_cooldown_channel CHECK (channel IN ('mail', 'sms', 'email'))
        )
    $tbl$, v_schema_name, v_schema_name);

    EXECUTE format($trig$
        CREATE TRIGGER trg_%s_cooldown_ledger_updated_at
            BEFORE UPDATE ON %I.cooldown_ledger
            FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()
    $trig$, p_dealer_id, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_cooldown_record_id ON %I.cooldown_ledger (record_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_cooldown_expires ON %I.cooldown_ledger (channel, cooldown_expires_at)', v_schema_name);

    -- campaign_ledger: full lifecycle record for every outbound marketing piece
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.campaign_ledger (
            campaign_id             UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            record_id               UUID            NOT NULL REFERENCES %I.golden_records (record_id) ON DELETE RESTRICT,
            channel                 VARCHAR(16)     NOT NULL DEFAULT 'mail',
            status                  VARCHAR(32)     NOT NULL DEFAULT 'queued',
            lob_tracking_id         UUID,
            copy_payload_json       JSONB,
            compliance_result_json  JSONB,
            offer_apr               NUMERIC(5, 3),
            offer_monthly_payment   NUMERIC(10, 2),
            offer_term              SMALLINT,
            created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            generated_at            TIMESTAMPTZ,
            compliance_checked_at   TIMESTAMPTZ,
            dispatched_at           TIMESTAMPTZ,
            delivered_at            TIMESTAMPTZ,
            scanned_at              TIMESTAMPTZ,
            converted_at            TIMESTAMPTZ,
            updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

            CONSTRAINT ck_campaign_channel CHECK (channel IN ('mail', 'sms', 'email')),
            CONSTRAINT ck_campaign_status CHECK (status IN (
                'queued', 'generated', 'compliance_passed', 'compliance_failed',
                'dispatched', 'delivered', 'scanned', 'converted'
            )),
            CONSTRAINT ck_campaign_apr_positive CHECK (offer_apr IS NULL OR offer_apr > 0),
            CONSTRAINT ck_campaign_payment_positive CHECK (offer_monthly_payment IS NULL OR offer_monthly_payment > 0),
            CONSTRAINT ck_campaign_term_positive CHECK (offer_term IS NULL OR offer_term > 0)
        )
    $tbl$, v_schema_name, v_schema_name);

    EXECUTE format($trig$
        CREATE TRIGGER trg_%s_campaign_ledger_updated_at
            BEFORE UPDATE ON %I.campaign_ledger
            FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()
    $trig$, p_dealer_id, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_campaign_record_id ON %I.campaign_ledger (record_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_campaign_status ON %I.campaign_ledger (status)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_campaign_lob_tracking ON %I.campaign_ledger (lob_tracking_id) WHERE lob_tracking_id IS NOT NULL', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_campaign_created_at ON %I.campaign_ledger (created_at DESC)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_campaign_channel_status ON %I.campaign_ledger (channel, status)', v_schema_name);

    -- qr_scans: attribution event log for every QR code scan
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.qr_scans (
            scan_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            campaign_id     UUID            NOT NULL REFERENCES %I.campaign_ledger (campaign_id) ON DELETE RESTRICT,
            scanned_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            ip_address      INET,
            user_agent      TEXT,
            redirect_url    TEXT            NOT NULL
        )
    $tbl$, v_schema_name, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_qr_scans_campaign_id ON %I.qr_scans (campaign_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_qr_scans_scanned_at ON %I.qr_scans (scanned_at DESC)', v_schema_name);

    RAISE NOTICE 'Schema % provisioned successfully for dealer_id %', v_schema_name, p_dealer_id;
END;
$$;

-- =============================================================================
-- EXAMPLE INVOCATION
-- =============================================================================
-- INSERT INTO public.dealers
--     (name, address_line1, city, state, zip, schema_name, crm_type, config_json)
-- VALUES
--     ('Acme Motors', '123 Main St', 'Springfield', 'IL', '62701',
--      'dealer_1', 'generic_csv',
--      '{"score_threshold": 0.70, "cooldown_days_mail": 45,
--        "inventory_redirect_base_url": "https://acmemotors.com/inventory"}');
--
-- SELECT public.provision_dealer_schema(1);
