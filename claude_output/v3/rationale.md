# AutoCDP V3 — Architecture Decision Log

---

## Decision 1: Snowflake vs Redshift vs BigQuery vs Athena

### Decision
Enterprise analytics warehouse: **Snowflake**.

### Alternatives considered
- **Amazon Redshift Serverless**: AWS-native; tight IAM integration.
- **Google BigQuery**: Best price-performance on large scans; requires multi-cloud.
- **Amazon Athena**: Serverless SQL on S3; no materialized views, limited join performance.
- **ClickHouse Cloud**: Fast analytical engine; smaller ecosystem.

### Why Snowflake

**Separation of storage and compute.** Snowflake's architecture allows the CEO dashboard
queries to run on a dedicated XS warehouse that auto-suspends after 1 minute of inactivity.
AutoCDP pays $0 when no one is looking at the dashboard. Redshift Serverless charges per RPU-
second with a higher floor.

**External tables on S3.** Snowflake reads directly from our S3 data lake via external tables.
No data duplication — the Parquet files written by DMS are the single source of truth. Snowflake
caches frequently accessed data in its own storage layer automatically.

**Materialized views.** Snowflake supports materialized views that auto-refresh on a schedule.
The `campaign_performance` table refreshes every 15 minutes, pre-computing cross-dealer joins.
CEO dashboard queries hit pre-aggregated data, returning in <100ms. Athena cannot do this.

**Multi-cloud neutrality.** While AutoCDP runs on AWS, Snowflake's independence from AWS means
we are not locked into Redshift's ecosystem. If a V4 migration to GCP or Azure is ever
considered, Snowflake moves with us.

**Semi-structured data support.** JSONB fields from Aurora (feature_vector_json, compliance_
result_json) are natively queryable in Snowflake's VARIANT type. This enables ad-hoc analytics
on compliance patterns without ETL flattening.

### Cost at V3 scale
- XS warehouse: ~$2/credit, ~$50-200/month for sporadic CEO dashboard usage
- Storage: ~50 GB at $23/TB/month = ~$1.15/month
- Auto-refresh: ~$100-500/month depending on CDC volume
- **Total: ~$500-3,000/month** (highly variable with query volume)

### Why not Athena
Athena is attractive for its serverless simplicity, but:
- No materialized views — every dashboard load re-scans S3
- JOIN performance degrades with cross-table queries on Parquet
- No caching — repeated queries re-scan the same data
- At V3 query volumes (50+ concurrent CEO sessions), Athena costs would exceed Snowflake

---

## Decision 2: AWS DMS CDC vs Custom ETL to Lake

### Decision
Data lake ingestion: **AWS DMS Change Data Capture** from Aurora to S3.

### Alternatives considered
- **Custom Fargate job**: Read Aurora, write Parquet to S3 on a nightly schedule.
- **Debezium + Kafka**: Open-source CDC; overkill before V4.
- **Aurora S3 export**: Native `SELECT INTO S3` commands; not real-time.

### Why DMS CDC

**Near real-time replication.** DMS reads the Aurora WAL (Write-Ahead Log) and streams changes
to S3 within ~15 seconds. The CEO dashboard shows data that is at most 15 minutes old (after
Snowflake external table refresh). A custom nightly job would show data that is 24 hours old.

**Schema-agnostic capture.** DMS captures changes from ALL dealer schemas automatically. Adding
a new dealer requires zero DMS configuration — the replication task discovers new schemas
via its table mapping rules.

**Parquet output.** DMS writes directly to S3 in Parquet format, which Snowflake reads natively.
No intermediate format conversion needed.

**Managed service.** DMS handles WAL position tracking, checkpointing, and retry. A custom
Fargate job would need to implement all of this, including handling Aurora failovers (which
change the WAL position).

### Cost
dms.t3.medium replication instance: ~$50/month. S3 PUT requests: negligible (~$0.005 per 1,000).

---

## Decision 3: SageMaker Pipelines vs Custom MLOps

### Decision
ML retraining: **AWS SageMaker Pipelines** with spot training instances.

### Alternatives considered
- **Custom Step Functions pipeline**: Trigger Lambda → Fargate training → Lambda deploy.
- **MLflow on EC2**: Open-source MLOps; requires instance management.
- **Vertex AI (GCP)**: Best ML tooling; wrong cloud.

