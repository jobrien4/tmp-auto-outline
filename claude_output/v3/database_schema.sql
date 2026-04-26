-- =============================================================================
-- AutoCDP V3 — Database DDL (Incremental from V2)
-- Aurora PostgreSQL + Snowflake
-- =============================================================================
-- V3 adds: channel_routing_log, model_versions, dealer_groups
-- V3 alters: campaign_ledger (twilio_sid, sendgrid_id, channel_cost)
-- V3 adds: Snowflake analytical tables
-- =============================================================================

-- Run V1 + V2 DDL first. See v1/database_schema.sql and v2/database_schema.sql.

-- =============================================================================
-- SECTION 1: NEW PUBLIC SCHEMA TABLES (Aurora)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.model_versions (
    version_id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    model_type                  VARCHAR(20)     NOT NULL,
    s3_artifact_path            TEXT            NOT NULL,
    training_dataset_range_start DATE           NOT NULL,
    training_dataset_range_end  DATE            NOT NULL,
    training_row_count          BIGINT          NOT NULL,
    metrics_json                JSONB           NOT NULL,
    deployed_at                 TIMESTAMPTZ,
    retired_at                  TIMESTAMPTZ,
    is_active                   BOOLEAN         NOT NULL DEFAULT FALSE,
    deployed_by                 VARCHAR(50)     NOT NULL DEFAULT 'auto',
    created_at                  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_model_type CHECK (model_type IN ('xgboost', 'lightgbm')),
    CONSTRAINT ck_model_deployed_by CHECK (deployed_by IN ('auto', 'manual', 'rejected'))
);

CREATE INDEX idx_model_versions_active ON public.model_versions (is_active) WHERE is_active = TRUE;
CREATE INDEX idx_model_versions_created ON public.model_versions (created_at DESC);

