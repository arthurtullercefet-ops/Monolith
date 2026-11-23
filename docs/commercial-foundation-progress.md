# Execution ledger — 2026-11-23 commercial foundation
Plan: docs/superpowers/plans/2026-11-23-commercial-foundation.md
Base: 29a2f61e3693e2afb67442d3000800cefd8539a6
Branch: codex/commercial-foundation

- Scope: first enforceable business-model delivery; user confirmed no Stripe account, so no checkout or cash operations.
- Preservation: legacy access grants retain current seats; specific beta agreements are not inferred from names or roles.
- Pre-flight: Task 1 produces current-account JSON consumed by Task 2. Field names fixed in spec.
- Environment: shell Node works; PGlite dependency absent; registry fetch failed; managed Node REPL unavailable. SQL tests use an explicit rolled-back transaction and no Auth fixtures.
- Existing hardening already removed self-write subscription policies in production; repeat restrictive grants defensively in the migration.
- Project uses numbered SQL snapshots. Supabase MCP creates the hosted migration history; keep step-40 snapshot consistent with repository convention.
- Task 1: SQL RED observed (42883 missing RPC). All transactional integration assertions passed, then rolled back. Persistent verification: Auth 7, profiles 7, links 4; no new tables/functions remained.
- Task 2: UI RED observed (missing module), then unit/browser helper checks passed. Integrated language-change test reproduced stale Portuguese catalog; adding explicit language refresh.
- Task 2: language fix GREEN. Core QA, calendar/billing, beta, Voice and pending-fixes scripts passed. Diet browser passed. Managed browser initially failed because its mock treated every RPC as managed creation; added the new read-only RPC contract and reran: passed. Commercial app test passed, including account switch and disabled checkout. Screenshot inspected.
- Task 2: active-client list refresh revalidates the server quota after successful mutations. UI does not grant access and treats commercial API errors as unknown capacity.
- Payment blocker remains: founder has no Stripe account. New paid onboarding must stay closed; existing access remains preserved, and new beta allowances require explicit server grants.
- Final review: no critical finding. Fixed Important findings: successful managed save now forces a fresh quota read after any in-flight read; terminal MONOLITH_SUBSCRIPTION_REQUIRED clears/unlocks the draft; profile and session headings refresh on loading/completion; paid access requires server_verified_at with no historical auto-backfill.
- Final regressions: each UI finding reproduced RED (stale 1/15, stale Basic heading, retry error for definitive rejection) then GREEN. All 8 browser scripts passed via tests/run-commercial-browser-suite.cjs, which owns its HTTP server and survives process/session boundaries.
- Final SQL integration assertions passed again with verification provenance and isolation guard, inside BEGIN/ROLLBACK.
- Provenance regression: same source helper in isolated QA schema admitted an unverified historical row at 50 seats before the filter, and returned only the explicit 1-seat test grant after restoration. Both outcomes asserted.
- Isolation/reassignment: repeated-read activation rejection and active reassignment into a full destination asserted. Two dispatched last-seat requests yielded one admission/one rejection, but the rejected call showed no measurable lock wait. No claim of overlapping PostgreSQL execution is made.
- QA schema was removed. Final production check: Auth 7, profiles 7, links 4, no commercial schema deployed.
- Ruling: stage schema and frontend in a draft PR until purchase or explicit beta onboarding exists; deploying now would block new trainers. Current production stays unchanged.
- Ruling: retain explicit READ COMMITTED enforcement and defer the genuinely overlapping two-session test to an environment with independently controlled SQL sessions; release remains blocked until that check.
- Final: minor (deferred): initial hidden capacity markup contains 0/15 before rendering; future policy-rate changes need dynamic localized affiliate copy. Current server/15% policy is correct.
- Delivery: draft PR https://github.com/arthurtullercefet-ops/Monolith/pull/2, remote code commit 0628e811f916ef4e49e38b8059e07172a197e975. Remote tree exactly matches reviewed local code. No merge or production migration.