### Why SageMaker Pipelines

**Built-in model registry.** SageMaker tracks model versions, metrics, and deployment status
natively. The `model_versions` Aurora table mirrors this for application-layer queries, but
SageMaker provides the source of truth for artifact storage and lineage.

**Spot training instances.** SageMaker training jobs run on spot instances (ml.m5.xlarge at
$0.15/hr spot vs $0.23/hr on-demand). A 2-hour monthly training run costs ~$0.30. At 500
dealers with 25M training rows, this is exceptional value.

**S3 data lake integration.** SageMaker reads training data directly from the S3 data lake.
No data copying needed. The same Parquet files that feed Snowflake analytics also feed
model training.

**Conditional deployment.** The pipeline evaluates the new model against a holdout set and
only deploys if metrics improve. This prevents model regression — a critical safety feature
when the model controls millions of dollars in marketing spend.

### Why not custom Step Functions

A custom pipeline could work, but we would need to implement:
- Model versioning and artifact management
- Spot instance lifecycle handling
- A/B evaluation framework
- Conditional deployment logic

SageMaker provides all of these out of the box. The marginal cost ($0-10/month) is less than
the engineering time to build and maintain custom MLOps.

---

## Decision 4: XGBoost vs LightGBM vs Neural Networks

### Decision
Propensity model: **XGBoost** (V1-V2), transitioning to **LightGBM** evaluation in V3.

### Why gradient boosted trees (not neural nets)

**Tabular data.** The feature set is structured tabular data: equity amount, lease months
remaining, service visit count, days since purchase. Gradient boosted trees consistently
outperform neural networks on tabular data (see benchmarks from Grinsztajn et al., 2022).

**Interpretability.** Feature importance is directly available from tree models. The CEO
dashboard can show "top conversion drivers this month" without SHAP approximations.

**Training speed.** 25M rows x 10 features trains in ~30 minutes on XGBoost/LightGBM.
A neural network with similar accuracy would require hyperparameter tuning, GPU instances,
and 10-50x longer training time.

### Why evaluate LightGBM in V3

LightGBM uses histogram-based splitting which is faster on large datasets and handles
categorical features natively (no one-hot encoding needed for `crm_type`, `make`, etc.).
At 25M rows, the training speed difference becomes meaningful.

V3's SageMaker Pipeline trains both XGBoost and LightGBM in parallel and selects the
better-performing model automatically. This A/B evaluation runs monthly at near-zero cost.

---

## Decision 5: Channel Router — RL Bandit vs Heuristic Rules

### Decision
Channel routing: **heuristic rules with learned conversion rate priors**, evolving toward
contextual bandit in late V3.

### Why not full RL from the start

**Cold start problem.** V3 launches with zero historical data on SMS and email conversion
rates. A reinforcement learning agent with no priors would explore randomly — sending
expensive print to test email effectiveness. This wastes budget.

**Heuristic rules provide a safe default.** The initial router uses simple rules:
1. If only one channel is available (others on cooldown), use it.
2. If multiple channels are available, prefer the cheapest one that exceeds a minimum
   expected conversion threshold (initially set manually based on industry benchmarks).
3. Log every routing decision with the full evaluation context.

**Logged decisions enable offline learning.** The `channel_routing_log` table captures what
was available, what was selected, what it cost, and (eventually) whether it converted. After
3-6 months of logged decisions, a contextual bandit model can be trained offline on this data
and deployed as a warm-started policy.

### Evolution path
- **V3 launch (months 1-3)**: Heuristic rules. Cheapest available channel above 2% expected
  conversion rate.
- **V3 mid (months 4-6)**: Empirical conversion rates replace industry benchmarks. Rules
  use actual AutoCDP data.
- **V3 late (months 7-12)**: Contextual bandit (Thompson Sampling or UCB) trained on
  `channel_routing_log` data. Explores channel assignment with controlled randomization.

---

## Decision 6: Twilio vs Alternatives for SMS

### Decision
SMS dispatch: **Twilio**.

### Alternatives considered
- **Amazon SNS**: AWS-native; $0.00645/SMS; no delivery receipts, no conversation tracking.
- **Amazon Pinpoint**: Better marketing features; complex setup; AWS-only.
- **Vonage (Nexmo)**: Competitive pricing; smaller market share.

### Why Twilio

