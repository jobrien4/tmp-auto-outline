-- =============================================================================
-- AutoCDP V4 — Database DDL (Incremental from V3)
-- Aurora PostgreSQL + Neptune + Redis + Kafka
-- =============================================================================
-- V4 adds: intent_events, inventory_snapshot, inventory_match_log,
--          attribution_events, identity_graph_links (Aurora mirror)
-- V4 alters: campaign_ledger (trigger_type, matched_vin, latency_ms)
--            dealers (pixel_site_id, dms_feed_id)
-- V4 adds: Snowflake V4 analytical views
-- =============================================================================

-- Run V1 + V2 + V3 DDL first.

-- =============================================================================
-- SECTION 1: ALTER PUBLIC TABLES (Aurora)
-- =============================================================================

-- Add pixel and inventory feed identifiers to dealers
ALTER TABLE public.dealers
    ADD COLUMN IF NOT EXISTS pixel_site_id VARCHAR(64),
    ADD COLUMN IF NOT EXISTS dms_feed_id VARCHAR(64),
    ADD COLUMN IF NOT EXISTS realtime_enabled BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_dealers_pixel ON public.dealers (pixel_site_id) WHERE pixel_site_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dealers_realtime ON public.dealers (realtime_enabled) WHERE realtime_enabled = TRUE;

-- =============================================================================
-- SECTION 2: NEW PUBLIC SCHEMA TABLES (Aurora)
-- =============================================================================

-- Real-time pipeline execution log (cross-dealer)
CREATE TABLE IF NOT EXISTS public.realtime_pipeline_log (
    pipeline_run_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    dealer_id               INTEGER         NOT NULL REFERENCES public.dealers (dealer_id),
    event_id                UUID            NOT NULL,
    record_id               UUID,
    identity_confidence     NUMERIC(4, 3),
    matched_vin             VARCHAR(17),
    campaign_id             UUID,
    total_latency_ms        INTEGER         NOT NULL,
    stage_latencies_json    JSONB           NOT NULL,
    outcome                 VARCHAR(30)     NOT NULL,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_rt_outcome CHECK (outcome IN (
        'dispatched', 'identity_failed', 'no_inventory_match',
        'compliance_failed', 'cooldown_blocked', 'below_intent_threshold'
    ))
);

CREATE INDEX idx_rt_pipeline_dealer ON public.realtime_pipeline_log (dealer_id, created_at DESC);
CREATE INDEX idx_rt_pipeline_outcome ON public.realtime_pipeline_log (outcome);

-- =============================================================================
-- SECTION 3: UPDATED PROVISION FUNCTION — V4 TABLES
-- =============================================================================

