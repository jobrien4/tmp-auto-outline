# AutoCDP System Architecture Output (V1→V5)

This document translates the provided master blueprint into implementation-ready artifacts:
- `mermaid.js` architecture diagrams.
- Technical tradeoff framing by version.
- Relational database schema (OLTP + analytics bridge).
- Terraform starter Infrastructure-as-Code for V1/V2 async batch architecture.

---

## 1) Architecture Diagrams (Mermaid)

### 1.1 V1/V2 Async Batch Baseline (with explicit boundaries)

```mermaid
flowchart LR
  %% Boundaries
  subgraph TP[Third-Party Aggregators]
    AGG[Authenticom / Motive Retail\nNightly JSON/CSV Drops]
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
  S3 --> SFN
  SFN --> ETL --> AUR
  SFN --> INF --> AUR
  SFN --> LLM --> REGZ
  REGZ -->|Approved Offer Payload| LOB
  REGZ -->|ADF XML Note| SES --> CRM
  LOB -->|Tracking UUID| AUR
  QR --> API --> AUR
  META <-->|Read-only analytics| AUR
```

### 1.2 V3 Superscalar Expansion (OLTP/OLAP + MLOps + Omnichannel)

```mermaid
flowchart LR
  subgraph AWS[AWS Cloud Boundary]
    AUR[(Postgres OLTP)]
    DMS[AWS DMS Replication]
    SNOW[(Snowflake OLAP)]
    SAGE[SageMaker Pipelines\nMonthly Retrain]
    ROUTER[Channel Router\n(RL/Heuristic Policy)]
    REGZ[Pydantic Reg Z Firewall]
    ORCH[Batch Orchestrator]
  end

  subgraph IO[Physical / External I-O]
    LOB[Lob]
    TW[Twilio SMS]
    SG[SendGrid Email]
  end

  AUR --> DMS --> SNOW
  SNOW --> SAGE --> ORCH
  ORCH --> ROUTER --> REGZ
  REGZ --> LOB
  REGZ --> TW
  REGZ --> SG
  ORCH <--> AUR
```

### 1.3 V4 Streaming SoC Transition

```mermaid
flowchart LR
  subgraph TP[Third-Party Aggregators + Web Events]
    PIX[Web Pixel / App Events]
    AGG[Dealer/Partner Feeds]
  end

  subgraph AWS[AWS Cloud Boundary]
    MSK[Kafka / Amazon MSK]
    FLINK[Flink Streaming ETL]
    NEP[(Amazon Neptune Graph Identity)]
    FEAT[Feature & Cooldown State\nPostgres + Redis]
    RAG[(Pinecone Vector Index)]
    LLMVPC[Private LLM in VPC\n(Llama-class)]
    FIRE[Rust/Python Deterministic Reg Z Firewall]
    SNOW[(Snowflake)]
    REDIS[(Redis UI Materialized Views)]
    UI[React Command Center]
  end

  subgraph IO[Physical / External I-O]
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
  AGG --> MSK
  MSK --> FLINK --> NEP
  FLINK --> FEAT
  FEAT --> LLMVPC
  RAG --> LLMVPC
  LLMVPC --> FIRE
  FIRE --> TW
  FIRE --> LOB
  FIRE --> SG
  FEAT --> SNOW --> REDIS --> UI
```

---

## 2) Technical Tradeoffs by Version

### V1 (Breadboard)
- **Primary optimization:** Lowest cost, deterministic behavior, simple fault recovery.
- **Tradeoff:** Manual ingestion and static model weights restrict scalability and adaptation.

### V2 (Microcontroller)
- **Primary optimization:** Automated nightly operations and write-back visibility without CRM API fees.
- **Tradeoff:** Still batch-bound and eventually exposed to model drift.

### V3 (Superscalar)
- **Primary optimization:** Margin expansion via omnichannel routing + continuous learning.
- **Tradeoff:** Increased platform complexity, cloud cost, and governance burden (SOC-2, MLOps controls).

