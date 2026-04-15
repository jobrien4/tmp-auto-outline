# AutoCDP Phases 1–2: Week-by-Week Engineering Implementation Plan

> **Purpose**  
> This document is an execution-grade delivery plan for **Phase 1 (V1 MVP)** and **Phase 2 (V2 SaaS Automation)**.  
> It is structured so a cross-functional engineering team can execute without ambiguity.

---

## 0) Delivery Assumptions and Team Topology

## Team Pods
- **Platform Pod:** AWS infra, networking, IAM, CI/CD, observability.
- **Data Pod:** ETL, schema, quality rules, dedupe, batch orchestration.
- **Intelligence Pod:** scoring service, feature store logic, model packaging, evaluation.
- **Activation Pod:** LLM integration, Reg Z guardrails, Lob/Twilio/SES adapters.
- **App Pod:** FastAPI redirect service, admin UI, auth, analytics pages.
- **QA/Security Pod:** test automation, threat modeling, release readiness.

## Non-Negotiable Controls (must hold every week)
1. No direct CRM read/write APIs in V1/V2.
2. Cooldown checks happen before every dispatch.
3. No outbound offer without deterministic Reg Z validation.
4. Every workflow step emits traceable audit metadata.

---

## 1) Definition of Done (DoD) by Phase

| Phase | DoD Summary |
|---|---|
| **Phase 1 (Weeks 1–12)** | Pilot-ready async batch pipeline: S3 upload -> ETL -> scoring -> guardrail -> Lob print -> scan attribution with dashboard visibility. |
| **Phase 2 (Weeks 13–48)** | Production SaaS automation: nightly SFTP ingestion, scheduled orchestration, CRM write-back via SES/ADF XML, self-serve approvals, and multi-tenant operational controls. |

---

## 2) Phase 1 (V1 MVP) — Weeks 1–12

## Week 1 — Program Foundation and Architecture Freeze
**Objectives**
- Freeze v1 architecture decisions and interfaces.
- Establish repo conventions, branching, and CI.

**Tasks**
- Write ADRs for: S3 ingest, Step Functions orchestration, Fargate ETL, Postgres schema, Lob integration, FastAPI scan service.
- Create mono-repo structure: `/infra`, `/services/etl`, `/services/scoring`, `/services/guardrail`, `/services/scan-api`, `/web/admin`.
- Configure CI: lint, unit test, security scan, IaC fmt/validate.

**Deliverables**
- Approved ADR set.
- Green CI baseline on default branch.

**Acceptance Criteria**
- All service folders build and test as empty scaffolds.
- CI gates block merge on failures.

## Week 2 — AWS Landing Zone and Core Infra
**Objectives**
- Provision foundational AWS resources for dev/stage.

**Tasks**
- Create VPC, private/public subnets, NAT, security groups.
- Provision S3 raw bucket + processed bucket + lifecycle policies.
- Provision Aurora Postgres (serverless), Secrets Manager, KMS keys.
- Create ECR repos for each service.

**Deliverables**
- Terraform/CDK stacks deployed to dev.

**Acceptance Criteria**
- Infra deploy reproducible via one pipeline command.
- Secrets never stored in plaintext in repo.

## Week 3 — Canonical Data Model and Migration System
**Objectives**
- Establish schema and migration discipline.

**Tasks**
- Implement tables: dealerships, customers, propensity_scores, cooldown_ledger, campaign_offers, channel_dispatches, qr_scans.
- Add migration tooling (Alembic/Flyway).
- Seed scripts for synthetic pilot data.

**Deliverables**
- Versioned DB migrations and ERD diagram.

**Acceptance Criteria**
- Fresh DB bootstrap passes in CI.
- Rollback tested for latest migration.

## Week 4 — S3 Upload Path + Presigned URL Service
**Objectives**
- Secure large file ingestion path.

**Tasks**
- Build API endpoint to mint presigned PUT URLs.
- Implement upload constraints (file type, max size, tenant prefix).
- Add object metadata tagging (dealer_id, upload_id, checksum).

**Deliverables**
- End-to-end upload from browser/client to S3.

**Acceptance Criteria**
- 3GB test file uploads without app server memory use.
- Invalid file types rejected with deterministic errors.

## Week 5 — ETL Service v1 (Polars)
**Objectives**
- Deterministic cleansing and normalization.