CREATE OR REPLACE FUNCTION public.provision_dealer_schema_v4(p_dealer_id INTEGER)
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

    -- Run V3 provisioning first (includes V1+V2, idempotent)
    PERFORM public.provision_dealer_schema_v3(p_dealer_id);

    -- Add V4 columns to campaign_ledger
    EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS trigger_type VARCHAR(20) NOT NULL DEFAULT ''batch''', v_schema_name);
    EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS matched_vin VARCHAR(17)', v_schema_name);
    EXECUTE format('ALTER TABLE %I.campaign_ledger ADD COLUMN IF NOT EXISTS latency_ms INTEGER', v_schema_name);

    EXECUTE format($ck$
        ALTER TABLE %I.campaign_ledger
            DROP CONSTRAINT IF EXISTS ck_campaign_trigger_type
    $ck$, v_schema_name);
    EXECUTE format($ck$
        ALTER TABLE %I.campaign_ledger
            ADD CONSTRAINT ck_campaign_trigger_type CHECK (trigger_type IN ('batch', 'realtime'))
    $ck$, v_schema_name);

    -- intent_events: website/pixel events linked to identified customers
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.intent_events (
            event_id                UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            record_id               UUID            REFERENCES %I.golden_records (record_id),
            event_type              VARCHAR(30)     NOT NULL,
            event_data              JSONB           NOT NULL DEFAULT '{}',
            intent_score            NUMERIC(5, 4),
            source_cookie           VARCHAR(128),
            source_fingerprint      VARCHAR(128),
            identity_confidence     NUMERIC(4, 3),
            event_at                TIMESTAMPTZ     NOT NULL,
            created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

            CONSTRAINT ck_intent_event_type CHECK (event_type IN (
                'page_view', 'vdp_view', 'payment_calc', 'trade_in_submit',
                'chat_start', 'form_submit', 'phone_click'
            ))
        )
    $tbl$, v_schema_name, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_intent_record ON %I.intent_events (record_id, event_at DESC)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_intent_type ON %I.intent_events (event_type, event_at DESC)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_intent_score ON %I.intent_events (intent_score DESC) WHERE intent_score IS NOT NULL', v_schema_name);

    -- Partition intent_events by month for efficient cleanup
    -- (In production, this would be a partitioned table. Shown as index + policy here.)

    -- inventory_snapshot: current vehicle inventory for this dealer
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.inventory_snapshot (
            vin                     VARCHAR(17)     PRIMARY KEY,
            make                    VARCHAR(50)     NOT NULL,
            model                   VARCHAR(100)    NOT NULL,
            trim                    VARCHAR(100),
            model_year              SMALLINT        NOT NULL,
            msrp                    NUMERIC(10, 2)  NOT NULL,
            invoice                 NUMERIC(10, 2),
            days_on_lot             INTEGER         NOT NULL DEFAULT 0,
            status                  VARCHAR(20)     NOT NULL DEFAULT 'available',
            segment                 VARCHAR(30),
            incentives_json         JSONB           NOT NULL DEFAULT '[]',
            money_factors_json      JSONB           NOT NULL DEFAULT '{}',
            residual_24mo           NUMERIC(4, 3),
            residual_36mo           NUMERIC(4, 3),
            residual_48mo           NUMERIC(4, 3),
            last_synced_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

            CONSTRAINT ck_inv_status CHECK (status IN ('available', 'hold', 'sold', 'in_transit')),
            CONSTRAINT ck_inv_segment CHECK (segment IN ('truck', 'sedan', 'suv', 'van', 'coupe', 'ev', 'hybrid', 'other'))
        )
    $tbl$, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_inv_status ON %I.inventory_snapshot (status) WHERE status = ''available''', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_inv_segment ON %I.inventory_snapshot (segment, days_on_lot DESC)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_inv_days ON %I.inventory_snapshot (days_on_lot DESC)', v_schema_name);

    -- inventory_match_log: records every vehicle matching decision
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.inventory_match_log (
            match_id                UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            campaign_id             UUID            REFERENCES %I.campaign_ledger (campaign_id),
            record_id               UUID            NOT NULL REFERENCES %I.golden_records (record_id),
            matched_vin             VARCHAR(17)     NOT NULL,
            candidates_evaluated    INTEGER         NOT NULL,
            candidates_json         JSONB           NOT NULL,
            offered_payment         NUMERIC(8, 2)   NOT NULL,
            offered_term            SMALLINT        NOT NULL,
            offered_down            NUMERIC(8, 2)   NOT NULL DEFAULT 0,
            customer_equity         NUMERIC(10, 2),
            customer_credit_tier    VARCHAR(5),
            match_score             NUMERIC(5, 4)   NOT NULL,
            match_latency_ms        INTEGER,
            created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
        )
    $tbl$, v_schema_name, v_schema_name, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_inv_match_campaign ON %I.inventory_match_log (campaign_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_inv_match_record ON %I.inventory_match_log (record_id, created_at DESC)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_inv_match_vin ON %I.inventory_match_log (matched_vin)', v_schema_name);

    -- attribution_events: full journey tracking from pixel to sale
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.attribution_events (
            attribution_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            campaign_id             UUID            REFERENCES %I.campaign_ledger (campaign_id),
            record_id               UUID            NOT NULL REFERENCES %I.golden_records (record_id),
            event_type              VARCHAR(30)     NOT NULL,
            event_data              JSONB           NOT NULL DEFAULT '{}',
            event_at                TIMESTAMPTZ     NOT NULL,
            created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

            CONSTRAINT ck_attr_event_type CHECK (event_type IN (
                'pixel_view', 'identity_resolved', 'offer_generated',
                'offer_dispatched', 'offer_delivered', 'offer_opened',
                'offer_clicked', 'qr_scanned', 'test_drive_scheduled',
                'deal_started', 'deal_closed', 'deal_lost'
            ))
        )
    $tbl$, v_schema_name, v_schema_name, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_attr_campaign ON %I.attribution_events (campaign_id, event_at)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_attr_record ON %I.attribution_events (record_id, event_at)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_attr_type ON %I.attribution_events (event_type, event_at DESC)', v_schema_name);

    -- identity_graph_links: Aurora mirror of Neptune edges for reporting
    EXECUTE format($tbl$
        CREATE TABLE IF NOT EXISTS %I.identity_graph_links (
            link_id                 UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
            record_id               UUID            NOT NULL REFERENCES %I.golden_records (record_id),
            identifier_type         VARCHAR(20)     NOT NULL,
            identifier_hash         VARCHAR(128)    NOT NULL,
            confidence              NUMERIC(4, 3)   NOT NULL,
            first_seen_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
            last_seen_at            TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

            CONSTRAINT ck_id_type CHECK (identifier_type IN ('cookie', 'fingerprint', 'email', 'phone', 'ip')),
            CONSTRAINT uq_identity_link UNIQUE (record_id, identifier_type, identifier_hash)
        )
    $tbl$, v_schema_name, v_schema_name);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_idgraph_record ON %I.identity_graph_links (record_id)', v_schema_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_idgraph_hash ON %I.identity_graph_links (identifier_type, identifier_hash)', v_schema_name);

    RAISE NOTICE 'V4 schema extensions provisioned for dealer_id %', p_dealer_id;
