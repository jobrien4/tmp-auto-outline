# AutoCDP V3 Architecture

## C4 System Context Diagram

```mermaid
graph TB
    dealer_gm["Dealer GM<br/><i>Self-serve dashboard</i>"]
    group_ceo["Auto Group CEO<br/><i>Cross-dealer analytics dashboard</i>"]
    autocdp_admin["AutoCDP Admin"]
    customer["Vehicle Owner"]

    autocdp["<b>AutoCDP V3</b><br/>Multi-Channel + Continuous Learning<br/>Smart routing, MLOps flywheel,<br/>enterprise analytics"]

    authenticom["<b>Authenticom / Motive</b><br/><i>Nightly CRM delta extraction</i>"]
    crm["<b>Legacy CRM</b>"]
    lob["<b>Lob.com</b><br/><i>Print fulfilment</i>"]
    twilio["<b>Twilio</b><br/><i>SMS dispatch</i>"]
    sendgrid["<b>SendGrid</b><br/><i>Email dispatch</i>"]
    llm["<b>LLM Provider</b>"]
    ses["<b>AWS SES</b><br/><i>ADF XML write-backs</i>"]

    authenticom -->|"Nightly delta"| crm
    authenticom --> autocdp
    autocdp --> lob
    autocdp --> twilio
    autocdp --> sendgrid
    autocdp --> llm
    autocdp --> ses
    ses --> crm
    dealer_gm --> autocdp
    group_ceo --> autocdp
    customer --> autocdp
```

---

## C4 Container Diagram

```mermaid
graph TB
    subgraph External["External Services"]
        authenticom["Authenticom"]
        lob["Lob.com"]
        twilio["Twilio"]
        sendgrid["SendGrid"]
        llm["LLM Provider"]
        crm["Legacy CRM"]
    end

    subgraph AWS["AutoCDP V3 — AWS Cloud Boundary"]
        subgraph Scheduling["Scheduling"]
            eb["<b>EventBridge</b><br/><i>Nightly sync, print/digital run, monthly retrain</i>"]
        end

        subgraph Ingestion["Ingestion"]
            s3_raw["<b>S3 Raw</b><br/><i>Aggregator drops</i>"]
        end

        subgraph Compute["Compute"]
            sfn["<b>Step Functions</b><br/><i>Orchestration</i>"]
            etl["<b>ETL Fargate</b><br/><i>Polars delta processing</i>"]
            score["<b>Scoring Lambda</b><br/><i>XGBoost/LightGBM</i>"]
            select["<b>Selection Lambda</b>"]
            router["<b>Channel Router Lambda</b><br/><i>RL heuristic routing</i>"]
            gen["<b>Generation Lambda</b><br/><i>LLM + Pydantic per channel</i>"]
            dispatch["<b>Dispatch Lambda</b><br/><i>Lob + Twilio + SendGrid</i>"]
        end

        subgraph DataLayer["Data Layer"]
            aurora["<b>Aurora PostgreSQL</b><br/>Serverless v2<br/><i>Schema-per-dealer OLTP</i>"]
            dms["<b>AWS DMS</b><br/><i>CDC replication</i>"]
            s3_lake["<b>S3 Data Lake</b><br/><i>Unified Parquet, partitioned by dealer_id</i>"]
            snowflake["<b>Snowflake</b><br/><i>OLAP analytics warehouse</i>"]
        end

        subgraph MLOps["MLOps"]
            sagemaker["<b>SageMaker Pipelines</b><br/><i>Monthly automated retraining</i>"]
            model_reg["<b>Model Registry</b><br/><i>Version tracking + auto-deploy</i>"]
        end

        subgraph Frontend["Frontend"]
            cognito["<b>Cognito</b>"]
            nextjs["<b>Next.js Dashboard</b><br/><i>Dealer GM + Group CEO views</i>"]
            api_gw["<b>API Gateway</b>"]
        end

        subgraph Services["Services"]
            qr["<b>QR Redirect</b>"]
            ses["<b>AWS SES</b>"]
            redis["<b>ElastiCache Redis</b><br/><i>Dashboard cache (optional)</i>"]
        end
    end

    authenticom --> s3_raw
    eb --> sfn
    s3_raw --> sfn
    sfn --> etl
    sfn --> score
    sfn --> select
    sfn --> router
    sfn --> gen
    sfn --> dispatch

    etl --> aurora
    score --> aurora
    select --> aurora
    router --> aurora
    gen --> aurora
    gen --> llm
    dispatch --> lob
    dispatch --> twilio
    dispatch --> sendgrid
    dispatch --> aurora
    dispatch --> ses
    ses --> crm

    aurora -->|"CDC"| dms
    dms -->|"Parquet"| s3_lake
    s3_lake --> snowflake
    s3_lake --> sagemaker
    sagemaker --> model_reg
    model_reg -->|"Deploy new model"| score

    nextjs --> api_gw
    api_gw --> aurora
    api_gw --> snowflake
    nextjs --> cognito
    customer --> qr
    qr --> aurora
```