**Tasks**
- Implement parsers for CSV variants.
- Normalize phones, emails, addresses, name casing.
- Dedupe logic with configurable match thresholds.
- Write clean outputs to S3 and metadata to Postgres.

**Deliverables**
- Containerized ETL job with deterministic outputs.

**Acceptance Criteria**
- Golden-record tests pass on known dirty datasets.
- ETL job idempotent on retry.

## Week 6 — Workflow Orchestration (Step Functions)
**Objectives**
- Chain ingest -> ETL -> scoring -> activation states.

**Tasks**
- Define state machine with retries/backoff and dead-letter handling.
- Add failure alerts (CloudWatch + Slack/PagerDuty).
- Persist run history to Postgres execution table.

**Deliverables**
- Operational batch workflow in dev.

**Acceptance Criteria**
- Simulated transient failures auto-recover.
- Hard failures land in DLQ with actionable context.

## Week 7 — Scoring Service v1
**Objectives**
- Deploy static model inference path.

**Tasks**
- Package XGBoost model artifact in S3 with version metadata.
- Implement batch scoring service reading feature rows from Postgres.
- Save score + model_version + feature snapshot.

**Deliverables**
- Deterministic scoring pipeline integrated into state machine.

**Acceptance Criteria**
- Score range 0.0–1.0 enforced.
- Same input set yields identical outputs across runs.

## Week 8 — Guardrail Service (Reg Z)
**Objectives**
- Block illegal financial outputs before dispatch.

**Tasks**
- Implement Pydantic schemas for APR/payment/term structures.
- Build deterministic recalculation module.
- Wire LLM generation adapter and mandatory validation gate.

**Deliverables**
- Guardrail service with reject reasons and audit logs.

**Acceptance Criteria**
- Invalid outputs never pass to dispatch queue.
- All decisions written to immutable audit table.

## Week 9 — Lob Dispatch Adapter + Campaign Ledger
**Objectives**
- Physical mail actuation with robust status tracking.

**Tasks**
- Implement Lob API client with retries and idempotency keys.
- Persist outbound payload hash, provider IDs, tracking UUID.
- Add webhook/status polling for mailed/failed states.

**Deliverables**
- Reliable print dispatch path.

**Acceptance Criteria**
- Duplicate trigger does not send duplicate mail.
- Dispatch state transitions are complete and queryable.

## Week 10 — FastAPI Scan Service and Attribution
**Objectives**
- Complete closed-loop attribution path.

**Tasks**
- Build `/scan/{uuid}` endpoint with UUID lookup.
- Record scan telemetry (timestamp, user-agent, IP).
- Return HTTP 302 redirect to configured destination.

**Deliverables**
- Production-like scan and attribution flow.

**Acceptance Criteria**
- Unknown UUID safely handled (404 + no redirect).
- Valid UUID updates conversion funnel metrics.

## Week 11 — Pilot Admin UI + Operational Dashboards
**Objectives**
- Provide pilot operators visibility and controls.

**Tasks**
- Build pages: uploads, pipeline runs, campaign status, scans.
- Add role-based auth (admin/operator).
- Add KPI cards: sent, delivered, scanned, conversion proxy.

**Deliverables**
- Minimal but functional pilot UI.

**Acceptance Criteria**
- Non-engineering operator can run one complete campaign.
- Dashboard data latency < 5 minutes.

## Week 12 — Phase 1 Hardening and Pilot Release
**Objectives**
- Stabilize and release to 1–5 pilot dealerships.

**Tasks**
- Run load/perf test on ETL and scoring batch windows.
- Security review: IAM least privilege, secret rotation, audit coverage.
- Create runbooks: incident response, replay, backfill, rollback.

**Deliverables**
- Phase 1 release tag and production pilot rollout checklist.

**Acceptance Criteria**
- Critical severity vulnerabilities = 0.
- Pilot go-live signoff from engineering, product, and compliance.

---

## 3) Phase 2 (V2 SaaS Automation) — Weeks 13–48

## Week 13 — Multi-Tenant Model Introduction
**Tasks**: tenant scoping in all tables, row-level access patterns, tenant-aware service middleware.  
**Acceptance**: cross-tenant data leakage tests all pass.

