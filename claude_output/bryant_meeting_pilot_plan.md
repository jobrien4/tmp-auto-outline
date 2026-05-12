# AutoCDP V1 Pilot — Pre-Data Execution Plan
**Prepared for: First Meeting with Bryant (Thursday)**
**Scope: V1 MVP (1-5 Pilot Dealerships), Months 1-3**

---

## 1. The Core Question

> *"How much of the V1 platform can we build before we have a single byte of real dealership data, and what do we need from Bryant (and the pilot dealership) to unlock the data-dependent work?"*

This document answers that question by separating V1 execution into two parallel tracks running side-by-side:

- **Track A — Build (no data required):** ~85% of the V1 platform can be implemented, tested, and deployed using synthetic data. We do not need to wait on Bryant or any dealership to start.
- **Track B — Data Acquisition (requires Bryant + Dealership):** The remaining 15% — primarily the trained propensity model and end-to-end validation — is blocked until we receive the first historical CRM export.

The strategy: **maximize Track A work in weeks 1-3 so that the moment Track B delivers data (target: end of week 3), the platform is ready to ingest it within 24 hours.**

---

## 2. Bryant's Role in the Critical Path

The single dependency that gates V1 launch is **the first historical CSV export from a pilot dealership.** Everything else can be built around it.

To get that export, Bryant needs to help unblock:

| Need | Who Owns | Timing |
|---|---|---|
| Identify the pilot dealership (1-3 candidates) | Bryant | Week 1 |
| Introduce executive sponsor at the dealership | Bryant | Week 1 |
| Identify dealership IT / CRM contact | Bryant + Sponsor | Week 1-2 |
| Approve mutual NDA + Data Processing Agreement | Bryant + Legal | Week 2 |
| Confirm CRM type (CDK, R&R, DealerSocket, VinSolutions) | Dealership IT | Week 1 |
| Approve initial dataset scope (fields, date range) | Dealership Privacy | Week 2 |
| Sign Statement of Work for pilot | Bryant + Dealership | Week 2 |
| Deliver first historical export | Dealership IT | Week 3 |

The earlier Bryant can move on the legal and dealership-relationship items, the earlier we get data, the earlier V1 goes live.

---

## 3. Track A — Work We Can Do With Zero Real Data

Everything in this section can begin Monday after the Thursday meeting. None of it requires Bryant's input beyond a green light to proceed.

### 3.1 AWS Foundation (Week 1)

| Component | Purpose | Data-Free Validation |
|---|---|---|
| AWS account hardening | Multi-account org, billing alerts, IAM baseline | N/A |
| VPC + subnets + KMS keys | Network isolation, encryption-at-rest baseline | N/A |
| S3 bucket: `autocdp-raw-vault` | Cold storage for historical CSVs | Upload synthetic CSVs |
| S3 bucket: `autocdp-processed` | Intermediate ETL outputs | Internal pipeline test |
| Aurora PostgreSQL Serverless v2 | Schema-per-dealer OLTP database | Provision `dealer_test` schema |
| Step Functions state machine | Pipeline orchestration | Run with synthetic events |
| EventBridge rules | Cron triggers (future) | Test with no-op targets |
| Secrets Manager | API keys, DB credentials | Store Lob/LLM keys when ready |
| CloudWatch + X-Ray | Observability + tracing | Validate against synthetic runs |

**Cost during this phase:** ~$80-150/month. Aurora minimum ACU + S3 storage + idle Lambda.

### 3.2 Application Layer (Weeks 1-2)

These are pure software-engineering tasks with no data dependency.

