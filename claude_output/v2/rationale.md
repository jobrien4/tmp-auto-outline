# AutoCDP V2 — Architecture Decision Log

---

## Decision 1: Authenticom / Motive vs Direct CRM API Integration

### Decision
Data extraction: **neutral 3rd-party aggregators** (Authenticom, Motive Retail) via nightly S3 batch drops.

### Alternatives considered
- **Direct CDK/Reynolds API**: Real-time access but $50k+ upfront certification + $2k-5k/month ongoing.
- **FullPath CDP API**: Modern REST API but exposes our client list to a competitor pivoting into marketing.
- **Dealership IT-managed SFTP exports**: Low cost but requires each dealership to configure and maintain.

### Why neutral aggregators

**Cost avoidance is existential at this stage.** CDK certification alone ($50k+ upfront) would consume the first 3 months of a single dealer's revenue. At 5-50 dealers, the integration toll would be $250k-2.5M/year in pure licensing fees with zero value-add.

**Strategic protection.** Authenticom and Motive are pure-play data plumbers. They extract data from CRM systems for a flat fee ($200-500/dealer/month) and have no marketing product. They cannot and will not compete with us. FullPath, by contrast, is actively building marketing features. Using their API would expose our dealer relationships to a direct competitor.

**Reliability.** Aggregators have existing, certified connections to every major CRM. We inherit their certification without paying for it. Adding a new CRM type requires zero engineering work on our side.

**Format standardization.** Aggregators normalize output across CRM types. Whether the dealer uses CDK, Reynolds, or DealerTrack, we receive a consistent JSON schema. This eliminates per-CRM ETL branches.

### Cost math
Authenticom: ~$300/dealer/month. At 50 dealers = $15k/month. Against $750k/month revenue (50 x $15k) = 2% of revenue. Acceptable.

### V3 implications
The aggregator model scales linearly. At 500 dealers, aggregator costs are ~$150k/month against $7.5M/month revenue — still 2%. The S3 drop pattern also seeds the V3 data lake: raw aggregator files become the first layer of the unified S3 data lake.

---

## Decision 2: ADF XML via SES vs Other CRM Write-Back Methods

### Decision
CRM write-backs: **ADF XML payloads sent via AWS SES** to CRM lead routing email addresses.

### Alternatives considered
- **Direct CRM write API**: Requires certification + ongoing fees per vendor.
- **Zapier/webhook integration**: Third-party dependency; per-event pricing scales poorly.
- **Dealer-managed manual data entry**: Does not scale; defeats automation purpose.

### Why ADF XML via SES

**Zero integration cost.** Every major automotive CRM (CDK, Reynolds, DealerTrack, VinSolutions, DealerSocket) supports ADF XML email intake as a standard feature. It was created in 1999 as the universal format for internet lead routing. We repurpose this lead intake channel for internal note-taking.

**Silent injection.** The CRM receives the ADF XML email, parses it automatically, and creates a note on the customer record. The sales team sees the note. No one needs to know how it got there. The experience is seamless.

**SES cost.** $0.10 per 1,000 emails. At 50 dealers x 10k campaigns/month = 500k emails/month = $50/month. Negligible.

**Delivery tracking.** SES provides delivery notifications (via SNS), bounce tracking, and complaint handling. We store `ses_message_id` and `delivery_status` in `crm_writebacks` for audit.

### Risk
Some CRM systems may rate-limit or filter high-volume ADF XML emails. Mitigation: stagger sends over the print run window (not all at once). Monitor bounce rates per dealer. If a CRM blocks ADF intake, fall back to daily batch digest emails.

### V3 implications
The same ADF XML pattern works for SMS and email campaign write-backs in V3. The note template changes but the delivery mechanism is identical.

---

## Decision 3: Amazon EventBridge vs Airflow vs EC2 Cron

### Decision
Scheduling: **Amazon EventBridge Scheduler** for nightly sync and bi-weekly print run cron triggers.

### Alternatives considered
- **Apache Airflow (MWAA)**: Full DAG orchestration; $300-800/month minimum.
- **EC2 cron jobs**: Simple but requires instance management, monitoring, failover.
- **Lambda scheduled events**: Works but limited to 15-minute execution windows.

### Why EventBridge

**Zero infrastructure cost.** EventBridge Scheduler charges $1/million invocations. At 2 invocations/day (sync + print run check) = $0.00006/month. MWAA at minimum tier = $300-800/month for the same two cron jobs.

