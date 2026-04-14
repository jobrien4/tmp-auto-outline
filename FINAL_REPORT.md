# AutoCDP Final Report (Stakeholder Version)

## Direct answer to your question
You should read **this file** for the final narrative report, and use `AUTOCDP_ARCHITECTURE_OUTPUT.md` for the full technical diagrams and build artifacts.

If diagrams do not render in your markdown viewer, open the file directly in GitHub or a Mermaid-compatible markdown renderer.

---

## Version-by-Version Pipeline (Scale, Revenue, and Operating Model)

| Version | Dealers | Revenue Target | Operating Model |
|---|---:|---:|---|
| V1 | 1–5 | $0–$1M ARR | Concierge async batch |
| V2 | 5–50 | $1M–$9M ARR | Automated cron batch |
| V3 | 50–500 | $9M–$90M ARR | Batch + MLOps + omnichannel |
| V4 | 500–5,000+ | $100M–$500M+ ARR | Streaming SoC activation |
| V5 | 5,000–20,000+ | $500M+ ARR | National market-maker layer |

---

## End-to-End How the System Works at Each Stage

### V1
1. GM uploads historical CRM files to S3.
2. Step Functions runs ETL and dedupe into Aurora Postgres.
3. Frozen XGBoost scores customer propensity.
4. LLM drafts offer; deterministic Reg Z guardrail validates math.
5. Lob sends direct mail; QR scans close attribution loop.

### V2
1. Aggregators drop nightly deltas to S3 automatically.
2. EventBridge schedules nightly sync and print cycles.
3. Cooldown ledger blocks over-contact before actuation.
4. SES sends ADF XML write-back notes into legacy CRM inbox.
5. GMs monitor approval/spend in self-serve UI.

### V3
1. DMS replicates OLTP events to Snowflake OLAP.
2. SageMaker retrains scoring models monthly.
3. Router picks print/SMS/email based on cost and conversion policy.
4. Reg Z validation remains a hard pre-dispatch gate.
5. Enterprise analytics are served from Snowflake at scale.

### V4
1. Pixel and partner events stream via Kafka/MSK continuously.
2. Flink + Neptune resolve identity graph in near real time.
3. Private LLM uses inventory context from vector retrieval.
4. Deterministic legal engine validates terms and channels dispatch instantly.
5. Command center reflects live performance via Redis materialized views.

### V5
1. OEM and bank subsidy feeds enter optimization core.
2. RL allocator distributes incentive capital by demand/constraints.
3. Regulatory engine enforces legal math/terms globally.
4. Activation network executes across thousands of dealerships.
5. Platform behaves as a macro automotive demand-shaping layer.

---

## Mandatory Controls (All Versions)
- No direct CRM API write-back in V1–V3 (SES + ADF XML only).
- No outbound actuation without deterministic Reg Z validation.
- Cooldown checks happen before every send.
- State remains auditable and decoupled from execution workers.

