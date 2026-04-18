# AutoCDP V2 Architecture

## C4 System Context Diagram

```mermaid
graph TB
    dealer_gm["Dealer GM<br/><i>Approves budgets, views dashboard</i>"]
    autocdp_admin["AutoCDP Admin<br/><i>Manages dealers, monitors pipelines</i>"]
    customer["Vehicle Owner<br/><i>Receives mail, scans QR code</i>"]

    autocdp["<b>AutoCDP V2</b><br/>Automated SaaS Engine<br/>Nightly sync, automated scoring,<br/>CRM write-backs, self-serve UI"]

    authenticom["<b>Authenticom / Motive</b><br/><i>Neutral data aggregator</i><br/><i>Nightly CRM delta extraction</i>"]
    crm["<b>Legacy CRM</b><br/><i>CDK / Reynolds / DealerTrack</i>"]
    lob["<b>Lob.com</b><br/><i>Print-and-mail fulfilment</i>"]
    llm["<b>LLM Provider</b><br/><i>OpenAI / Anthropic / Bedrock</i>"]
    ses["<b>AWS SES</b><br/><i>ADF XML CRM write-back emails</i>"]

    authenticom -->|"Nightly delta extract"| crm
    authenticom -->|"Drops JSON/CSV to S3"| autocdp
    autocdp -->|"Submits print jobs"| lob
    autocdp -->|"Sends offer prompts"| llm
    autocdp -->|"ADF XML email"| ses
    ses -->|"Invisible CRM note"| crm
    dealer_gm -->|"Dashboard + budget approval"| autocdp
    autocdp_admin -->|"Manages config"| autocdp
    customer -->|"Scans QR code"| autocdp
    lob -->|"Mails letter"| customer
```

---

## C4 Container Diagram

```mermaid
graph TB
    subgraph External["External Actors & Services"]
        dealer_gm["Dealer GM"]
        customer["Vehicle Owner"]
        authenticom["Authenticom / Motive"]
        crm["Legacy CRM"]
        lob["Lob.com"]
        llm["LLM Provider"]
    end

    subgraph AWS["AutoCDP V2 — AWS Cloud Boundary"]
        subgraph Scheduling["Scheduling Layer"]
            eventbridge["<b>EventBridge</b><br/><i>Nightly Sync cron (daily 2AM)</i><br/><i>Print Run cron (bi-weekly)</i>"]
        end

        subgraph Ingestion["Ingestion Layer"]
            s3_raw["<b>S3 Raw Bucket</b><br/><i>Receives aggregator drops + manual uploads</i>"]
        end

        subgraph Compute["Compute Layer"]
            sfn["<b>Step Functions</b><br/><i>Orchestrates ETL, scoring, generation, dispatch</i>"]
            etl["<b>ETL Fargate</b><br/><i>Polars: clean, deduplicate, delta upsert</i>"]
            score_lambda["<b>Scoring Lambda</b><br/><i>XGBoost propensity scoring</i>"]
            select_lambda["<b>Selection Lambda</b><br/><i>Score threshold + cooldown filter</i>"]
            gen_lambda["<b>Generation Lambda</b><br/><i>LLM + Pydantic Compliance Firewall</i>"]
            dispatch_lambda["<b>Dispatch Lambda</b><br/><i>Lob print + SES ADF write-back</i>"]
        end

        subgraph Data["Data Layer"]
            aurora["<b>Aurora PostgreSQL</b><br/>Serverless v2<br/><i>Schema-per-dealer OLTP</i>"]
        end

        subgraph Frontend["Frontend Layer"]
            cognito["<b>Cognito</b><br/><i>JWT auth for dealer portal</i>"]
            nextjs["<b>Next.js Dashboard</b><br/><i>Self-serve dealer portal</i>"]
            api_gw["<b>API Gateway</b><br/><i>Routes API + dashboard requests</i>"]
        end

        subgraph Services["Service Layer"]
            qr_service["<b>QR Redirect</b><br/><i>FastAPI / Fargate</i>"]
            ses["<b>AWS SES</b><br/><i>ADF XML email dispatch</i>"]
            metabase["<b>Metabase</b><br/><i>Internal analytics</i>"]
        end
    end

    authenticom -->|"Daily delta JSON/CSV"| s3_raw
    eventbridge -->|"Cron trigger"| sfn
    s3_raw -->|"ObjectCreated"| sfn
    sfn --> etl
    sfn --> score_lambda
    sfn --> select_lambda
    sfn --> gen_lambda
    sfn --> dispatch_lambda

    etl -->|"UPSERT golden_records"| aurora
    score_lambda -->|"INSERT propensity_scores"| aurora
    select_lambda -->|"READ scores + cooldowns"| aurora
    gen_lambda -->|"INSERT campaigns + audit"| aurora
    gen_lambda --> llm
    dispatch_lambda --> lob
    dispatch_lambda -->|"UPDATE campaign_ledger"| aurora
    dispatch_lambda -->|"Send ADF XML"| ses
    ses -->|"Invisible note"| crm

    dealer_gm --> nextjs
    nextjs --> cognito
    nextjs --> api_gw
    api_gw --> aurora
    customer --> qr_service
    qr_service --> aurora
    metabase -->|"Read replica"| aurora
```

---

## Sequence Diagram — Nightly Sync Flow