**Native Step Functions integration.** EventBridge rules can directly start Step Functions executions with structured JSON input. No intermediate Lambda needed.

**Reliability.** AWS-managed, 99.99% SLA. No EC2 instances to patch, restart, or monitor.

**Separation of concerns.** EventBridge is the clock; Step Functions is the orchestrator. EventBridge decides WHEN; Step Functions decides WHAT. This clean separation means changing the schedule requires zero code changes.

### V3 implications
V3 adds more scheduled events (monthly model retraining, weekly channel optimization). EventBridge handles unlimited rules at negligible cost. If V3 needs complex scheduling dependencies, MWAA can be added alongside EventBridge — they are complementary, not exclusive.

---

## Decision 4: AWS Cognito vs Auth0 vs Custom JWT

### Decision
Authentication: **AWS Cognito User Pools** with hosted UI for the dealer self-serve dashboard.

### Alternatives considered
- **Auth0**: Superior developer experience; $23+/month for B2B features.
- **Custom JWT with bcrypt**: Maximum control; significant development effort.
- **AWS IAM Identity Center (SSO)**: Enterprise-grade but overkill for dealer portals.

### Why Cognito

**AWS-native integration.** API Gateway validates Cognito JWTs natively without custom authorizer Lambdas. The `dealer_id` is embedded as a custom claim in the JWT, enabling row-level authorization in API handlers.

**Cost at V2 scale.** First 50,000 MAU free. At 50 dealers x 3 users/dealer = 150 MAU = $0/month. Auth0's equivalent B2B tier starts at $23/month and requires paid plans for custom claims.

**Hosted UI reduces frontend work.** Cognito provides a pre-built login, registration, and password reset flow. The Next.js dashboard redirects to the hosted UI for auth and receives tokens on callback. No custom auth forms.

**MFA support.** TOTP MFA is built into Cognito at no additional cost. Important for dealer GMs managing $50k campaign budgets.

### Trade-off
Cognito's customization is limited compared to Auth0. The hosted UI is functional but not pretty. For V2, this is acceptable — dealer GMs see the login screen for 5 seconds per session. If branding becomes important for enterprise sales (V3), a custom UI backed by the Cognito API can replace the hosted UI without changing the backend.

---

## Decision 5: Next.js vs Plain React SPA

### Decision
Dealer dashboard: **Next.js** deployed on Vercel (or AWS Amplify).

### Alternatives considered
- **React SPA (Vite)**: Simpler; requires separate API proxy; no SSR.
- **Remix**: Strong data loading patterns; smaller ecosystem.
- **Vue/Nuxt**: Equivalent capability; team preference for React ecosystem.

### Why Next.js

**API routes simplify backend-for-frontend.** Next.js API routes can act as a lightweight BFF (Backend-for-Frontend), handling Cognito token refresh, request aggregation, and response shaping without a separate Node.js server.

**SSR for dashboard load time.** The dashboard's first paint should show real data, not a loading spinner. Server-side rendering pre-fetches campaign metrics during page load. At 50 dealers, the dashboard query takes <50ms against Aurora read replica.

**Vercel deployment is zero-ops.** Push to Git, Vercel deploys. No EC2, no Docker, no load balancer configuration. At V2 scale (150 MAU), Vercel's free tier or $20/month Pro plan is sufficient.

**React ecosystem alignment.** The V3 CEO dashboard will be a more complex React application with charts, real-time updates, and multi-dealer views. Building on React/Next.js now means V3 extends the existing codebase rather than rewriting.

### Cost
Vercel Pro: ~$20/month (or AWS Amplify: ~$10-30/month). Negligible vs. building and operating a custom deployment pipeline.

---

## Decision 6: Delta Processing vs Full Reload

### Decision
Nightly ingestion: **incremental delta processing** (upsert changed records only).

### Alternatives considered
- **Full reload**: Drop and re-import all records nightly. Simple but wasteful.
- **CDC from aggregator**: Real-time change stream. Not available from Authenticom/Motive.

### Why delta processing

**Volume reduction.** A typical dealer has ~50k total records but only ~500 change per day (new sales, service visits, payment updates). Processing 500 rows vs 50k rows is 100x less compute, storage, and time.

**Score efficiency.** Only changed records need re-scoring. At 50 dealers x 500 changes = 25k re-scores/night vs 50 x 50k = 2.5M full re-scores. Lambda invocation costs drop proportionally.