END;
$$;

-- =============================================================================
-- SECTION 4: INTENT EVENT CLEANUP POLICY
-- =============================================================================
-- intent_events grows fast. Retain 30 days in Aurora, archive to S3 via DMS.

-- Scheduled cleanup (run daily via EventBridge → Lambda):
-- DO $$
-- DECLARE r RECORD;
-- BEGIN
--   FOR r IN SELECT schema_name FROM public.dealers WHERE is_active = TRUE AND realtime_enabled = TRUE LOOP
--     EXECUTE format('DELETE FROM %I.intent_events WHERE event_at < NOW() - INTERVAL ''30 days''', r.schema_name);
--   END LOOP;
-- END $$;

-- =============================================================================
-- SECTION 5: SNOWFLAKE V4 ANALYTICAL VIEWS
-- =============================================================================
-- These are created in Snowflake, not Aurora.

-- Real-time funnel: pixel → identity → offer → conversion
-- CREATE OR REPLACE VIEW autocdp_analytics.analytics.realtime_funnel AS
-- SELECT
--     ie.dealer_id,
--     DATE_TRUNC('day', ie.event_at) AS day,
--     COUNT(DISTINCT ie.event_id) AS pixel_events,
--     COUNT(DISTINCT CASE WHEN ie.identity_confidence >= 0.85 THEN ie.record_id END) AS identities_resolved,
--     COUNT(DISTINCT im.campaign_id) AS offers_generated,
--     COUNT(DISTINCT CASE WHEN cl.status = 'dispatched' THEN cl.campaign_id END) AS offers_dispatched,
--     COUNT(DISTINCT CASE WHEN cl.status = 'converted' THEN cl.campaign_id END) AS conversions,
--     AVG(cl.latency_ms) AS avg_latency_ms
-- FROM s3_lake_intent_events ie
-- LEFT JOIN s3_lake_inventory_matches im ON im.record_id = ie.record_id
--     AND im.created_at BETWEEN ie.event_at AND ie.event_at + INTERVAL '1 minute'
-- LEFT JOIN s3_lake_campaigns cl ON cl.campaign_id = im.campaign_id
-- WHERE cl.trigger_type = 'realtime'
-- GROUP BY ie.dealer_id, DATE_TRUNC('day', ie.event_at);

