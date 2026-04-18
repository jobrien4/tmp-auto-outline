# AutoCDP V1 — Architecture Decision Log

This document records every significant technology choice made for V1,
the reasoning behind each choice, the alternatives considered, and how
each decision positions the system for V2 and V3 evolution.

---

## Decision 1: Aurora PostgreSQL Serverless v2 vs DynamoDB

### Decision
Primary operational data store: **Amazon Aurora PostgreSQL Serverless v2**.

### Alternatives considered
- **Amazon DynamoDB**: Pay-per-request at zero scale, no minimum ACU charge.
- **Amazon RDS PostgreSQL (provisioned)**: Requires constant minimum instance.
- **PlanetScale / Neon / Supabase**: Not native to AWS ecosystem.

### Why Aurora Serverless v2

**Schema-per-dealer isolation is a first-class requirement.** DynamoDB has no concept of
schema isolation. Implementing dealer isolation in DynamoDB requires either separate tables
per dealer (50 dealers x 7 tables = 350 DynamoDB tables) or composite partition key schemes
with careful application-layer enforcement. Both are error-prone and difficult to audit.

**Relational queries are intrinsic to the problem.** The Selection Lambda must join
`propensity_scores` with `cooldown_ledger` to produce a single eligibility result set.
The Metrics API must aggregate across `campaign_ledger` with time range filters and status
breakdowns. These are trivially expressed in SQL and painful in DynamoDB.

**Metabase requires SQL.** The analytics requirement is to connect Metabase directly to the
data store. Metabase speaks SQL; it does not speak DynamoDB.

**ACU math at V1 scale.** At 0.5 ACU minimum (~$0.06/hour), Aurora Serverless v2 costs
~$43/month at minimum capacity. Batch workloads burst to 2-4 ACUs during ETL (~10-20 minutes)
and fall back immediately. Total Aurora cost: ~$50-80/month for 1-5 dealers.

### V2/V3 implications
Aurora Serverless v2 scales to 128 ACUs. V3 cross-schema analytical queries for ML retraining
are possible on a single cluster. The read replica feeds Metabase without impacting writes.
CDC replication (Aurora -> DMS -> S3 -> Snowflake) is a standard AWS pattern for V3.

---

## Decision 2: AWS ECS Fargate vs AWS Lambda for ETL

### Decision
ETL processing: **AWS ECS Fargate** with a dedicated task definition.

### Alternatives considered
- **AWS Lambda**: Zero infrastructure overhead, but 15-min timeout and 10 GB storage limit.
- **AWS Glue**: Managed Spark ETL; heavy, slow cold start, expensive for small jobs.
- **EC2 Spot + SQS**: Cost-efficient but requires managing instance lifecycle.

### Why Fargate for ETL

**Lambda has a 15-minute maximum execution timeout.** A dealer CSV with 50k-200k rows loaded
into Polars, normalized, deduplicated, and written to Aurora in batch upserts will run for
5-20 minutes. A particularly dirty file could exceed 15 minutes. Fargate has no timeout.

**Lambda has a 10 GB memory limit.** Polars is memory-efficient but not free. A 200k-row CSV
with 30 columns can peak at 2-4 GB working memory. Fargate at 4 vCPU / 8 GB for a 20-minute
task costs ~$0.053/run vs ~$0.80/run for a 4 GB Lambda.

**Docker packaging is reusable.** The Fargate image includes Polars, psycopg3, and data
normalization libraries. V2 adds VIN decoding and address standardization — same image pattern.

**Step Functions integrates natively** via `arn:aws:states:::ecs:runTask.sync`, which submits
a task and waits for completion synchronously.

### TPS math
- Max concurrent ETL tasks: 5 (one per dealer)
- Aurora burst during upserts: ~50 TPS for 10-30 seconds
- Aurora at 1 ACU handles ~200 TPS for simple INSERTs — no bottleneck

---

## Decision 3: Polars vs Pandas for ETL

### Decision
DataFrame library: **Polars**.

### Alternatives considered
- **Pandas**: Industry standard, vast ecosystem.
- **DuckDB**: Excellent for aggregations, not ideal for row-level UDF cleaning.
- **PySpark**: Overkill at V1 scale.

### Why Polars

**Memory efficiency.** Polars uses Apache Arrow columnar layout internally. For 200k rows,
it uses 40-60% less peak memory than Pandas for the same operations. This reduces Fargate
memory cost.

**Performance.** Polars operations are compiled Rust executing on all available cores. On a
4 vCPU Fargate task, Polars uses all 4 cores automatically. Pandas is single-core for most
operations (GIL-constrained). 3-8x speedup in practice at 200k rows.

