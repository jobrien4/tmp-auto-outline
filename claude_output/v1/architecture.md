# AutoCDP V1 Architecture

## C4 System Context Diagram

```mermaid
graph TB
    dealer_staff["Dealer Staff<br/><i>Uploads CRM CSV export via pre-signed URL</i>"]
    autocdp_admin["AutoCDP Admin<br/><i>Generates upload URLs, monitors pipelines</i>"]
    customer["Vehicle Owner<br/><i>Receives mail, scans QR code</i>"]
    dealer_analyst["Dealer Analyst<br/><i>Views campaign performance via dashboard</i>"]

    autocdp["<b>AutoCDP V1</b><br/>Autonomous automotive retail marketing platform.<br/>Ingests CRM data, scores propensity,<br/>generates compliant offers, dispatches mail,<br/>tracks QR attribution."]

    lob["<b>Lob.com</b><br/><i>Print-and-mail fulfilment API</i>"]
    llm_provider["<b>LLM Provider</b><br/><i>OpenAI / Anthropic / Bedrock</i>"]
    usps["<b>USPS</b><br/><i>Physical postal delivery</i>"]

    dealer_staff -->|"Uploads CSV via pre-signed S3 URL"| autocdp
    autocdp_admin -->|"Generates URLs, triggers pipelines"| autocdp
    dealer_analyst -->|"Views metrics via Metabase"| autocdp
    customer -->|"Scans QR code on mailer"| autocdp
    autocdp -->|"Submits print jobs"| lob
    autocdp -->|"Sends offer generation prompts"| llm_provider
    lob -->|"Hands off printed mail"| usps
    usps -->|"Delivers mailer to home"| customer
```

---

## C4 Container Diagram

```mermaid
graph TB
    subgraph External["External Actors"]
        dealer_staff["Dealer Staff"]
        autocdp_admin["AutoCDP Admin"]
        customer["Vehicle Owner"]
        dealer_analyst["Dealer Analyst"]
    end

    subgraph AWS["AutoCDP V1 — AWS Cloud Boundary"]
        api_gw["<b>API Gateway</b><br/>AWS API Gateway HTTP API<br/><i>Routes all external HTTP requests</i>"]
        s3["<b>S3 Dropzone</b><br/>AWS S3<br/><i>Receives CSV uploads, triggers pipeline</i>"]
        sfn["<b>Orchestration Engine</b><br/>AWS Step Functions<br/><i>Coordinates ETL → Score → Generate → Dispatch</i>"]
        etl["<b>ETL Service</b><br/>ECS Fargate / Python Polars<br/><i>Normalizes, deduplicates, upserts golden records</i>"]
        score_lambda["<b>Scoring Service</b><br/>Lambda / XGBoost<br/><i>Loads frozen model, scores propensity</i>"]
        select_lambda["<b>Selection Service</b><br/>Lambda / Python<br/><i>Filters by score + cooldown</i>"]
        gen_lambda["<b>Offer Generation</b><br/>Lambda / instructor + Pydantic<br/><i>LLM copy + Compliance Firewall</i>"]
        dispatch_lambda["<b>Dispatch Service</b><br/>Lambda / Python<br/><i>Submits to Lob, updates ledger</i>"]
        qr_service["<b>QR Redirect Service</b><br/>ECS Fargate / FastAPI<br/><i>Logs scan, returns HTTP 302</i>"]
        aurora["<b>Aurora PostgreSQL</b><br/>Serverless v2<br/><i>Schema-per-dealer operational DB</i>"]
        metabase["<b>Metabase</b><br/>BI Dashboard<br/><i>Campaign performance reporting</i>"]
        secrets["<b>Secrets Manager</b><br/><i>API keys, DB credentials</i>"]
    end

    subgraph ExtServices["External Services"]
        lob["<b>Lob.com</b><br/><i>Print fulfilment</i>"]
        llm["<b>LLM Provider</b><br/><i>OpenAI / Anthropic / Bedrock</i>"]
    end

    dealer_staff -->|"POST /upload/presigned-url"| api_gw
    autocdp_admin -->|"POST /pipeline/trigger"| api_gw
    dealer_analyst --> metabase
    customer -->|"GET /scan/{uuid}"| qr_service

    api_gw --> s3
    s3 -->|"ObjectCreated event"| sfn
    sfn -->|"ECS RunTask"| etl
    sfn -->|"Lambda Invoke"| score_lambda
    sfn -->|"Lambda Invoke"| select_lambda
    sfn -->|"Lambda Invoke (Map)"| gen_lambda
    sfn -->|"Lambda Invoke (Map)"| dispatch_lambda

    etl -->|"UPSERT golden_records"| aurora
    score_lambda -->|"INSERT propensity_scores"| aurora
    select_lambda -->|"READ scores + cooldowns"| aurora
    gen_lambda -->|"INSERT campaigns + audit log"| aurora
    gen_lambda -->|"POST prompt"| llm
    dispatch_lambda -->|"POST /v1/letters"| lob
    dispatch_lambda -->|"UPDATE campaign_ledger"| aurora
    qr_service -->|"INSERT qr_scans"| aurora
    metabase -->|"SELECT (read replica)"| aurora

    etl --> secrets
    score_lambda --> secrets
    gen_lambda --> secrets
    dispatch_lambda --> secrets
```

