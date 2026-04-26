# AutoCDP V4 Architecture

## C4 System Context Diagram

```mermaid
graph TB
    dealer_gm["Dealer GM<br/><i>Real-time dashboard</i>"]
    group_ceo["Auto Group CEO<br/><i>Cross-dealer analytics</i>"]
    autocdp_admin["AutoCDP Admin"]
    customer["Vehicle Owner"]
    website_visitor["Website Visitor<br/><i>Anonymous or known</i>"]

    autocdp["<b>AutoCDP V4</b><br/>Real-Time Activation Platform<br/>Streaming, identity resolution,<br/>live inventory, private AI"]

    authenticom["<b>Authenticom / Motive</b><br/><i>CRM delta extraction</i>"]
    crm["<b>Legacy CRM</b>"]
    dms_feed["<b>DMS Inventory Feed</b><br/><i>Real-time vehicle updates</i>"]
    lob["<b>Lob.com</b><br/><i>Print fulfilment</i>"]
    twilio["<b>Twilio</b><br/><i>SMS dispatch</i>"]
    sendgrid["<b>SendGrid</b><br/><i>Email dispatch</i>"]
    ses["<b>AWS SES</b><br/><i>ADF XML write-backs</i>"]
    dealer_website["<b>Dealer Website</b><br/><i>JavaScript pixel</i>"]

    dealer_website -->|"Pixel events"| autocdp
    website_visitor --> dealer_website
    authenticom -->|"CRM CDC"| crm
    authenticom --> autocdp
    dms_feed -->|"Inventory updates"| autocdp
    autocdp --> lob
    autocdp --> twilio
    autocdp --> sendgrid
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
        crm["Legacy CRM"]
        dms_feed["DMS Inventory Feed"]
        dealer_website["Dealer Websites"]
    end

    subgraph AWS["AutoCDP V4 — AWS Cloud Boundary"]
        subgraph Streaming["Real-Time Streaming Layer"]
            kafka["<b>Amazon MSK (Kafka)</b><br/><i>Event ingestion + routing</i>"]
            flink["<b>Amazon Managed Flink</b><br/><i>Stream processing + intent scoring</i>"]
            pixel_api["<b>Pixel Ingestion API</b><br/><i>CloudFront + Lambda@Edge</i>"]
        end

        subgraph Identity["Identity Resolution Layer"]
            neptune["<b>Amazon Neptune</b><br/><i>Identity graph database</i>"]
            resolver["<b>Identity Resolver Lambda</b><br/><i>Graph traversal + confidence scoring</i>"]
        end

        subgraph Inventory["Live Inventory Layer"]
            inv_cache["<b>ElastiCache Redis</b><br/><i>Real-time inventory state</i>"]
            inv_sync["<b>Inventory Sync Fargate</b><br/><i>DMS feed ingestion</i>"]
            matchmaker["<b>Inventory Matchmaker Lambda</b><br/><i>Lease calculation engine</i>"]
        end

        subgraph PrivateAI["Private AI Layer"]
            gpu["<b>GPU Instances (p4d/g5)</b><br/><i>Fine-tuned LLM inference</i>"]
            compliance["<b>Compliance Guardrail</b><br/><i>Reg Z validation</i>"]
        end

        subgraph BatchLayer["Batch Layer (V3 Carried Forward)"]
            eb["<b>EventBridge</b><br/><i>Nightly sync, scheduled campaigns</i>"]
            sfn["<b>Step Functions</b><br/><i>Batch orchestration</i>"]
            etl["<b>ETL Fargate</b>"]
            score_batch["<b>Batch Scoring Lambda</b>"]
            router["<b>Channel Router Lambda</b>"]
            gen_batch["<b>Batch Generation Lambda</b>"]
            dispatch_batch["<b>Batch Dispatch Lambda</b>"]
        end

        subgraph DataLayer["Data Layer"]
            aurora["<b>Aurora PostgreSQL</b><br/>Serverless v2<br/><i>Schema-per-dealer OLTP</i>"]
            dms["<b>AWS DMS</b><br/><i>CDC replication</i>"]
            s3_lake["<b>S3 Data Lake</b><br/><i>Unified Parquet</i>"]
            snowflake["<b>Snowflake</b><br/><i>OLAP analytics</i>"]
        end

        subgraph MLOps["MLOps"]
            sagemaker["<b>SageMaker Pipelines</b><br/><i>Weekly automated retraining</i>"]
            model_reg["<b>Model Registry</b>"]
        end

        subgraph Frontend["Frontend"]
            cognito["<b>Cognito</b>"]
            nextjs["<b>Next.js Dashboard</b><br/><i>Real-time + analytics views</i>"]
            api_gw["<b>API Gateway</b>"]
            ws_gw["<b>WebSocket API Gateway</b><br/><i>Live dashboard updates</i>"]
        end

        subgraph Services["Services"]
            qr["<b>QR Redirect</b>"]
            ses["<b>AWS SES</b>"]
        end
    end

    dealer_website -->|"Pixel events"| pixel_api
    pixel_api --> kafka
    authenticom -->|"CRM CDC"| kafka
    dms_feed -->|"Inventory"| inv_sync
    inv_sync --> inv_cache
    inv_sync --> kafka

    kafka --> flink
    flink -->|"High-intent event"| resolver
    resolver --> neptune
    resolver -->|"Identified customer"| matchmaker
    matchmaker --> inv_cache
    matchmaker --> aurora
    matchmaker -->|"Structured offer"| gpu
    gpu --> compliance
    compliance -->|"Approved"| twilio
    compliance --> aurora

    eb --> sfn
    sfn --> etl
    sfn --> score_batch
    sfn --> router
    sfn --> gen_batch
    sfn --> dispatch_batch
    etl --> aurora
    dispatch_batch --> lob
    dispatch_batch --> twilio
    dispatch_batch --> sendgrid
    dispatch_batch --> ses
    ses --> crm

    aurora -->|"CDC"| dms
    dms --> s3_lake
    s3_lake --> snowflake
    s3_lake --> sagemaker
    sagemaker --> model_reg
    model_reg --> score_batch
    model_reg --> flink

    nextjs --> api_gw
    nextjs --> ws_gw
    api_gw --> aurora
    api_gw --> snowflake
    ws_gw --> kafka
    nextjs --> cognito
    customer --> qr
    qr --> aurora
```