## Week 14 — EventBridge Nightly Scheduler
**Tasks**: define nightly sync and bi-weekly print schedules per tenant timezone.  
**Acceptance**: jobs trigger correctly for at least 3 timezone scenarios.

## Week 15 — SFTP Intake Service Design
**Tasks**: choose SFTP partner contract; implement inbox polling spec and checksum verification.  
**Acceptance**: corrupted files quarantined and alerted.

## Week 16 — SFTP to S3 Connector Implementation
**Tasks**: deploy connector worker, key-based auth rotation, file manifest tracking.  
**Acceptance**: nightly deltas delivered to S3 with exactly-once manifest semantics.

## Week 17 — Delta ETL Pipeline
**Tasks**: incremental merge logic (upsert, soft-delete handling), schema drift handling.  
**Acceptance**: day-over-day delta replay yields deterministic final state.

## Week 18 — Cooldown Engine v2
**Tasks**: implement policy table (channel, lock period, exceptions), pre-dispatch gate API.  
**Acceptance**: blocked users never reach provider adapters.

## Week 19 — Approval Workflow Service
**Tasks**: add campaign budget approvals, approval SLAs, escalation notifications.  
**Acceptance**: unapproved campaigns cannot dispatch.

## Week 20 — SES + ADF XML Write-back Adapter
**Tasks**: build ADF XML template engine, SES sender identities, SMTP delivery monitoring.  
**Acceptance**: CRM test inbox parses and renders notes on sample records.

## Week 21 — Write-back Audit and Reconciliation
**Tasks**: log message-id, dealer routing address, payload hash; add daily reconciliation job.  
**Acceptance**: 99%+ match between sent events and CRM acknowledgments in test env.

## Week 22 — Retry and Backoff Framework Standardization
**Tasks**: shared retry lib for Lob, SES, future channels; classify transient vs permanent failures.  
**Acceptance**: failure classes produce expected retry behavior in chaos tests.

## Week 23 — Observability v2 (Metrics and Traces)
**Tasks**: distributed tracing across ETL/scoring/guardrail/dispatch, SLO dashboard creation.  
**Acceptance**: p95 step durations and error rates visible per tenant.

## Week 24 — Security Sprint 1
**Tasks**: threat model refresh, S3 bucket policy hardening, mTLS between internal services if applicable.  
**Acceptance**: security review closes all high findings.

## Week 25 — Self-Serve Dealer Onboarding Wizard
**Tasks**: dealer profile, credential setup, destination URLs, branding assets upload.  
**Acceptance**: new dealer onboarded in < 30 minutes without engineer support.

## Week 26 — Budget and Spend Controls
**Tasks**: per-tenant monthly caps, per-campaign max spend, soft/hard stop behavior.  
**Acceptance**: spend cannot exceed hard cap under retry storms.

## Week 27 — Campaign Segmentation Rules Engine
**Tasks**: rule builder for score thresholds, ownership windows, service recency filters.  
**Acceptance**: generated segment SQL audited and explain-plans accepted.

## Week 28 — Data Quality Monitoring
**Tasks**: field completeness scoring, anomaly detection on nightly deltas, alert thresholds.  
**Acceptance**: data quality incidents produce actionable alerts within 10 minutes.

## Week 29 — Performance Optimization Sprint
**Tasks**: tune DB indexes, partition large ledger tables, optimize ETL memory profiles.  
**Acceptance**: nightly run completes within agreed maintenance window.

## Week 30 — QA Automation Expansion
**Tasks**: add contract tests for provider adapters; end-to-end scenario suite in staging.  
**Acceptance**: regression suite runtime < 30 minutes, pass rate > 98%.

## Week 31 — Disaster Recovery and Backup Validation
**Tasks**: backup restore drills for Postgres, S3 version recovery exercises.  
**Acceptance**: RTO and RPO targets met in rehearsal.

## Week 32 — Billing and Usage Metering Foundations
**Tasks**: metering events for sends, scans, active records; invoice export format.  
**Acceptance**: billing report reconciles with dispatch ledger to within 0.5%.

## Week 33 — Compliance Reporting Pack
**Tasks**: exportable audit bundles (who/what/when/why) for offers and approvals.  
**Acceptance**: one-click compliance package generated per campaign.

## Week 34 — Partner Reliability Sprint
**Tasks**: fallback routes for SFTP outages, alternative contact channels for dealer alerts.  
**Acceptance**: simulated partner downtime does not block full nightly completion.