**Delivery receipts.** Twilio provides per-message delivery status callbacks (queued, sent,
delivered, failed, undelivered). We store `twilio_sid` and track delivery status for
attribution and write-back accuracy.

**10DLC compliance.** Twilio manages 10DLC (10-Digit Long Code) registration, which is
required for application-to-person SMS in the US. A2P 10DLC registration involves carrier
vetting and takes 2-4 weeks. Twilio handles the carrier relationships.

**Opt-out management.** TCPA requires a STOP mechanism. Twilio automatically handles STOP
replies and provides webhook notifications, which we use to update the cooldown_ledger with
a permanent opt-out.

**Cost.** $0.0079/outbound SMS + $0.01/phone number/month. At 500 dealers x 8k SMS/month =
4M SMS/month = ~$31,600/month. This is passed through to dealer budgets (like Lob print costs).

---

## Decision 7: SendGrid vs SES for Marketing Email

### Decision
Marketing email: **SendGrid**.

### Alternatives considered
- **Amazon SES**: Already used for ADF XML write-backs; $0.10 per 1,000 emails.
- **Mailgun**: Similar to SendGrid; less market share.
- **Postmark**: Focused on transactional email; not marketing.

### Why SendGrid (not SES) for marketing email

**SES is already used for ADF XML write-backs.** Mixing marketing email and CRM write-backs
on the same SES account risks reputation damage. If a dealer's customers mark AutoCDP marketing
emails as spam, SES could throttle or suspend the account — taking down the CRM write-back
channel.

**SendGrid provides dedicated IP and reputation management.** Marketing emails are sent from a
separate SendGrid account with its own IP reputation. CRM write-backs continue on SES
unaffected. This isolation protects the critical ADF XML channel.

**SendGrid analytics.** Open rates, click rates, bounce rates, and unsubscribe tracking are
built in. These feed back into the channel router as conversion signals.

**Cost.** SendGrid Pro: ~$90/month for 100k emails. At 500 dealers x variable email volume,
~$100-500/month. Passed to dealer budgets.

---

## Decision 8: Schema-Per-Dealer + Unified Data Lake

### Key insight
Schema-per-dealer in Aurora does NOT prevent cross-dealer ML training or analytics.

**The two-layer pattern:**

| Layer | Purpose | Isolation | Example |
|---|---|---|---|
| OLTP (Aurora) | Operational execution | Schema-per-dealer | `dealer_104.campaign_ledger` |
| Lake (S3 + Snowflake) | Analytics + ML training | Unified, partitioned | `campaign_ledger/dealer_id=104/` |

DMS CDC bridges the two layers automatically. Every write to any dealer schema is captured,
tagged with `dealer_id`, and written to the unified lake.

**Why this is better than a shared OLTP schema:**
- Operational isolation is maintained (blast radius, Metabase safety, offboarding)
- Analytics and ML get the full cross-dealer corpus
- No single-table bottleneck during nightly sync across 500 dealers
- Each dealer's Aurora schema can be independently backed up or restored

---

## Decision 9: SOC-2 Type II Implications

V3 targets enterprise auto groups (50-100 rooftops). These buyers require SOC-2 Type II
attestation. Key architectural controls:

| SOC-2 Control | V3 Implementation |
|---|---|
| Access control | Cognito RBAC + schema isolation + IAM per-service roles |
| Audit logging | compliance_audit_log (append-only), channel_routing_log, sync_history |
| Change management | SageMaker model registry with version tracking + conditional deploy |
| Data encryption | Aurora KMS, S3 SSE-KMS, Snowflake managed encryption |
| Availability | Aurora multi-AZ, Fargate multi-AZ, Snowflake cross-AZ replication |
| Incident response | CloudWatch alarms, SNS escalation, PagerDuty integration |
| Vendor management | Authenticom DPA, Lob DPA, Twilio DPA, SendGrid DPA |

---

## Decision 10: Why NOT Streaming Yet (V4)

V3 is the last batch-oriented version. The temptation to add Kafka or Kinesis in V3 is real
but premature:

- **500 dealers at nightly batch** = ~250k records/night total. A 2-hour processing window
  handles this at ~35 TPS sustained. No streaming needed.
- **Kafka operational complexity** is disproportionate to V3 scale. Managed Kafka (MSK) costs
  ~$2,000/month minimum for a 3-broker cluster. EventBridge + Step Functions handles V3
  scheduling for ~$10/month.