---

## Sequence Diagram — Real-Time Intent-to-Offer Pipeline

```mermaid
sequenceDiagram
    autonumber
    participant Website as Dealer Website
    participant Pixel as Pixel API (CloudFront)
    participant Kafka as MSK (Kafka)
    participant Flink as Managed Flink
    participant Resolver as Identity Resolver
    participant Neptune as Neptune Graph
    participant Matcher as Inventory Matchmaker
    participant Redis as Redis (Inventory Cache)
    participant Aurora as Aurora PostgreSQL
    participant AI as Private AI (GPU)
    participant Compliance as Compliance Guardrail
    participant Cooldown as Spam Prevention Ledger
    participant Twilio as Twilio SMS

    Website->>Pixel: VDP click event {cookie, fingerprint, ip, vin, dealer_id}
    Pixel->>Kafka: Produce to topic: website.events

    Kafka->>Flink: Consume event
    Flink->>Flink: Window aggregation: 3 VDP views in 5 min → high intent
    Flink->>Kafka: Produce to topic: intent.high

    Kafka->>Resolver: Consume high-intent event
    Resolver->>Neptune: MATCH (cookie)-[:LINKED_TO]-(identity)
    Neptune-->>Resolver: {record_id: "mike-uuid", confidence: 0.92}

    Resolver->>Aurora: SELECT customer + vehicle data WHERE record_id = $1
    Aurora-->>Resolver: {name: "Mike Johnson", equity: $4200, credit: "A", ...}

    Resolver->>Matcher: {record_id, browsed_vins, equity, credit_tier}
    Matcher->>Redis: GET inventory:{dealer_id}
    Redis-->>Matcher: [VIN list with MSRP, incentives, days_on_lot]
    Matcher->>Matcher: Filter by browsed segment (trucks)
    Matcher->>Matcher: Calculate lease: MSRP - equity - incentives → $489/mo
    Matcher-->>Resolver: {vin, payment: $489, term: 36, down: $0}

    Resolver->>AI: {customer: "Mike", vehicle: "2027 F-150 XLT", offer: $489/mo, channel: sms}
    AI->>AI: Generate personalized SMS (fine-tuned model, <500ms)
    AI-->>Resolver: "Hi Mike, I see you're looking at the 2027 F-150 XLT..."

    Resolver->>Compliance: Validate APR math, Reg Z formatting
    Compliance-->>Resolver: PASSED

    Resolver->>Cooldown: CHECK sms cooldown for record_id
    Cooldown-->>Resolver: CLEAR (last SMS 12 days ago)

    Resolver->>Aurora: INSERT campaign_ledger {channel: sms, status: dispatched}
    Resolver->>Aurora: INSERT cooldown_ledger {channel: sms, expires: +7 days}
    Resolver->>Twilio: Send SMS
    Twilio-->>Resolver: {sid: "SM...", status: "queued"}

    Note over Website,Twilio: Total elapsed: ~7 seconds
```

---

## Sequence Diagram — Identity Graph Resolution