---

## Sequence Diagram — Full Pipeline (CSV Upload to Mail Dispatch)

```mermaid
sequenceDiagram
    autonumber
    actor DealerStaff as Dealer Staff
    participant APIGW as API Gateway
    participant S3 as S3 Dropzone
    participant SFN as Step Functions
    participant ETL as ETL Fargate
    participant ScoreLambda as Scoring Lambda
    participant SelectLambda as Selection Lambda
    participant GenLambda as Generation Lambda
    participant LLMProvider as LLM Provider
    participant Aurora as Aurora PostgreSQL
    participant Lob as Lob.com API

    DealerStaff->>APIGW: POST /api/v1/upload/presigned-url {dealer_id, filename}
    APIGW->>S3: Generate pre-signed PUT URL (15-min TTL)
    APIGW-->>DealerStaff: {presigned_url, expires_at}

    DealerStaff->>S3: PUT CSV file via pre-signed URL
    S3-->>DealerStaff: HTTP 200 OK

    S3->>SFN: ObjectCreated event -> StartExecution {dealer_id, s3_key}

    SFN->>ETL: ECS RunTask {dealer_id, s3_key}
    ETL->>S3: GetObject - read raw CSV
    ETL->>ETL: Polars: normalize, deduplicate, compute SHA-256 hash
    ETL->>Aurora: UPSERT dealer_{id}.golden_records ON CONFLICT(source_hash)
    ETL-->>SFN: Task complete {records_upserted, records_skipped}

    SFN->>ScoreLambda: Invoke {dealer_id, batch_of_record_ids}
    ScoreLambda->>S3: GetObject - load XGBoost model.pkl (cached)
    ScoreLambda->>Aurora: SELECT golden_records + vehicles for batch
    ScoreLambda->>ScoreLambda: XGBoost predict() -> scores[]
    ScoreLambda->>Aurora: INSERT dealer_{id}.propensity_scores
    ScoreLambda-->>SFN: {scored_count}

    SFN->>SelectLambda: Invoke {dealer_id, score_threshold: 0.70}
    SelectLambda->>Aurora: SELECT WHERE score > 0.70 AND cooldown_expires_at < NOW()
    SelectLambda-->>SFN: {eligible_record_ids[]}

    Note over SFN: Map state - parallel batches of eligible records

    loop For each eligible record
        SFN->>GenLambda: Invoke {dealer_id, record_id}
        GenLambda->>Aurora: SELECT golden_records, vehicles, propensity_scores
        GenLambda->>GenLambda: Build structured prompt with customer context
        GenLambda->>LLMProvider: POST structured output (instructor + Pydantic schema)
        LLMProvider-->>GenLambda: OfferDraft {body, apr, monthly_payment, term, disclosures[]}
        GenLambda->>GenLambda: Compliance Firewall: recompute APR from principal/rate/term
        alt Compliance PASS
            GenLambda->>Aurora: INSERT campaign_ledger {status: compliance_passed}
            GenLambda->>Aurora: INSERT compliance_audit_log {event_type: PASS}
            GenLambda-->>SFN: {campaign_id, status: compliance_passed}
        else Compliance FAIL
            GenLambda->>Aurora: INSERT campaign_ledger {status: compliance_failed}
            GenLambda->>Aurora: INSERT compliance_audit_log {event_type: FAIL, reason}
            GenLambda-->>SFN: {campaign_id, status: compliance_failed}
        end
    end

    Note over SFN: Map state - dispatch compliance_passed campaigns

    loop For each compliance_passed campaign
        SFN->>Lob: Invoke Dispatch Lambda -> POST /v1/letters {address, content, QR}
        Lob-->>SFN: {lob_tracking_id, expected_delivery_date}
        SFN->>Aurora: UPDATE campaign_ledger SET status=dispatched
        SFN->>Aurora: UPSERT cooldown_ledger SET expires_at=NOW()+45d
    end

    SFN-->>SFN: Execution SUCCEEDED
```