- **Streaming introduces consistency challenges.** With batch processing, the nightly sync is
  atomic per dealer — either it completes or it doesn't. With streaming, partial state windows
  require exactly-once semantics, watermarking, and late-arrival handling. This complexity is
  warranted only when V4's real-time intent matching requires sub-second latency.

**V4 is where streaming becomes mandatory:** real-time website pixel events, live inventory
matching, and sub-10-second SMS dispatch require Kafka/Flink/Neptune. V3 intentionally
avoids this complexity to maintain operational simplicity during the scale from 50 to 500
dealers.

---

## Cost Analysis: Digital Routing Margin Improvement

### Scenario: 500 dealers, 10k campaigns/month/dealer = 5M campaigns/month

| Channel Mix | Mail (%) | SMS (%) | Email (%) | Total Channel Cost/Month |
|---|---|---|---|---|
| V2 (all mail) | 100% | 0% | 0% | $5,000,000 |
| V3 conservative | 60% | 25% | 15% | $3,012,500 |
| V3 optimized | 30% | 40% | 30% | $1,521,500 |

### V3 conservative breakdown
- 3M mail x $1.00 = $3,000,000
- 1.25M SMS x $0.01 = $12,500
- 750k email x $0.001 = $750
- **Total: $3,013,250 — saving $1,986,750/month vs all-mail**

### Impact on unit economics
Channel costs are passed to dealer budgets. But cheaper channels mean:
- Dealers can run MORE campaigns per dollar of budget
- More campaigns = more conversions = higher dealer satisfaction = lower churn
- AutoCDP's $15k/month fee looks increasingly valuable as cost-per-conversion drops

---

## TPS and Capacity Summary (V3: 500 Dealers)

| Workload | Sustained TPS | Burst TPS | Window | Notes |
|---|---|---|---|---|
| Nightly sync writes | 30 | 500 | 2-4 AM | 500 dealers sequential |
| Nightly scoring | 20 | 250 | After sync | Changed records only |
| Campaign selection | 20 | 100 | 3 AM bi-weekly | All dealers |
| Channel routing | 20 | 200 | During campaign run | Per-record evaluation |
| Generation (LLM) | 10 | 50 | During campaign run | LLM API bottleneck |
| Dispatch (multi-channel) | 20 | 200 | During campaign run | Lob+Twilio+SendGrid |
| QR scan reads | 5 | 100 | Daytime | Seasonal |
| SMS webhook callbacks | 5 | 50 | Continuous | Twilio delivery status |
| Dashboard reads (Aurora) | 10 | 30 | Business hours | Dealer GM dashboards |
| Dashboard reads (Snowflake) | 5 | 20 | Business hours | CEO analytics |
| Aurora ACU range | | | | 4 idle / 16 peak |

---

## Monthly Cost Breakdown (V3: 500 Dealers)

| Component | Monthly Cost | Notes |
|---|---|---|
| Aurora Serverless v2 | $1,000-5,000 | 4-16 ACU |
| Snowflake | $500-3,000 | XS warehouse, auto-suspend |
| S3 (raw + lake) | $100-500 | ~200 GB total |
| DMS replication | $50-200 | dms.t3.medium |
| SageMaker | $5-50 | Monthly spot training |
| ECS Fargate (ETL + QR) | $500-2,000 | Nightly tasks + always-on QR |
| Lambda (all functions) | $50-200 | Scoring, routing, generation, dispatch |
| Step Functions | $20-50 | High state transition count |
| EventBridge | <$5 | 3 cron rules |
| API Gateway | $50-200 | Dashboard + QR + webhook traffic |
| SES (ADF XML) | $50-100 | 5M write-back emails/month |
| Cognito | $0 | Still under 50k MAU |
| Next.js hosting | $50-100 | Vercel Pro |
| CloudWatch / X-Ray | $50-200 | Expanded monitoring |
| Secrets Manager | $10-20 | Additional keys |
| LLM API | $5,000-20,000 | 5M generations/month |
| **Total cloud** | **$7,435-31,625/mo** | |
| Aggregator (Authenticom) | $100,000-250,000 | 500 dealers |
| **Total all-in** | **$107,435-281,625/mo** | |
| **Revenue** | **$7,500,000/mo** | 500 x $15k |
| **All-in margin** | **>96%** | |