---

## Sequence Diagram — Monthly ML Retraining Pipeline

```mermaid
sequenceDiagram
    autonumber
    participant EB as EventBridge (1st of month)
    participant SM as SageMaker Pipeline
    participant S3Lake as S3 Data Lake
    participant Training as SageMaker Training Job
    participant Eval as SageMaker Processing Job
    participant Registry as Model Registry (Aurora)
    participant Score as Scoring Lambda

    EB->>SM: Trigger monthly retraining pipeline

    SM->>S3Lake: Read unified training data (all dealers, 12 months)
    Note over S3Lake: 500 dealers x 50k records = 25M rows

    SM->>Training: Launch XGBoost/LightGBM training job (spot instance)
    Training->>Training: Train on features: equity, lease_months_remaining,<br/>service_recency, service_count, days_since_purchase
    Training->>Training: Evaluate: precision, recall, AUC, F1
    Training->>S3Lake: Save model artifact (.tar.gz)
    Training-->>SM: {model_artifact_path, metrics}

    SM->>Eval: Launch evaluation job
    Eval->>S3Lake: Read holdout dataset (last 30 days actual conversions)
    Eval->>Eval: Compare predictions vs actual conversions
    Eval->>Eval: Calculate lift over previous model version
    Eval-->>SM: {evaluation_metrics, lift_vs_previous}

    alt New model improves over current
        SM->>Registry: INSERT model_versions {metrics, is_active=true}
        SM->>Registry: UPDATE previous model SET is_active=false, retired_at=NOW()
        SM->>S3Lake: Copy model artifact to production path
        Note over Score: Next scoring run automatically loads new model
        SM-->>EB: Retraining SUCCEEDED — new model deployed
    else New model does not improve
        SM->>Registry: INSERT model_versions {metrics, is_active=false, deployed_by='rejected'}
        SM-->>EB: Retraining completed — previous model retained
    end
```

---

## Sequence Diagram — Smart Channel Router Decision

```mermaid
sequenceDiagram
    autonumber
    participant SFN as Step Functions
    participant Router as Channel Router Lambda
    participant Aurora as Aurora PostgreSQL
    participant Gen as Generation Lambda
    participant LLM as LLM Provider

    SFN->>Router: Invoke {dealer_id, record_id, score: 0.89}
    Router->>Aurora: SELECT cooldown_ledger WHERE record_id = $1

    Note over Router: Evaluate each channel

    Router->>Router: Mail: cooldown_expires_at = 15 days from now → BLOCKED
    Router->>Router: SMS: cooldown_expires_at = 3 days ago → AVAILABLE, cost=$0.01
    Router->>Router: Email: cooldown_expires_at = 5 days ago → AVAILABLE, cost=$0.001

    Router->>Router: Predict conversion rate per channel:<br/>SMS: 8% (high for this segment)<br/>Email: 2% (low engagement history)
    Router->>Router: Expected ROI: SMS=$0.08/0.01=$8.00, Email=$0.02/0.001=$20.00
    Router->>Router: Select SMS (higher absolute conversion, meets ROI threshold)

    Router->>Aurora: INSERT channel_routing_log {selected: sms, reason, cost_estimate}
    Router-->>SFN: {record_id, selected_channel: sms}

    SFN->>Gen: Invoke {dealer_id, record_id, channel: sms}
    Gen->>Aurora: SELECT customer + vehicle data
    Gen->>LLM: POST prompt (160-char SMS Pydantic schema)
    LLM-->>Gen: SMS OfferDraft {body, apr, payment, term}
    Gen->>Gen: Compliance Firewall: validate APR math (same as mail)
    Gen->>Aurora: INSERT campaign_ledger {channel: sms, status: compliance_passed}
    Gen-->>SFN: {campaign_id, channel: sms, compliance: passed}
```