### V4 (SoC Streaming)
- **Primary optimization:** Real-time activation with identity resolution and semantic matching.
- **Tradeoff:** Operationally heavy distributed systems (Kafka/Flink/Neptune + private LLM lifecycle).

### V5 (Market Maker)
- **Primary optimization:** Macro-scale subsidy routing and ecosystem-level optimization.
- **Tradeoff:** High systemic/legal risk concentration and strict SLA/regulatory requirements.

---

## 3) Relational Schema (PostgreSQL OLTP)

```sql
-- Core identity
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

CREATE TABLE vehicles (
  id BIGSERIAL PRIMARY KEY,
  vin TEXT UNIQUE NOT NULL,
  year INT,
  make TEXT,
  model TEXT,
  trim TEXT,
  msrp_cents BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE ownership_events (
  id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customers(id),
  vehicle_id BIGINT NOT NULL REFERENCES vehicles(id),
  event_type TEXT NOT NULL CHECK (event_type IN ('PURCHASE','LEASE','SERVICE')),
  event_ts TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- Model output + campaign state
CREATE TABLE propensity_scores (
  id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customers(id),
  model_version TEXT NOT NULL,
  score NUMERIC(5,4) NOT NULL CHECK (score >= 0 AND score <= 1),
  feature_snapshot JSONB NOT NULL,
  scored_at TIMESTAMPTZ NOT NULL DEFAULT now()
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
CREATE TABLE channel_dispatches (
  id BIGSERIAL PRIMARY KEY,
  offer_id BIGINT NOT NULL REFERENCES campaign_offers(id),
  provider TEXT NOT NULL CHECK (provider IN ('LOB','TWILIO','SENDGRID','SES_ADF')),
  provider_message_id TEXT,
  tracking_uuid UUID,
  status TEXT NOT NULL,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE qr_scans (
  id BIGSERIAL PRIMARY KEY,
  tracking_uuid UUID NOT NULL,
  scanned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  user_agent TEXT,
  ip INET,
  redirect_url TEXT NOT NULL
);

CREATE INDEX idx_scores_customer_scored_at ON propensity_scores(customer_id, scored_at DESC);
CREATE INDEX idx_cooldown_customer_channel ON cooldown_ledger(customer_id, channel);
CREATE INDEX idx_dispatch_tracking_uuid ON channel_dispatches(tracking_uuid);
```

---

## 4) Terraform Starter (V1/V2 Batch-First, No CRM API Sync)

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
  schedule_expression = "cron(0 2 * * ? *)" # 02:00 UTC daily
}

resource "aws_cloudwatch_event_rule" "print_run" {
  name                = "${var.project}-print-run"
  schedule_expression = "cron(0 9 ? * MON *)" # weekly example
}

resource "aws_ecs_cluster" "etl" {
  name = "${var.project}-etl"
}

resource "aws_iam_role" "step_functions_role" {
  name = "${var.project}-sfn-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "states.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.project}-pipeline"
  role_arn = aws_iam_role.step_functions_role.arn
  definition = jsonencode({
    Comment = "AutoCDP batch pipeline",
    StartAt = "RunETL",
    States = {
      RunETL = {
        Type     = "Task",
        Resource = "arn:aws:states:::ecs:runTask.sync",
        Next     = "Score"
      },
      Score = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Next     = "GuardrailAndDispatch"
      },
      GuardrailAndDispatch = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        End      = true
      }
    }
  })
}

resource "aws_rds_cluster" "aurora_pg" {
  cluster_identifier = "${var.project}-aurora"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  master_username    = "autocdp"
  master_password    = "replace_me_securely"
  skip_final_snapshot = true
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
## 5) Implementation Guardrails Checklist (Non-Negotiable)

1. **Batch-first (V1-V3):** No synchronous high-QPS ingestion architecture.
2. **No direct CRM API reads/writes:** Read via aggregator drops; write via SES + ADF XML.
3. **Deterministic legal firewall:** Every generated APR/payment must be recalculated and schema-validated before actuation.
4. **Cooldown enforcement first:** Must block prior to channel dispatch.
5. **State/compute decoupling:** Persisted ledgers and model outputs remain queryable/auditable independent of execution layer.