---

## Sequence Diagram — QR Scan (Attribution Flow)

```mermaid
sequenceDiagram
    autonumber
    actor Customer as Vehicle Owner
    participant QR as QR Redirect Service (FastAPI)
    participant Aurora as Aurora PostgreSQL
    participant Inventory as Dealer Inventory Website

    Customer->>QR: GET https://go.autocdp.com/scan/{tracking_uuid}
    QR->>Aurora: SELECT campaign_ledger WHERE lob_tracking_id = {uuid}
    Aurora-->>QR: campaign row {dealer_id, record_id, redirect_url, status}

    QR->>Aurora: INSERT dealer_{id}.qr_scans {scan_id, campaign_id, ip, user_agent}
    Aurora-->>QR: OK

    QR->>Aurora: UPDATE campaign_ledger SET status=scanned, scanned_at=NOW()
    Aurora-->>QR: OK

    QR-->>Customer: HTTP 302 Location: {redirect_url}
    Customer->>Inventory: Browser follows redirect to dealer inventory page
```

---

## Step Functions State Machine

```mermaid
stateDiagram-v2
    [*] --> ValidateInput : S3 ObjectCreated triggers execution

    ValidateInput --> RunETL : Input valid
    ValidateInput --> ExecutionFailed : Missing dealer_id or s3_key

    RunETL --> WaitForETL : ECS task submitted
    WaitForETL --> ETLSucceeded : Task SUCCEEDED
    WaitForETL --> ETLFailed : Task FAILED or timeout

    ETLSucceeded --> ScoreRecords : Invoke Scoring Lambda (chunked Map)
    ETLFailed --> ExecutionFailed

    ScoreRecords --> SelectEligible : All score batches complete
    SelectEligible --> NoEligibleRecords : eligible_count = 0
    SelectEligible --> GenerateOffers : eligible_count > 0

    NoEligibleRecords --> ExecutionSucceeded : Log zero-eligible result

    state GenerateOffers {
        [*] --> ProcessRecord
        ProcessRecord --> [*] : Map state MaxConcurrency=10
    }
    GenerateOffers --> CollectComplianceResults : All generation complete

    CollectComplianceResults --> NoPassedOffers : passed_count = 0
    CollectComplianceResults --> DispatchOffers : passed_count > 0

    NoPassedOffers --> ExecutionSucceeded : Log all-failed result

    state DispatchOffers {
        [*] --> DispatchCampaign
        DispatchCampaign --> [*] : Map state MaxConcurrency=5
    }
    DispatchOffers --> RecordSummary : All dispatches attempted

    RecordSummary --> ExecutionSucceeded : Write summary to S3

    ExecutionSucceeded --> [*]
    ExecutionFailed --> [*]
```