```mermaid
sequenceDiagram
    autonumber
    participant Event as Incoming Event
    participant Resolver as Identity Resolver
    participant Neptune as Neptune Graph DB
    participant Aurora as Aurora PostgreSQL

    Event->>Resolver: {cookie: "abc123", fingerprint: "fp456", ip: "1.2.3.4", dealer_id: 104}

    Resolver->>Neptune: MATCH (n {cookie: "abc123"}) RETURN n
    Neptune-->>Resolver: Node found: cookie_abc123

    Resolver->>Neptune: MATCH (cookie_abc123)-[:SAME_DEVICE]-(d)-[:BELONGS_TO]-(identity) RETURN identity
    Neptune-->>Resolver: identity_node {record_id: "mike-uuid", edges: 4, confidence: 0.92}

    alt Confidence >= 0.85
        Resolver->>Aurora: SELECT * FROM golden_records WHERE record_id = "mike-uuid"
        Aurora-->>Resolver: {first_name: "Mike", last_name: "Johnson", ...}
        Resolver-->>Event: IDENTIFIED {record_id: "mike-uuid", confidence: 0.92}
    else Confidence < 0.85
        Resolver->>Neptune: UPDATE cookie_abc123 SET last_seen = NOW()
        Resolver-->>Event: ANONYMOUS {cookie: "abc123", reason: "low_confidence"}
    end
```

---

## Sequence Diagram — Inventory Sync Pipeline

```mermaid
sequenceDiagram
    autonumber
    participant DMS as DMS Inventory Feed
    participant Sync as Inventory Sync Fargate
    participant Redis as Redis Inventory Cache
    participant Kafka as MSK (Kafka)
    participant Aurora as Aurora PostgreSQL

    loop Every 15 minutes
        DMS->>Sync: Push inventory delta {dealer_id, vins_added, vins_removed, price_changes}
        Sync->>Sync: Parse and validate inventory records

        Sync->>Redis: HSET inventory:{dealer_id} {vin} {json}
        Note over Redis: Each dealer's inventory = Redis hash map

        Sync->>Redis: HDEL inventory:{dealer_id} {sold_vins}
        Note over Redis: Sold vehicles removed immediately

        Sync->>Aurora: UPSERT dealer_{id}.inventory_snapshot
        Sync->>Kafka: Produce to topic: inventory.updates {dealer_id, delta_summary}
    end
```

---

## Sequence Diagram — Real-Time Dashboard via WebSocket

```mermaid
sequenceDiagram
    autonumber
    actor GM as Dealer GM
    participant NextJS as Next.js Dashboard
    participant WS as WebSocket API Gateway
    participant Kafka as MSK (Kafka)
    participant Aurora as Aurora PostgreSQL

    GM->>NextJS: Open dashboard
    NextJS->>WS: Connect WebSocket {dealer_id, jwt}
    WS->>Kafka: Subscribe to topic: dealer.{dealer_id}.events

    loop Real-time updates
        Kafka->>WS: New event {type: "campaign_dispatched", record_id, channel: "sms"}
        WS->>NextJS: Push event
        NextJS->>NextJS: Update live campaign counter

        Kafka->>WS: New event {type: "identity_resolved", visitor_count: 14}
        WS->>NextJS: Push event
        NextJS->>NextJS: Update "Active Visitors" widget

        Kafka->>WS: New event {type: "conversion", campaign_id, revenue_attributed}
        WS->>NextJS: Push event
        NextJS->>NextJS: Update ROI ticker
    end
```

---

## Full V4 Service Topology

```mermaid
graph LR
    subgraph RealTime["Real-Time Layer"]
        pixel["Pixel API<br/>CloudFront + Lambda@Edge"]
        kafka["MSK Kafka<br/>Event backbone"]
        flink["Managed Flink<br/>Stream processing"]
    end

    subgraph Identity["Identity Layer"]
        neptune["Neptune<br/>Graph DB"]
        resolver["Identity Resolver"]
    end

    subgraph Inventory["Inventory Layer"]
        redis["Redis<br/>Live inventory cache"]
        matchmaker["Inventory Matchmaker<br/>Lease calculator"]
    end

    subgraph AI["AI Layer"]
        gpu["Private LLM<br/>GPU inference"]
        compliance["Compliance<br/>Guardrail"]
    end

    subgraph Batch["Batch Layer (V3)"]
        eb["EventBridge<br/>Cron triggers"]
        sfn["Step Functions"]
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
        sagemaker["SageMaker<br/>Weekly Retraining"]
        model["Model Registry"]
    end

    subgraph Channels["Dispatch Channels"]
        lob["Lob.com<br/>Print $1.00"]
        twilio["Twilio<br/>SMS $0.01"]
        sendgrid["SendGrid<br/>Email $0.001"]
    end

    pixel --> kafka
    kafka --> flink
    flink --> resolver
    resolver --> neptune
    resolver --> matchmaker
    matchmaker --> redis
    matchmaker --> gpu
    gpu --> compliance
    compliance --> twilio

    eb --> sfn
    sfn --> aurora
    sfn --> lob
    sfn --> sendgrid

    aurora --> dms
    dms --> s3
    s3 --> snowflake
    s3 --> sagemaker
    sagemaker --> model
    model --> flink
```