**Audit trail preservation.** Full reload would require either DELETE + INSERT (losing `created_at` history) or complex diff logic. Delta processing with `ON CONFLICT DO UPDATE` preserves the original `created_at` and updates `updated_at`, maintaining a clean audit trail.

**Aggregator alignment.** Authenticom already provides delta-only exports as their default mode. We are aligned with the vendor's natural output format.

### Risk
If the aggregator's delta is incomplete (misses a change), the golden record becomes stale until the next delta includes it. Mitigation: run a weekly full reconciliation (compare our golden_records count against the aggregator's total count per dealer). Flag discrepancies for investigation.

---

## Decision 7: Bi-Weekly Print Cadence

### Decision
Print run frequency: **bi-weekly** (1st and 15th of each month).

### Why not daily or weekly?

**Postal delivery latency.** USPS First Class mail takes 3-7 business days. A customer who qualifies on Monday and receives mail on Friday could qualify again on Tuesday's run — resulting in overlapping mail in transit. The 45-day cooldown prevents this, but bi-weekly batching provides additional protection by grouping selections.

**Lob.com batch efficiency.** Lob offers volume discounts on batches >1,000 pieces. Bi-weekly batching at 50 dealers x ~250 eligible records/run = ~12,500 pieces per batch — well into discount territory. Daily runs of ~900 pieces would lose this discount.

**Budget governance.** Dealers approve monthly budgets. Bi-weekly runs allow the system to allocate ~50% of the budget per run, providing a natural checkpoint. If the first run consumes more budget than expected, the second run can be throttled.

**5k-10k monthly mail per dealer.** At 10k pieces/month/dealer, bi-weekly means ~5k per run per dealer. At 50 dealers = 250k pieces per print run. Lob's SLA handles this volume within 24 hours.

---

## TPS and Capacity Summary (V2: 50 Dealers)

| Workload | Sustained TPS | Burst TPS | Duration | Notes |
|---|---|---|---|---|
| Nightly sync ETL writes | ~5 | ~50 | 2-4 AM (2 hr window) | 50 dealers x 500 rows sequential |
| Nightly scoring | ~5 | ~25 | Following ETL | Only changed records |
| Print run selection | ~10 | ~50 | 3:00 AM (bi-weekly) | 50 dealers x eligible query |
| Print run generation | ~10 | ~20 | 3:00-4:00 AM | LLM API is bottleneck |
| Print run dispatch | ~5 | ~20 | Following generation | Lob API rate: 100/sec |
| SES ADF XML sends | ~5 | ~50 | Following dispatch | SES rate: 14/sec default |
| QR scan reads | ~1 avg | ~20 | Daytime hours | Seasonal peaks |
| Dashboard API reads | ~5 | ~20 | Business hours | 150 MAU, bursty |
| Aurora ACU | 1-2 idle | 4 peak | | Auto-scales |

---

## Cost Breakdown (Monthly, V2: 50 Dealers)

| Component | Monthly Cost | Notes |
|---|---|---|
| Aurora Serverless v2 | $200-800 | 1 ACU min; peaks during nightly sync |
| S3 (raw + processed) | $20-50 | 50 dealers x daily deltas |
| ECS Fargate (ETL) | $50-150 | Nightly tasks, ~3 min each |
| Lambda (all functions) | $10-30 | Scoring + selection + generation + dispatch |
| Step Functions | $5-10 | ~50 pipeline executions/month |
| EventBridge | <$1 | 2 cron rules |
| API Gateway | $10-30 | Dashboard + QR scan traffic |
| SES (ADF XML) | $5-10 | ~500k emails/month |
| ECS Fargate (QR service) | $30-60 | Always-on |
| Cognito | $0 | <50k MAU free tier |
| Next.js hosting | $20-50 | Vercel Pro or Amplify |
| Metabase | $15-20 | t3.small EC2 |
| Secrets Manager | $5-10 | Additional secrets for aggregator |
| CloudWatch / X-Ray | $10-30 | Logs, traces, alarms |
| LLM API | $1,000-5,000 | ~500k offers/month at scale |
| Aggregator fees | $10,000-25,000 | $200-500/dealer/month |
| **Total cloud** | **$1,380-6,250/mo** | Excluding aggregator |
| **Total all-in** | **$11,380-31,250/mo** | Including aggregator |
| **Revenue** | **$750,000/mo** | 50 dealers x $15k |
| **Cloud margin** | **>95%** | |