**Lazy evaluation.** Polars' `LazyFrame` allows the entire cleaning pipeline to be expressed
as a computation graph that is optimized (predicate pushdown, projection pruning) before
executing.

**Type safety.** Polars enforces schema types at load time. Attempting to normalize a `Utf8`
column as `Int64` raises an exception at the operation, not silently coercing to `NaN`.

### Trade-off
Smaller ecosystem than Pandas. Acceptable because V1 ETL logic is straightforward (normalize,
hash, deduplicate, upsert). No scikit-learn integration needed in ETL — that lives in the
Scoring Lambda.

### V2/V3 implications
Polars' streaming mode (processing files larger than RAM in chunks) becomes relevant in V3
when dealer datasets grow. The API is the same; switching to streaming requires changing
`collect()` to `sink_*()`.

---

## Decision 4: Schema-Per-Dealer vs Row-Level Security

### Decision
Multi-tenancy model: **schema-per-dealer** in a single Aurora cluster.

### Alternatives considered
- **Shared tables with RLS**: Single set of tables; PostgreSQL row-level security policies.
- **Separate Aurora cluster per dealer**: Maximum isolation; independent scaling.

### Why schema-per-dealer

**Operational data isolation is a business requirement.** Competing automotive dealer groups
sharing a database is a data-leak-away from a business-ending event. Schema isolation provides
defense-in-depth: a bug must both (a) incorrectly set `search_path` AND (b) execute a query
to access another dealer's data.

**RLS is footgun-prone.** Policies must be applied to every table, verified on every new table,
and work correctly with every query plan. A new developer adding a UNION without understanding
RLS can silently bypass it. Schema isolation is passive — requires no per-query attention.

**Separate clusters are expensive.** ~$43/month minimum per dealer at V1. More importantly,
each cluster requires its own endpoint, Secrets Manager entry, security group, and monitoring.
Schema provisioning takes one SQL function call; cluster provisioning takes 15+ minutes and
Terraform.

**V3 cross-dealer ML training works.** A single `UNION ALL` across `dealer_*.campaign_ledger`
on a shared cluster. Alternatively, CDC replicates all schemas into a unified S3 data lake
(the V3 architecture). Schema-per-dealer does NOT prevent cross-dealer analytics.

---

## Decision 5: AWS Step Functions vs Apache Airflow (MWAA)

### Decision
Pipeline orchestration: **AWS Step Functions (Standard Workflows)**.

### Alternatives considered
- **Amazon MWAA (Airflow)**: Industry-standard DAG orchestration; Python-native; rich UI.
- **AWS EventBridge Pipes + SQS**: Lightweight; no state management.
- **AWS Batch + SQS**: Good for heavy compute; complex to coordinate.

### Why Step Functions

**Zero infrastructure overhead.** MWAA requires minimum $300-800/month for the smallest tier
running 24/7. V1 pipelines run at most once per day per dealer. A full pipeline run costs
~$0.05 in Step Functions fees. MWAA at V1 volume would be 50-90% of the monthly cloud budget.

**Native AWS integrations.** First-class sync integration with ECS RunTask (`.sync` pattern),
Lambda Invoke, and S3 — all used in V1. Retry, error propagation, and state serialization
handled without custom code.

**Map state for parallel generation.** The Generation and Dispatch stages process one campaign
per eligible record. Map state runs up to N concurrent Lambda invocations over an array of
record IDs without fan-out code. Airflow would require custom dynamic task mapping.

**Execution history.** Full state transition history for 90 days. Debugging a failed pipeline
means clicking the execution and reading the exact failing payload.

### V2/V3 implications
In V2, Step Functions is triggered by EventBridge Scheduler on a nightly cron. Structure
unchanged. In V3, if pipeline complexity requires cross-pipeline dependencies, MWAA can be
added — Step Functions remains the operational execution backbone.

---

## Decision 6: Pydantic Compliance Firewall Design

### Decision
FTC Reg Z enforcement: **deterministic Python rules engine using Pydantic v2 with `Decimal`
arithmetic, embedded in the Generation Lambda**.

### Alternatives considered
- **Separate compliance microservice**: Dedicated container/Lambda; HTTP call per offer.
- **Database-layer constraints**: PostgreSQL CHECK constraints on stored values.
- **Post-hoc audit**: Log LLM outputs and audit later; don't block dispatch.

### Why embedded deterministic engine

**Post-hoc audit is legally unacceptable.** Reg Z requires disclosures be accurate at time of
dissemination. A system that sends and then audits has already disseminated non-compliant offers.

**Database constraints are insufficient.** PostgreSQL can verify APR is positive and in-range,
but cannot independently recompute APR from principal/rate/term. The compliance requirement is
computational, not range-based.

