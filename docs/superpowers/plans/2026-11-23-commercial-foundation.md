# Commercial Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the approved trainer business model enforceable and reviewable before payment-provider setup.

**Architecture:** Retain access roles, add a regional price catalog and server-owned access grants. A current-account RPC supplies the UI; the student activation trigger enforces the server quota. Commission preview is backend-only and uses exact minor-unit arithmetic.

**Tech Stack:** Existing HTML/JavaScript, PostgreSQL/Supabase, Node and Playwright.

**Spec:** docs/commercial-foundation-spec.md

## Global Constraints
- Basic: 15, USD 3499, BRL 2990. Pro: 50, USD 4999, BRL 3990 minor units monthly.
- Default influencer commission: 1500 basis points on eligible receipts; preserve explicit existing agreements.
- No Stripe account: checkout remains disabled, preview does not record earnings.
- Student access/discovery free, core features equal, Space independent.
- Preserve current access and data; no Auth test users, outbound messages, or edits under sources/.

## Review Focus
- Concurrent activation and reassignment must not bypass quota.
- Expired/past_due subscriptions and a forged client role must not confer Pro.
- Existing over-limit portfolios and beta grants must survive without deleted data.
- Unknown/error/loading server states must not advertise an unverified quota.
- Negative/overflowing commission inputs, fee deductions and existing agreement overrides must be safe.

### Task 1: Server business rules
**Files:** Create database/monolith-production-step-40-commercial-foundation.sql; tests/qa-commercial-foundation.sql.
**Interfaces:** current-account state RPC and service-only commission preview as specified.
- [ ] Write SQL behavior assertions for regional prices, equal core features, current-user isolation, Basic/Pro quota, managed student idempotency, subscription expiration, existing access, blocked client writes and commission arithmetic/overrides.
- [ ] Run assertions before implementation; expect absent commercial API.
- [ ] Implement catalog, access grants, state RPC, capacity trigger and commission preview.
- [ ] Run the assertions with migration inside BEGIN/ROLLBACK; expect success and unchanged persistent counts.
- [ ] Commit server rules and tests.

### Task 2: Account and capacity display
**Files:** Create assets/monolith-commercial.js; tests/qa-commercial-ui.cjs. Modify index.html; package.json.
**Interfaces:** use the state RPC and render only verified current-user data.
- [ ] Write UI behavior tests: correct regional currency, real quota/source, student included message, server error/loading state and disabled checkout.
- [ ] Run tests before implementation; expect missing module/display behavior.
- [ ] Implement rendering helper and current-account integration, resetting state on identity changes.
- [ ] Run unit/browser tests and existing QA scripts; expect no regressions.
- [ ] Commit UI and tests.

### Task 3: Review and release preparation
**Files:** Update database/README.md; docs/commercial-foundation-handoff.md.
- [ ] Document deployed-versus-pending state, required provider events and beta handling.
- [ ] Run an independent whole-change review and fix material findings with regression coverage.
- [ ] Deploy only reviewed, tested migration; verify catalog, effective current quotas and grants.
- [ ] Prepare/push changes using existing GitHub authorization if available. Report exact checks and payment-provider blocker.

