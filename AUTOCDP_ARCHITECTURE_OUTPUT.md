# AutoCDP System Architecture Output (V1→V5)

This document is the engineering artifact set for architecture visualization and implementation planning.

---

## 1) Version Pipeline Snapshot

| Version | Dealer Scale | Revenue Target | Core Mode |
|---|---:|---:|---|
| V1 Breadboard | 1–5 | $0–$1M ARR | Manual-assisted async batch |
| V2 Microcontroller | 5–50 | $1M–$9M ARR | Fully automated scheduled batch |
| V3 Superscalar | 50–500 | $9M–$90M ARR | Batch + MLOps + omnichannel routing |
| V4 SoC Streaming | 500–5,000+ | $100M–$500M+ ARR | Real-time event-driven activation |
| V5 Global Neural Network | 5,000–20,000+ | $500M+ ARR | Market-making subsidy optimizer |

---

## 2) Mermaid Architecture Diagrams (GitHub-safe syntax)

### 2.1 V1 Breadboard (1–5 Dealers, $0–$1M ARR)

```mermaid
flowchart LR
  subgraph TP[Third Party Inputs]
    GM[Dealer GM Uploads CSV]
  end

  subgraph AWS[AWS Cloud Boundary]
    S3[(S3 Raw Dropzone)]
    SFN[Step Functions Orchestrator]
    ETL[ECS Fargate ETL and Dedup]
    PG[(Aurora Postgres Ledger)]
    ML[Lambda Scoring with Frozen XGBoost]
    LLM[OpenAI via Instructor]
    FIRE[Pydantic Reg Z Firewall]
    API[FastAPI QR Redirect]
    BI[Metabase Read Replica]
  end

  subgraph EXT[Physical and External IO]
    LOB[Lob Print API]
    USER[Customer Receives Mail and Scans QR]
  end

  GM --> S3 --> SFN --> ETL --> PG
  SFN --> ML --> PG
  SFN --> LLM --> FIRE --> LOB
  LOB --> PG
  USER --> API --> PG
  BI <--> PG
```

### 2.2 V2 Microcontroller (5–50 Dealers, $1M–$9M ARR)

```mermaid
flowchart LR
  subgraph TP[Third Party Aggregators]
    AGG[Authenticom or Motive Nightly Delta]
  end

  subgraph AWS[AWS Cloud Boundary]
    S3[(S3 Delta Bucket)]
    EB[EventBridge Schedules]
    SFN[Step Functions]
    ETL[ECS Fargate ETL]
    PG[(Aurora Postgres Cooldown Ledger)]
    ML[Inference Service]
    LLM[LLM Offer Draft]
    FIRE[Pydantic Reg Z Validation]
    SES[SES ADF XML Writeback]
    UI[Next.js and Cognito]
  end

  subgraph EXT[External IO]
    LOB[Lob Direct Mail]
    CRM[Legacy CRM Inbox Parser]
  end

  AGG --> S3
  EB --> SFN
  S3 --> SFN --> ETL --> PG
  SFN --> ML --> PG
  SFN --> LLM --> FIRE --> LOB
  FIRE --> SES --> CRM
  UI <--> PG
```

### 2.3 V3 Superscalar (50–500 Dealers, $9M–$90M ARR)

```mermaid
flowchart LR
  subgraph AWS[AWS and Data Platform]
    PG[(Postgres OLTP)]
    DMS[AWS DMS]
    SNOW[(Snowflake OLAP)]
    SAGE[SageMaker Monthly Retraining]
    ORCH[Batch Orchestrator]
    ROUTE[Channel Router Policy]
    FIRE[Pydantic Reg Z Firewall]
  end

  subgraph EXT[External Channels]
    LOB[Lob]
    TW[Twilio]
    SG[SendGrid]
  end

  PG --> DMS --> SNOW --> SAGE --> ORCH
  ORCH --> ROUTE --> FIRE
  FIRE --> LOB
  FIRE --> TW
  FIRE --> SG
  ORCH <--> PG
```

### 2.4 V4 SoC Streaming (500–5,000+ Dealers, $100M–$500M+ ARR)

```mermaid
flowchart LR
  subgraph TP[Live Event Sources]
    PIX[Web Pixel and App Events]
    FEED[Partner Inventory and Identity Feeds]
  end

  subgraph AWS[AWS Cloud Boundary]
    MSK[Kafka or MSK]
    FLINK[Flink Stream Processing]
    NEP[(Neptune Identity Graph)]
    STATE[(Postgres and Redis Cooldown State)]
    RAG[(Pinecone Vector Context)]
    PLLM[Private LLM in VPC]
    LEGAL[Deterministic Reg Z Engine]
    SNOW[(Snowflake)]
    REDIS[(Redis Materialized Views)]
    UI[Command Center UI]
  end

  subgraph EXT[External Channels]
    TW[Twilio]
    LOB[Lob]
    SG[SendGrid]
  end

  PIX --> MSK
  FEED --> MSK --> FLINK
  FLINK --> NEP
  FLINK --> STATE
  STATE --> PLLM
  RAG --> PLLM
  PLLM --> LEGAL
  LEGAL --> TW
  LEGAL --> LOB
  LEGAL --> SG
  STATE --> SNOW --> REDIS --> UI
```

### 2.5 V5 Global Neural Network (5,000–20,000+ Dealers, $500M+ ARR)