**A separate service adds latency and failure modes.** Each record making an HTTP call adds
~50-200ms plus availability dependency. At V1 scale this is manageable, but the complexity
is unjustified when the firewall is a pure Python function.

**Pydantic v2 + Decimal is the right tool.** Three responsibilities:
1. Parse and validate LLM output into typed `OfferDraft` Pydantic model.
2. Recompute APR from `principal`, `rate`, `term` using Python `Decimal` (not float).
   Compare to `offer_draft.apr` within +/-0.001 percentage points.
3. Verify all required Reg Z disclosure strings are present.

**The `instructor` library constrains LLM output shape.** Forces LLM to emit JSON conforming
to the `OfferDraft` schema via structured outputs. Eliminates parsing failures. The compliance
engine validates the structured output against financial rules, not text patterns.

**Every decision is logged before return.** Pass or fail, the Lambda writes to
`compliance_audit_log` with full input context, LLM output, and field-level compliance result.
This log is the regulatory audit trail. Write-only from application code.

### V2/V3 implications
V3 adds SMS (160 chars) and email formats. The `OfferDraft` Pydantic model gains a `channel`
discriminator and channel-specific schemas. APR verification is identical across channels.

---

## Decision 7: LLM Provider Abstraction Layer

### Decision
LLM integration: **provider-agnostic abstraction using `instructor`**, supporting OpenAI,
Anthropic, and AWS Bedrock as interchangeable backends.

### Alternatives considered
- **Direct OpenAI SDK**: Simplest; tight coupling.
- **AWS Bedrock only**: Stays in AWS; IAM auth; no external API calls.
- **Custom per-provider routing**: Different prompts per provider.

### Why provider-agnostic

**LLM pricing and quality are moving targets.** The best price-performance ratio for structured
offer generation changes quarterly. Tight coupling creates avoidable switching costs.

**`instructor` provides abstraction for free.** Wraps OpenAI, Anthropic, and Bedrock clients
with a unified interface that accepts Pydantic schemas and returns validated instances. Switching
providers requires one line of code and one environment variable.

**Bedrock provides data residency guarantees.** For dealers requiring no data leave AWS, Bedrock
models allow the same `instructor`-wrapped structured output without external API calls. A
deployment-time configuration change, not a code change.

**Cost per offer at V1 scale.** GPT-4o mini: ~$0.0003/offer. At 25k offers/month = ~$7.50/month.
GPT-4o: ~$0.05/offer = ~$1,250/month. V1 defaults to cost-conscious models with per-dealer
override via `config_json.llm_model_override`.

---

## TPS and Capacity Summary

| Workload | Sustained TPS | Burst TPS | Bottleneck | Headroom |
|---|---|---|---|---|
| ETL Aurora upserts | <1 | ~50 (10-30 sec) | Aurora ACU | Bursts to 128 ACU |
| Scoring Lambda writes | <1 | ~10 | Lambda concurrency | Default 1,000 |
| Generation Lambda | <1 | ~10 (Map state) | LLM API rate limits | Per-provider quotas |
| Dispatch Lambda (Lob) | <1 | ~5 | Lob.com rate limit | 100 req/sec |
| QR scan reads | 0.1 avg | ~5 | FastAPI/Fargate | Auto-scales |
| Metabase queries | ~0.01 | ~1 | Aurora read replica | Scales with primary |

All V1 workloads are batch-oriented. No sustained high-concurrency pattern exists.

---

## Cost Breakdown (Monthly, V1: 1-5 Dealers)

| Component | Monthly Cost | Notes |
|---|---|---|
| Aurora Serverless v2 | $50-80 | 0.5 ACU min; burst during batch |
| ECS Fargate (ETL) | $5-15 | Per-task billing; idle = $0 |
| Lambda (all functions) | $1-5 | Per-invocation; low batch volumes |
| Step Functions | $1-3 | $0.025 per 1,000 state transitions |
| S3 (storage + requests) | $2-5 | CSV uploads + model.pkl |
| API Gateway | $1-3 | HTTP API pricing |
| ECS Fargate (QR service) | $15-30 | Minimum always-on task |
| Metabase (t3.small EC2) | $15-20 | ~$0.02/hr |
| Secrets Manager | $2-5 | Per secret per month |
| CloudWatch / X-Ray | $5-10 | Logs, traces |
| Data transfer | $2-5 | S3 -> Fargate, Aurora -> Lambda |
| LLM API (GPT-4o mini) | $5-10 | ~25k offers/month |
| **Total** | **~$104-191/mo** | Well within $300-700 target |

Lob.com print costs (~$1.00/piece) are passed through to dealer budgets, not AutoCDP margins.
At 5 dealers x 10k pieces/month = $50k/month in print, all passed through.