- **Database schema deployment.** Run V1 DDL (`v1/database_schema.sql`) — `dealers`, `golden_records`, `vehicles`, `propensity_scores`, `cooldown_ledger`, `campaign_ledger`, `qr_scans`, `compliance_audit_log`. Validate via `provision_dealer_schema()` against a `dealer_test` schema.
- **Pre-signed S3 upload endpoint** (`POST /api/v1/upload/presigned-url`). Bryant or the dealer IT person will use this to deliver the export when ready. Build and test it now.
- **Step Functions pipeline** (ETL → Score → Select → Generate → Dispatch). Wire up the state machine with stub Lambdas; replace stubs with real logic as each component is built.
- **ETL Fargate task.** Polars-based data normalization (column mapping, dedup, address standardization, VIN normalization). Test against **synthetic CSVs** that mimic CDK / R&R export formats (we have public CRM column inventories to copy from).
- **Compliance Guardrail** (Reg Z / Truth-in-Lending math validator). This is pure math — APR calculation, monthly payment validation, residual value formulas. **Build and unit-test exhaustively with no real data.** This is the highest-stakes piece of code in V1; we want it bulletproof before any letter is generated.
- **QR redirect service** (`GET /api/v1/scan/{tracking_uuid}`). FastAPI service on Fargate, logs scan to `qr_scans`, 302 redirects to dealer inventory URL. Test with fake tracking UUIDs.
- **Campaign API endpoints** (`GET /api/v1/campaigns/{dealer_id}`, etc.) per `v1/api_spec.yaml`. Populate with synthetic campaign records to exercise pagination + filters.
- **API key authentication.** V1 uses static per-admin API keys (Cognito JWT comes in V2). Implement and document the key rotation procedure.

### 3.3 AI / LLM Copy Generation (Weeks 1-3)

This is the only Track A item with notable risk because the LLM output quality is hard to evaluate without real customer profiles. We can still get 80% of the way there with synthetic data.

- **Build the Generation Lambda** using `instructor` + Pydantic schemas (per the V1 spec). Output is a structured `OfferDraft` with body text, APR, monthly payment, and term.
- **Prompt engineering against synthetic customer profiles.** Generate 200-500 fake customers spanning equity tiers, lease-end timing, credit profiles. Iterate prompts until the AI consistently produces compliant, dealership-appropriate copy.
- **Compliance Firewall integration.** The Generation Lambda's output is passed to the Compliance Guardrail (already unit-tested in 3.2) which mathematically validates the APR / payment math. If invalid, the system forces a regeneration. This loop can be fully tested with synthetic data.
- **Letter template (HTML/PDF) design.** Lay out the letterhead, dealer logo placeholder, QR code position, body text area, regulatory disclosure footer. Send test prints of synthetic letters to ourselves via Lob.com.

### 3.4 Print Fulfillment (Weeks 2-3)

- **Lob.com account setup.** Sandbox + production credentials. Verified sender addresses.
- **Print integration in Dispatch Lambda.** Submit synthetic letters end-to-end through Lob's sandbox. Validate the round-trip: PDF rendering, address handling, tracking ID storage.
- **Internal test sends.** Print 5-10 real synthetic letters to a team mailing address. Verify QR codes scan correctly, redirect to a test inventory URL, log scans in the database.

### 3.5 Propensity Model — Scaffolding Only (Weeks 2-3)

This is the one Track A item where we cannot finish without data, but we can do all the scaffolding:

- **Feature engineering pipeline.** Define and implement the feature extraction code: equity, months-since-purchase, lease-months-remaining, service-visit-count, etc. Run against synthetic data to validate the pipeline executes.
- **Training pipeline.** Build the XGBoost training script and Fargate task definition. Validate it can read from S3, train on a synthetic dataset, and serialize the model to S3.
- **Inference Lambda.** Build the Scoring Lambda that loads the model from S3 and produces propensity scores. Test with a stub model trained on synthetic data.
- **What we cannot do without real data:** Train a model whose predictions are actually meaningful. The XGBoost trained on synthetic data will produce scores, but they won't correlate with real conversion behavior. Real predictive accuracy is unlocked only when we have real historical sales outcomes (which we get with the first dealer export).

### 3.6 Compliance, Legal, and Documentation (Weeks 1-3)

This work runs in parallel with engineering. It feeds directly into the data-acquisition track.