CREATE TABLE IF NOT EXISTS public.dealer_groups (
    group_id        SERIAL          PRIMARY KEY,
    name            VARCHAR(255)    NOT NULL,
    config_json     JSONB           NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_dealer_groups_updated_at
    BEFORE UPDATE ON public.dealer_groups
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.dealer_group_members (
    group_id        INTEGER         NOT NULL REFERENCES public.dealer_groups (group_id),
    dealer_id       INTEGER         NOT NULL REFERENCES public.dealers (dealer_id),
    PRIMARY KEY (group_id, dealer_id)
);

CREATE INDEX idx_group_members_dealer ON public.dealer_group_members (dealer_id);

-- Add group_admin role to users
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS ck_users_role;
ALTER TABLE public.users
    ADD CONSTRAINT ck_users_role CHECK (role IN ('admin', 'manager', 'viewer', 'group_admin'));

-- =============================================================================
-- SECTION 2: ALTER CAMPAIGN_LEDGER — V3 COLUMNS
-- =============================================================================
-- These ALTER statements must be run against EACH dealer schema.
-- The provision function below handles new dealers automatically.

-- For existing dealer schemas, run this migration:
-- DO $$
-- DECLARE r RECORD;
-- BEGIN
--   FOR r IN SELECT schema_name FROM public.dealers WHERE is_active = TRUE LOOP
--     EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS twilio_sid VARCHAR(100)', r.schema_name);
--     EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS sendgrid_id VARCHAR(100)', r.schema_name);
--     EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS channel_cost NUMERIC(8,4)', r.schema_name);
--   END LOOP;
-- END $$;

-- =============================================================================
-- SECTION 3: UPDATED PROVISION FUNCTION — V3 TABLES
-- =============================================================================

CREATE OR REPLACE FUNCTION public.provision_dealer_schema_v3(p_dealer_id INTEGER)
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

    -- Run V2 provisioning first (includes V1, idempotent)
    PERFORM public.provision_dealer_schema_v2(p_dealer_id);

    -- Add V3 columns to campaign_ledger
    EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS twilio_sid VARCHAR(100)', v_schema_name);
    EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS sendgrid_id VARCHAR(100)', v_schema_name);
    EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS channel_cost NUMERIC(8,4)', v_schema_name);

    -- channel_routing_log: records every routing decision
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.channel_routing_log (
            routing_id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            record_id               UUID            NOT NULL REFERENCES %I.golden_records (record_id),
            campaign_id             UUID            REFERENCES %I.campaign_ledger (campaign_id),
            evaluated_channels_json JSONB           NOT NULL,
            selected_channel        VARCHAR(16)     NOT NULL,
            selection_reason        TEXT            NOT NULL,
            cost_estimate           NUMERIC(8, 4)   NOT NULL,
            created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

            CONSTRAINT ck_routing_channel CHECK (selected_channel IN ('mail', 'sms', 'email'))
        )
    $tbl$, v_schema_name, v_schema_name, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_routing_record ON %I.channel_routing_log (record_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_routing_campaign ON %I.channel_routing_log (campaign_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_routing_channel ON %I.channel_routing_log (selected_channel)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_routing_created ON %I.channel_routing_log (created_at DESC)', v_schema_name);

    RAISE NOTICE 'V3 schema extensions provisioned for dealer_id %', p_dealer_id;
END;
$$;

-- =============================================================================
-- SECTION 4: SNOWFLAKE ANALYTICAL TABLES
-- =============================================================================
-- These are created in Snowflake, not Aurora.
-- Included here for completeness.
-- Snowflake reads from S3 data lake via external tables.

-- Snowflake DDL:

-- CREATE DATABASE IF NOT EXISTS autocdp_analytics;
-- CREATE SCHEMA IF NOT EXISTS autocdp_analytics.analytics;

-- External stage pointing to S3 data lake
-- CREATE OR REPLACE STAGE autocdp_analytics.analytics.s3_lake
--   URL = 's3://autocdp-data-lake/'
--   STORAGE_INTEGRATION = autocdp_s3_integration
--   FILE_FORMAT = (TYPE = 'PARQUET');

-- Campaign performance: cross-dealer campaign metrics
-- CREATE OR REPLACE TABLE autocdp_analytics.analytics.campaign_performance AS
-- SELECT
--     cl.dealer_id,
--     cl.campaign_id,
--     cl.record_id,
--     cl.channel,
--     cl.status,
--     cl.offer_apr,
--     cl.offer_monthly_payment,
--     cl.channel_cost,
--     cl.created_at,
--     cl.dispatched_at,
--     cl.scanned_at,
--     cl.converted_at,
--     DATEDIFF('day', cl.dispatched_at, cl.scanned_at) AS days_to_scan,
--     DATEDIFF('day', cl.dispatched_at, cl.converted_at) AS days_to_convert
-- FROM s3_lake_campaigns cl;

-- Channel ROI: cost-per-conversion by channel, dealer, period
-- CREATE OR REPLACE VIEW autocdp_analytics.analytics.channel_roi AS
-- SELECT
--     dealer_id,
--     channel,
--     DATE_TRUNC('month', created_at) AS month,
--     COUNT(*) AS campaigns_sent,
--     SUM(CASE WHEN status = 'converted' THEN 1 ELSE 0 END) AS conversions,
--     SUM(channel_cost) AS total_cost,
--     CASE WHEN SUM(CASE WHEN status = 'converted' THEN 1 ELSE 0 END) > 0
--         THEN SUM(channel_cost) / SUM(CASE WHEN status = 'converted' THEN 1 ELSE 0 END)
--         ELSE NULL END AS cost_per_conversion,
--     SUM(CASE WHEN status = 'converted' THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS conversion_rate
-- FROM autocdp_analytics.analytics.campaign_performance
-- GROUP BY dealer_id, channel, DATE_TRUNC('month', created_at);

-- Model accuracy: prediction vs actual, by model version
-- CREATE OR REPLACE VIEW autocdp_analytics.analytics.model_accuracy AS
-- SELECT
--     ps.model_version,
--     DATE_TRUNC('month', ps.scored_at) AS month,
--     COUNT(*) AS records_scored,
--     AVG(ps.score) AS avg_predicted_score,
--     SUM(CASE WHEN cl.status = 'converted' THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS actual_conversion_rate,
--     SUM(CASE WHEN ps.score > 0.70 AND cl.status = 'converted' THEN 1 ELSE 0 END)::FLOAT /
--         NULLIF(SUM(CASE WHEN ps.score > 0.70 THEN 1 ELSE 0 END), 0) AS precision_at_70
-- FROM s3_lake_propensity_scores ps
-- LEFT JOIN s3_lake_campaigns cl ON cl.record_id = ps.record_id
-- GROUP BY ps.model_version, DATE_TRUNC('month', ps.scored_at);

-- Dealer summary: high-level KPIs per dealer for group CEO
-- CREATE OR REPLACE VIEW autocdp_analytics.analytics.dealer_summary AS
-- SELECT
--     d.dealer_id,
--     d.group_id,
--     d.name AS dealer_name,
--     COUNT(DISTINCT gr.record_id) AS total_customers,
--     COUNT(cl.campaign_id) AS total_campaigns,
--     SUM(CASE WHEN cl.status = 'converted' THEN 1 ELSE 0 END) AS total_conversions,
--     SUM(cl.channel_cost) AS total_spend,
--     SUM(CASE WHEN cl.status = 'converted' THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(cl.campaign_id), 0) AS conversion_rate
-- FROM s3_lake_dealers d
-- LEFT JOIN s3_lake_golden_records gr ON gr.dealer_id = d.dealer_id
-- LEFT JOIN s3_lake_campaigns cl ON cl.dealer_id = d.dealer_id
-- GROUP BY d.dealer_id, d.group_id, d.name;