```mermaid
sequenceDiagram
    autonumber
    participant EB as EventBridge (2AM cron)
    participant S3 as S3 Raw Bucket
    participant SFN as Step Functions
    participant ETL as ETL Fargate
    participant Score as Scoring Lambda
    participant Aurora as Aurora PostgreSQL

    Note over EB: Daily at 2:00 AM UTC
    EB->>SFN: StartExecution {event: nightly_sync}

    loop For each active dealer
        SFN->>S3: Check for new delta file in dealer prefix
        S3-->>SFN: {s3_key: dealer_{id}/daily/2026-04-18.json}

        SFN->>ETL: RunTask {dealer_id, s3_key, mode: delta}
        ETL->>S3: GetObject - read delta JSON
        ETL->>ETL: Polars: normalize, compute source_hash
        ETL->>Aurora: UPSERT golden_records ON CONFLICT(source_hash)
        ETL->>Aurora: UPSERT vehicles (new purchases, service visits)
        ETL->>Aurora: INSERT sync_history {records_received, records_processed}
        ETL-->>SFN: {records_upserted, records_updated}

        SFN->>Score: Invoke {dealer_id, changed_record_ids}
        Score->>Aurora: SELECT golden_records + vehicles for changed records
        Score->>Score: XGBoost predict() on changed records only
        Score->>Aurora: UPSERT propensity_scores for changed records
        Score-->>SFN: {scored_count}
    end

    SFN-->>SFN: Nightly Sync SUCCEEDED
```

---

## Sequence Diagram — Print Run + ADF XML Write-Back

```mermaid
sequenceDiagram
    autonumber
    participant EB as EventBridge (bi-weekly)
    participant SFN as Step Functions
    participant Select as Selection Lambda
    participant Gen as Generation Lambda
    participant LLM as LLM Provider
    participant Dispatch as Dispatch Lambda
    participant Lob as Lob.com
    participant SES as AWS SES
    participant CRM as Legacy CRM
    participant Aurora as Aurora PostgreSQL

    Note over EB: Bi-weekly Print Run
    EB->>SFN: StartExecution {event: print_run}

    loop For each active dealer
        SFN->>Select: Invoke {dealer_id, score_threshold: 0.70}
        Select->>Aurora: SELECT eligible records (score > 0.70, cooldown clear)
        Select-->>SFN: {eligible_record_ids[]}

        loop For each eligible record (Map state)
            SFN->>Gen: Invoke {dealer_id, record_id}
            Gen->>Aurora: SELECT customer + vehicle data
            Gen->>LLM: POST structured prompt (instructor + Pydantic)
            LLM-->>Gen: OfferDraft JSON
            Gen->>Gen: Compliance Firewall: validate APR math
            Gen->>Aurora: INSERT campaign_ledger + compliance_audit_log
            Gen-->>SFN: {campaign_id, compliance_status}
        end

        loop For each compliance_passed campaign (Map state)
            SFN->>Dispatch: Invoke {dealer_id, campaign_id}
            Dispatch->>Aurora: SELECT campaign copy_payload
            Dispatch->>Lob: POST /v1/letters {address, content, QR}
            Lob-->>Dispatch: {lob_tracking_id}
            Dispatch->>Aurora: UPDATE campaign_ledger SET status=dispatched
            Dispatch->>Aurora: UPSERT cooldown_ledger SET expires_at=NOW()+45d

            Note over Dispatch,CRM: ADF XML Write-Back
            Dispatch->>Aurora: SELECT dealers.crm_writeback_email
            Dispatch->>SES: Send ADF XML email to CRM intake address
            Dispatch->>Aurora: INSERT crm_writebacks {adf_xml, ses_message_id}
            SES-->>CRM: ADF XML email -> note on customer profile
        end
    end

    SFN-->>SFN: Print Run SUCCEEDED
```

---

## Sequence Diagram — Dealer Self-Serve Dashboard

```mermaid
sequenceDiagram
    autonumber
    actor GM as Dealer GM
    participant NextJS as Next.js Dashboard
    participant Cognito as AWS Cognito
    participant APIGW as API Gateway
    participant Aurora as Aurora PostgreSQL

    GM->>NextJS: Navigate to dashboard.autocdp.com
    NextJS->>Cognito: Redirect to hosted login UI
    GM->>Cognito: Enter email + password
    Cognito-->>NextJS: JWT tokens (access + refresh)

    GM->>NextJS: View dashboard
    NextJS->>APIGW: GET /api/v1/dashboard/{dealer_id} [Bearer JWT]
    APIGW->>Cognito: Validate JWT, extract dealer_id claim
    APIGW->>Aurora: SELECT campaign metrics, sync status, budget remaining
    Aurora-->>APIGW: Dashboard data
    APIGW-->>NextJS: {active_campaigns, scans_this_month, budget_remaining, last_sync}
    NextJS-->>GM: Render dashboard

    GM->>NextJS: Approve next month budget ($50,000)
    NextJS->>APIGW: POST /api/v1/campaigns/{dealer_id}/approve {budget: 50000}
    APIGW->>Aurora: INSERT campaign_approvals {budget, approved_by, expires_at}
    Aurora-->>APIGW: {approval_id}
    APIGW-->>NextJS: Budget approved
    NextJS-->>GM: Confirmation displayed
```

---

## EventBridge Scheduling Configuration

```mermaid
graph LR
    subgraph EventBridge["Amazon EventBridge Scheduler"]
        cron_sync["<b>Nightly Sync</b><br/>cron(0 2 * * ? *)<br/><i>Daily at 2:00 AM UTC</i>"]
        cron_print["<b>Print Run</b><br/>cron(0 3 1,15 * ? *)<br/><i>1st and 15th at 3:00 AM UTC</i>"]
    end

    sfn_sync["Step Functions<br/>Nightly Sync Workflow"]
    sfn_print["Step Functions<br/>Print Run Workflow"]

    cron_sync -->|"StartExecution"| sfn_sync
    cron_print -->|"StartExecution"| sfn_print
```