```mermaid
flowchart LR
  subgraph OEM[OEM and Bank Capital Sources]
    OEMAPI[OEM Subvention APIs]
    BANK[Bank Incentive Feeds]
  end

  subgraph CORE[AutoCDP Global Optimization Core]
    DEMAND[National Demand Graph]
    RL[Reinforcement Learning Allocator]
    LEGAL[Deterministic Regulatory Engine]
    POLICY[Budget and Priority Policy Layer]
  end

  subgraph NETWORK[Dealer Activation Network]
    D1[Dealer Groups]
    D2[Regional Campaign Nodes]
    CH[Channels Print SMS Email]
  end

  OEMAPI --> DEMAND
  BANK --> DEMAND
  DEMAND --> RL --> LEGAL --> CH
  POLICY --> RL
  CH --> D1 --> D2
```

---

## 3) End-to-End User Journey by Version

### V1 End-to-End
- **Scale and Revenue:** 1–5 dealers; **$0–$1M ARR**.
- Dealer GM uploads historical CRM CSV to S3.
- Nightly batch cleans and dedupes data into Golden Records.
- XGBoost scores likely buyers.
- LLM drafts offer, then Reg Z validator recalculates and approves.
- Lob prints and mails; customer scans QR; system records attribution.

### V2 End-to-End
- **Scale and Revenue:** 5–50 dealers; **$1M–$9M ARR**.
- Aggregator drops daily deltas automatically.
- EventBridge runs nightly sync and print cadence.
- Cooldown ledger blocks ineligible records before actuation.
- SES sends ADF XML notes to CRM inbox for write-back visibility.
- GM monitors spend/results in self-serve dashboard.

### V3 End-to-End
- **Scale and Revenue:** 50–500 dealers; **$9M–$90M ARR**.
- Monthly retraining adjusts propensity model weights.
- Router selects cheapest compliant channel (mail/SMS/email).
- Guardrail validation still gates all outbound content.
- Snowflake powers enterprise analytics and attribution at scale.

### V4 End-to-End
- **Scale and Revenue:** 500–5,000+ dealers; **$100M–$500M+ ARR**.
- Web events stream in real time via Kafka/MSK.
- Flink + Neptune resolve identity and context on-the-fly.
- Private LLM generates offer text with vector-grounded inventory context.
- Deterministic legal engine approves; channel is dispatched instantly.
- Command center updates in near-real-time via Redis materialized views.

### V5 End-to-End
- **Scale and Revenue:** 5,000–20,000+ dealers; **$500M+ ARR**.
- OEM and bank subsidies stream into optimization layer.
- RL allocator distributes incentives by geography, propensity, inventory, and constraints.
- Regulatory engine enforces compliant pricing/terms before market actuation.
- AutoCDP behaves as a national activation clearinghouse across dealer networks.

---

## 4) Relational Schema (PostgreSQL OLTP)

```sql
CREATE TABLE dealerships (
  id BIGSERIAL PRIMARY KEY,
  dealer_code TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  timezone TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE customers (
  id BIGSERIAL PRIMARY KEY,
  dealership_id BIGINT NOT NULL REFERENCES dealerships(id),
  external_customer_key TEXT,
  first_name TEXT,
  last_name TEXT,
  email TEXT,
  phone_e164 TEXT,
  address_line1 TEXT,
  city TEXT,
  state TEXT,
  postal_code TEXT,
  dedupe_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (dealership_id, dedupe_hash)
);

CREATE TABLE propensity_scores (
  id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customers(id),
  model_version TEXT NOT NULL,
  score NUMERIC(5,4) NOT NULL CHECK (score >= 0 AND score <= 1),
  feature_snapshot JSONB NOT NULL,
  scored_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cooldown_ledger (
  id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customers(id),
  channel TEXT NOT NULL CHECK (channel IN ('DIRECT_MAIL','SMS','EMAIL')),
  locked_until TIMESTAMPTZ NOT NULL,
  reason TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (customer_id, channel)
);

CREATE TABLE campaign_offers (
  id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customers(id),
  channel TEXT NOT NULL CHECK (channel IN ('DIRECT_MAIL','SMS','EMAIL')),
  offer_json JSONB NOT NULL,
  regz_validated BOOLEAN NOT NULL DEFAULT FALSE,
  regz_validation_details JSONB,
  status TEXT NOT NULL CHECK (status IN ('QUEUED','APPROVED','SENT','FAILED','BLOCKED_COOLDOWN')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at TIMESTAMPTZ
);
```

---

## 5) Terraform Starter (V1 and V2 Batch-First)

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" { type = string }
variable "project" { type = string }

resource "aws_s3_bucket" "raw_dropzone" {
  bucket = "${var.project}-raw-dropzone"
}

resource "aws_cloudwatch_event_rule" "nightly_sync" {
  name                = "${var.project}-nightly-sync"
  schedule_expression = "cron(0 2 * * ? *)"
}

resource "aws_ecs_cluster" "etl" {
  name = "${var.project}-etl"
}

resource "aws_ses_email_identity" "adf_sender" {
  email = "adf-writeback@${var.project}.example.com"
}
```

---

## 6) Non-Negotiable Guardrails
1. V1–V3 remain asynchronous batch systems; no high-QPS synchronous ingestion architecture.
2. No direct CRM read API dependency in V1–V3; use nightly aggregator drops.
3. No direct CRM write API dependency in V1–V3; use SES with ADF XML payloads.
4. Deterministic Reg Z validation must gate all outbound offers.
5. Cooldown ledger checks must occur before any channel dispatch.