-- Identity resolution stats
-- CREATE OR REPLACE VIEW autocdp_analytics.analytics.identity_resolution_stats AS
-- SELECT
--     dealer_id,
--     DATE_TRUNC('day', event_at) AS day,
--     COUNT(*) AS total_events,
--     SUM(CASE WHEN identity_confidence >= 0.85 THEN 1 ELSE 0 END) AS resolved,
--     SUM(CASE WHEN identity_confidence < 0.85 OR identity_confidence IS NULL THEN 1 ELSE 0 END) AS anonymous,
--     SUM(CASE WHEN identity_confidence >= 0.85 THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS resolution_rate,
--     AVG(CASE WHEN identity_confidence >= 0.85 THEN identity_confidence END) AS avg_confidence
-- FROM s3_lake_intent_events
-- GROUP BY dealer_id, DATE_TRUNC('day', event_at);

-- Inventory match performance
-- CREATE OR REPLACE VIEW autocdp_analytics.analytics.inventory_match_performance AS
-- SELECT
--     im.dealer_id,
--     inv.segment,
--     COUNT(*) AS matches,
--     AVG(im.offered_payment) AS avg_payment,
--     AVG(im.match_score) AS avg_match_score,
--     SUM(CASE WHEN cl.status = 'converted' THEN 1 ELSE 0 END) AS conversions,
--     SUM(CASE WHEN cl.status = 'converted' THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS conversion_rate,
--     AVG(im.match_latency_ms) AS avg_match_latency_ms
-- FROM s3_lake_inventory_matches im
-- JOIN s3_lake_inventory inv ON inv.vin = im.matched_vin
-- LEFT JOIN s3_lake_campaigns cl ON cl.campaign_id = im.campaign_id
-- GROUP BY im.dealer_id, inv.segment;

-- Customer journey (materialized, full attribution timeline)
-- CREATE OR REPLACE TABLE autocdp_analytics.analytics.customer_journey AS
-- SELECT
--     ae.record_id,
--     ae.dealer_id,
--     ae.campaign_id,
--     ARRAY_AGG(OBJECT_CONSTRUCT(
--         'event_type', ae.event_type,
--         'event_at', ae.event_at,
--         'event_data', ae.event_data
--     )) WITHIN GROUP (ORDER BY ae.event_at) AS journey_events,
--     MIN(ae.event_at) AS journey_start,
--     MAX(ae.event_at) AS journey_end,
--     DATEDIFF('hour', MIN(ae.event_at), MAX(ae.event_at)) AS journey_hours,
--     MAX(CASE WHEN ae.event_type = 'deal_closed' THEN 1 ELSE 0 END) AS converted
-- FROM s3_lake_attribution_events ae
-- GROUP BY ae.record_id, ae.dealer_id, ae.campaign_id;

-- Real-time vs batch comparison
-- CREATE OR REPLACE VIEW autocdp_analytics.analytics.realtime_vs_batch AS
-- SELECT
--     dealer_id,
--     trigger_type,
--     DATE_TRUNC('month', created_at) AS month,
--     COUNT(*) AS campaigns,
--     SUM(CASE WHEN status = 'converted' THEN 1 ELSE 0 END) AS conversions,
--     SUM(CASE WHEN status = 'converted' THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS conversion_rate,
--     SUM(channel_cost) AS total_cost,
--     AVG(latency_ms) AS avg_latency_ms
-- FROM s3_lake_campaigns
-- GROUP BY dealer_id, trigger_type, DATE_TRUNC('month', created_at);