---

## Sequence Diagram — Data Lake CDC Pipeline

```mermaid
sequenceDiagram
    autonumber
    participant Aurora as Aurora PostgreSQL
    participant DMS as AWS DMS
    participant S3Lake as S3 Data Lake
    participant Snowflake as Snowflake

    Note over Aurora,DMS: Continuous CDC (Change Data Capture)

    Aurora->>DMS: WAL stream (all dealer schemas)
    DMS->>DMS: Transform to Parquet format
    DMS->>S3Lake: Write to s3://autocdp-lake/{table}/dealer_id={id}/

    Note over S3Lake: Partitioned by dealer_id and date

    S3Lake->>Snowflake: External table auto-refresh (every 15 min)

    Note over Snowflake: Materialized views for CEO dashboard

    Snowflake->>Snowflake: REFRESH analytics.campaign_performance
    Snowflake->>Snowflake: REFRESH analytics.channel_roi
    Snowflake->>Snowflake: REFRESH analytics.model_accuracy
    Snowflake->>Snowflake: REFRESH analytics.dealer_summary
```

---

## Sequence Diagram — CEO Analytics Dashboard

```mermaid
sequenceDiagram
    autonumber
    actor CEO as Auto Group CEO
    participant NextJS as Next.js Dashboard
    participant APIGW as API Gateway
    participant Snowflake as Snowflake
    participant Aurora as Aurora PostgreSQL

    CEO->>NextJS: Navigate to dashboard (group view)
    NextJS->>APIGW: GET /api/v1/analytics/{group_id}/overview [Bearer JWT]
    APIGW->>Snowflake: SELECT from analytics.dealer_summary WHERE group_id = $1
    Snowflake-->>APIGW: Aggregated KPIs across 50 dealerships (50ms)
    APIGW-->>NextJS: {total_campaigns, total_conversions, roi_by_channel, model_accuracy}

    CEO->>NextJS: Click "Channel ROI" tab
    NextJS->>APIGW: GET /api/v1/analytics/{group_id}/channel-roi
    APIGW->>Snowflake: SELECT from analytics.channel_roi WHERE group_id = $1
    Snowflake-->>APIGW: Per-channel cost, conversion, ROI breakdown
    APIGW-->>NextJS: Chart data

    CEO->>NextJS: Click "Model Performance" tab
    NextJS->>APIGW: GET /api/v1/analytics/{group_id}/model-performance
    APIGW->>Snowflake: SELECT from analytics.model_accuracy ORDER BY month
    Snowflake-->>APIGW: Accuracy trend over 12 months
    APIGW-->>NextJS: Time series data
```

---

## Full V3 Service Topology

```mermaid
graph LR
    subgraph Cron["Scheduled Events"]
        nightly["Nightly Sync<br/>Daily 2AM"]
        biweekly["Campaign Run<br/>1st + 15th"]
        monthly["ML Retrain<br/>1st of month"]
    end

    subgraph OLTP["Transactional Layer"]
        aurora["Aurora PostgreSQL<br/>Schema-per-dealer"]
    end

    subgraph Lake["Data Lake Layer"]
        dms["DMS CDC"]
        s3["S3 Parquet Lake"]
    end

    subgraph OLAP["Analytics Layer"]
        snowflake["Snowflake<br/>Materialized Views"]
    end

    subgraph ML["ML Layer"]
        sagemaker["SageMaker<br/>Monthly Retraining"]
        model["Model Registry"]
    end

    subgraph Channels["Actuation Channels"]
        lob["Lob.com<br/>Print $1.00"]
        twilio["Twilio<br/>SMS $0.01"]
        sendgrid["SendGrid<br/>Email $0.001"]
    end

    nightly --> aurora
    biweekly --> aurora
    aurora --> dms
    dms --> s3
    s3 --> snowflake
    s3 --> sagemaker
    sagemaker --> model
    model --> aurora
    monthly --> sagemaker
    biweekly --> lob
    biweekly --> twilio
    biweekly --> sendgrid
```