## Week 35 — Feature Flags and Progressive Delivery
**Tasks**: add launchdarkly/unleash flags by tenant and feature; staged rollout playbook.  
**Acceptance**: canary rollout rollback under 5 minutes.

## Week 36 — UX Improvements for Ops Teams
**Tasks**: queue management UI, failed-job replay tools, bulk action interfaces.  
**Acceptance**: ops can resolve standard incidents without developer intervention.

## Week 37 — Tenant SLA Policy Engine
**Tasks**: define SLA tiers, priority queues, throughput quotas by dealer group.  
**Acceptance**: tiered workloads enforce latency and throughput contracts.

## Week 38 — API Surface Hardening
**Tasks**: formalize OpenAPI specs, auth scopes, idempotency contract docs.  
**Acceptance**: API contract tests pass for all public/internal endpoints.

## Week 39 — Security Sprint 2 (PII Controls)
**Tasks**: data masking in logs, retention rules, access reviews, break-glass audit path.  
**Acceptance**: zero unauthorized PII exposure in audit sample.

## Week 40 — Scale Test 50-Dealer Simulation
**Tasks**: synthetic tenant generator, high-volume nightly run simulation, saturation profiling.  
**Acceptance**: stable execution at 50-dealer target load.

## Week 41 — Incident Response Game Days
**Tasks**: runbook drills for ETL failure, DB failover, provider outage, bad model artifact.  
**Acceptance**: MTTR targets met in at least 3 scenario classes.

## Week 42 — Analytics Surface v2
**Tasks**: richer ROI dashboards, cohort comparisons, channel cost analytics.  
**Acceptance**: dashboard queries complete under performance budgets.

## Week 43 — Advanced Approval Controls
**Tasks**: dual approval, threshold-based auto-approval, audit signoff checkpoints.  
**Acceptance**: policy matrix behaves as configured across all tenants.

## Week 44 — Deployment Pipeline Finalization
**Tasks**: blue/green deploy support, zero-downtime migration strategy, release checklist automation.  
**Acceptance**: two successful blue/green production rehearsals.

## Week 45 — Documentation and Enablement
**Tasks**: developer handbook, onboarding docs, support playbooks, architecture diagrams refresh.  
**Acceptance**: new engineer can deploy staging in one day.

## Week 46 — Pilot-to-SaaS Migration Wave
**Tasks**: migrate initial pilot dealers to V2 scheduler pipeline, validate parity.  
**Acceptance**: no regression in campaign throughput or attribution metrics.

## Week 47 — Executive KPI Validation Sprint
**Tasks**: validate ARR drivers, margin assumptions, channel cost benchmarks, conversion deltas.  
**Acceptance**: KPI dashboard accepted by leadership as source of truth.

## Week 48 — Phase 2 Production Readiness Gate
**Tasks**: final audit, risk register closure, go/no-go review, rollout sequencing for 50 dealers.  
**Acceptance**: signed release approval by Engineering, Product, Compliance, and Operations.

---

## 4) Cross-Functional Weekly Rituals (Run Every Week)

- **Monday Architecture Standup (60 min):** platform risks, schema changes, integration dependencies.
- **Daily Pod Standups (15 min):** blockers, SLA-impacting issues.
- **Wednesday Quality Gate (45 min):** test coverage drift, flaky tests, incident review.
- **Friday Demo + Retrospective (60 min):** delivered features, acceptance evidence, carry-over decisions.
- **Weekly Metrics Report:** lead time, change failure rate, MTTR, nightly run success rate, dispatch success by channel.

---

## 5) Mandatory Artifacts per Week

Every week must end with:
1. Updated architecture diagram if dataflow changed.
2. Updated runbook entries for new failure modes.
3. Test evidence attached to sprint ticket closure.
4. Security/compliance signoff for any customer-impacting dataflow changes.

---

## 6) Program-Level Exit Criteria for Hand-off

The team is considered implementation-complete for Phases 1–2 when:
- V1 pilots are stable and measurable.
- V2 nightly automation runs reliably across multi-tenant workloads.
- CRM write-back via SES/ADF is consistently reconciled.
- Guardrails and cooldown controls demonstrate zero policy bypass in production logs.
- On-call and operations teams can run the platform without engineering heroics.