- **Privacy policy and Terms of Service.** Public-facing legal pages.
- **Data Processing Agreement template.** Pre-negotiate the DPA we will ask the pilot dealership to sign. Cover purpose limitation, security controls, breach notification, data retention, sub-processor disclosure.
- **Mutual NDA template.** For the initial discovery conversations.
- **TCPA / CAN-SPAM / Reg Z compliance memo.** Document the legal basis for direct mail with QR attribution. (V1 is mail-only, so TCPA / CAN-SPAM don't directly apply, but Reg Z does for any financial offer.)
- **SOC 2 prep.** Inventory the controls we already meet (KMS at rest, IAM RBAC, CloudTrail audit logs, append-only `compliance_audit_log` table). Identify gaps for a future Type II audit.
- **Pilot Statement of Work.** Define deliverables, success metrics, timeline, dealer obligations.

### 3.7 Internal Tooling (Week 3)

- **Metabase deployment.** Connect to the Aurora read replica. Build the first dashboards using synthetic data: campaign funnel, QR scan rate, compliance pass rate, conversion rate.
- **Synthetic data factory.** A reusable script that produces realistic dealer CSVs at configurable scale (10, 1k, 50k rows). We use this for end-to-end testing and future demos.
- **Internal runbook.** Step-by-step procedure for what happens when the first real CSV lands in the vault.

---

## 4. Track B — Data Acquisition (Bryant-Dependent)

Parallel to Track A, the data-acquisition work runs as its own thread. It is mostly people-and-paperwork, not engineering.

### 4.1 Dealership Identification (Week 1)

- Bryant nominates 1-3 candidate pilot dealerships. Ideal characteristics:
  - 1,000-10,000 customer records (large enough to be meaningful, small enough to iterate fast)
  - Lease-heavy mix (highest opportunity for our offer math)
  - General Manager engaged on direct-mail attribution problem
  - IT / CRM administrator willing to do one CSV export per week
- Discovery call(s) with each candidate's exec sponsor. Establish: CRM type, customer count, marketing budget today, current attribution methodology.

### 4.2 Legal (Weeks 1-2)

- Send mutual NDA to candidate dealership(s).
- Send DPA template; align on data fields, retention period, sub-processors (Lob, LLM provider).
- Statement of Work covers: pilot duration (90 days), success metrics (mail conversion rate vs. baseline), monthly fee structure (or pilot at no charge), termination clauses.
- Insurance review if required by the dealership.

### 4.3 Data Discovery (Week 2)

This is where the dealership's IT person tells us what we are actually getting.

- **CRM type confirmation.** CDK, R&R, DealerSocket, VinSolutions, or other.
- **Field inventory.** What fields are exportable? Critical: customer name, address, phone, email (optional), vehicle VIN, lease start/end dates, original lease payment, current payment, service visit history, last contact date.
- **Export mechanism.** Can the dealer IT person produce a CSV from the CRM's reporting module? Or do we need to use an aggregator (Authenticom, Motive Retail) as a workaround? **Aggregator is V2 territory; for V1 we want a manual CSV export.**
- **Field-mapping document.** Map their CRM column names to our `golden_records` schema. This unblocks the ETL Lambda's column-mapping logic.
- **Sample/anonymized export.** Even before the DPA is signed, ask for a 10-row anonymized sample so we can validate the field-mapping pipeline.

### 4.4 First Real Data Delivery (Week 3)

The deliverable: a full historical CSV uploaded to the `autocdp-raw-vault` S3 bucket via our pre-signed URL flow.

- Dealer IT generates the export following our documented procedure.
- AutoCDP admin generates pre-signed URL via the `/api/v1/upload/presigned-url` endpoint (already live from Track A).
- Dealer IT uploads via the URL. Step Functions auto-triggers on the S3 ObjectCreated event.
- The pipeline runs end-to-end on real data for the first time.

---

## 5. Week-by-Week Plan

| Week | Track A (Build) | Track B (Data Acquisition) |
|---|---|---|
| **1** | AWS foundation provisioned. Database schema deployed. Pre-signed URL endpoint live. Compliance Guardrail math unit-tested. Synthetic data factory built. | Bryant nominates pilot dealerships. Mutual NDA sent to lead candidate. Discovery call scheduled. |
| **2** | ETL pipeline ingests synthetic CSVs. Generation Lambda + LLM prompts iterated. Letter template designed. Lob.com integration tested in sandbox. | NDA signed. DPA negotiated. CRM type + field inventory confirmed. Anonymized 10-row sample received. SOW drafted. |
| **3** | End-to-end synthetic pipeline runs cleanly: CSV → clean → score → generate → compliance → print. Internal test letters mailed. Metabase dashboards live. Model training pipeline ready (untrained). | **DPA + SOW signed. First real historical CSV delivered.** Field mapping validated against real columns. |
| **4** | Real CSV ingested via the Track A pipeline. Model trains on real historical data. Predictions backtested against known sales outcomes. Compliance review of AI-generated copy against real customer profiles. | Dealer feedback on letter template. Compliance contact at dealer reviews regulatory disclosures. |
| **5** | First pilot mail batch (50-200 letters) sent to a controlled subset. QR scan tracking live. Daily monitoring of compliance pass rate + LLM output quality. | Dealer GM reviews first results. AutoCDP admin generates first dealer-facing report. |
| **6** | Iterate on prompts, model thresholds, channel cost assumptions. Full pilot mail run (~1,000-5,000 letters). | First QR scans → ROI attribution → first piece of data the dealer has never had before. |

Weeks 4-6 are intentionally aggressive. If data slips to week 4, this whole timeline shifts by one week — but Track A work in weeks 1-3 is unaffected, so we still arrive at "ready to ingest" by week 3.

---

## 6. What I Need Bryant to Commit To on Thursday

These are the concrete asks for the Thursday meeting. Each unlocks part of the critical path.

1. **Identify the lead pilot dealership** (or commit to nominating it by end of week 1).
2. **Introduce me to the executive sponsor** at the pilot dealership within 5 business days.
3. **Approve the legal review path** — who reviews the NDA + DPA on our side, what turnaround time we are working with.
4. **Approve the AWS + LLM + Lob budget** for weeks 1-3 (~$500-1,500 total).
5. **Confirm the scope of the pilot SOW** — duration, success metrics, fee structure (free pilot vs. paid).
6. **Decide V1 channel scope.** Master roadmap says V1 is mail-only. Confirm we are not adding SMS or email until V2 (this materially affects compliance work — TCPA only applies if we send SMS).

---

## 7. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Dealership delays the CSV export (IT bottleneck) | Medium | High | Start with anonymized 10-row sample by end of week 2. Full export becomes a cleanup step. |
| CRM lacks key fields (no equity, no lease-end date) | Medium | High | Field inventory by end of week 2. If gaps exist, supplement with public valuation APIs (KBB, Black Book) or descope features. |
| LLM output quality fails compliance review | Low | Medium | Compliance Guardrail catches math errors deterministically; output review is for tone/format only. Build a manual override path for week-1 letters. |
| Lob print costs exceed budget assumptions | Low | Low | $1.00/letter is well-documented; budget covers known volume. |
| DPA negotiation drags 4+ weeks | Medium | High | Start the DPA conversation in week 1, not week 3. Have our template ready before the meeting. |
| Synthetic data doesn't represent real CRM messiness | Medium | Medium | Pull public CRM data dictionaries; intentionally inject messy patterns (typos, duplicate addresses, missing emails) into synthetic CSVs. |
| Real model performs worse than synthetic on backtest | High | Medium | Expected. V1 model accepts a lower bar (>60% precision at >0.70 score). V2/V3 retraining loop is the long-term fix. |

---

## 8. Acceptance Criteria for V1 Pilot Launch

V1 is "launched" when:

- One pilot dealership has delivered a real historical CSV.
- The CSV has been ingested, cleaned, scored, and selected.
- At least 50 letters have been generated, passed compliance review, printed via Lob, and dispatched.
- The QR redirect service is live and logging scans in production.
- The dealer GM has access to a Metabase dashboard showing campaign status.
- The Compliance Audit Log shows zero math-validation failures escaping to production.

The earliest realistic date for V1 launch, given a Thursday meeting and Bryant moving immediately on dealership intros: **end of Week 5 (~5 weeks from the meeting).**

---

## 9. Why This Plan Works

The architecture (per `v1/architecture.md`) is intentionally decoupled. Every component talks to others through well-defined contracts: S3 events, Step Functions state, Aurora schemas, API payloads. That means we can build the contracts, test them with synthetic data, and swap in real data on day one with high confidence.

We are not building software *and* waiting for data. We are building software *so that* the moment data arrives, V1 is ready.

The work that requires data — training the real propensity model and validating predictions against real outcomes — is concentrated in weeks 4-5, after the legal and discovery work is done. Everything before that is engineering, prompt iteration, and paperwork.

Bryant unblocks the paperwork. The engineering happens regardless.
