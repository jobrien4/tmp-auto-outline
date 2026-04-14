# AutoCDP Final Architecture Report

## What this is
This is the **final, human-readable report** distilled from the technical blueprint and implementation artifact file.

- If you are an executive or stakeholder: read this file first.
- If you are engineering/AI tooling: use `AUTOCDP_ARCHITECTURE_OUTPUT.md` as the implementation source.

---

## Executive Summary
AutoCDP should be executed as a **batch-first, fault-tolerant activation platform** through V1–V3, then upgraded to a streaming SoC architecture in V4+. The core moat is not just ML scoring, but the combination of:
1. Neutral-bus ingestion from aggregator drops (avoiding CRM API tolls).
2. Deterministic FinTech guardrails (Reg Z-safe outputs only).
3. Cooldown ledger gating prior to any channel send.
4. Closed-loop attribution via campaign ledger + QR/dispatch telemetry.

This sequence minimizes legal/operational risk while maximizing speed-to-revenue.

---

## Recommended Operating Mode by Version

### V1 (1–5 dealers)
- Concierge onboarding via S3 upload + Step Functions + Fargate ETL.
- Frozen XGBoost model inference.
- Reg Z firewall required before Lob send.
- Goal: prove ROI and legal safety.

### V2 (5–50 dealers)
- EventBridge nightly automation + bi-weekly print cadence.
- SES ADF XML write-back to CRM inboxes (no direct CRM API write).
- GM self-serve dashboard for approvals and spend visibility.
- Goal: remove human-in-the-loop and scale margin-positive SaaS.

### V3 (50–500 dealers)
- Add Snowflake OLAP + DMS replication.
- Add SageMaker retrain flywheel and omnichannel router.
- Preserve OLTP/OLAP separation to keep UI and operations stable.
- Goal: protect margin while improving conversion quality.

### V4+ (500–5,000+ dealers)
- Move to Kafka/Flink/Neptune + private LLM stack.
- Keep deterministic legal firewall as a hard gate.
- Goal: real-time activation and identity-resolved orchestration.

---

## Non-Negotiable Controls
1. **No direct CRM read API dependence** in V1–V3.
2. **No direct CRM write APIs** in V1–V3; use SES + ADF XML.
3. **No raw LLM output may actuate** without deterministic Reg Z validation.
4. **Cooldown ledger checks are mandatory pre-dispatch** across all channels.
5. **State is auditable and decoupled** from execution workers.

---

## 90-Day Execution Plan

### Days 0–30
- Stand up V1 baseline infra (S3, Step Functions, Fargate ETL, Aurora, SES).
- Implement canonical Postgres schema and ingestion contracts.
- Implement Pydantic Reg Z validator and unit tests.

### Days 31–60
- Productionize campaign ledger + cooldown service.
- Launch first dealer pilot with direct-mail attribution.
- Add dashboard MVP read model.

### Days 61–90
- Integrate nightly aggregator drops (V2 motion).
- Enable SES ADF write-back and CRM note visibility.
- Run cohort analysis and ROI scorecard.

---

## What to read next
- Technical implementation artifact: `AUTOCDP_ARCHITECTURE_OUTPUT.md`
- This final stakeholder report: `FINAL_REPORT.md`

