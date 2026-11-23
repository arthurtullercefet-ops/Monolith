# Commercial foundation: implementation and remaining integration
Date: 2026-11-23. Branch: codex/commercial-foundation.

## Approved offer
| Product | Active clients | US monthly | BR monthly |
|---|---:|---:|---:|
| Basic | 15 | USD 34.99 | BRL 29.90 |
| Pro | 50 | USD 49.99 | BRL 39.90 |

Student access and discovery are included/free. Managed and authenticated students share active seats. Core features are the same. Space stays independent; no new Space checkout is provided.

## This delivery
Step 40 implements a regional catalog, exact quotas enforced under the existing trainer row lock, current-account state API and backend-only commission calculator. It hides old Student/Plus offers without deleting historical keys. It preserves current trainer capacity with explicit legacy grants and does not change profile roles, Space flags or clinical records.

The new account section reads prices and quota from the backend; loading/error states do not claim a paid quota. User changes and language changes re-render the matching view. Client list refresh rechecks current capacity.

Commission preview defaults to 1500 bps on payment minus direct sales tax, channel fees and refunds, with explicit agreement overrides. It is NOT an earnings ledger, attribution validation, payout or proof of a real payment. No new commission is earned for free students or signups.

## Provider blocker and staged activation
Arthur confirmed he does not yet have Stripe. Checkout buttons stay disabled. No payment, automatic renewal, commission payment or store purchase is enabled.

New trainer accounts without a purchased subscription or an explicit beta grant have zero new seats. Do not publicly open paid onboarding before provider setup; beta onboarding requires a server-owned grant for the authorized account. Existing legacy grants retain current access until deliberately migrated. Specific beta promises (including individual seat allowances) must be mapped to confirmed account identities; this migration does not guess identities or invent new agreements.

## Next implementation contract
1. Connect a founder-owned payment account; create four provider price IDs, and map them to the server catalog. A country/language switch in the client is not authority to choose a billing region.
2. Implement signature-verified provider events, idempotent event IDs, purchase/renewal/expiry/refund processing and server-only subscription writes. Set server_verified_at only after verification; historical provider/status fields confer no purchased capacity. Do not promote access using client redirects or editable account metadata.
3. Replace preview with a receipt-backed, currency-separated commission ledger: validate the paid trainer and fixed referral attribution, snapshot the agreement rate, deduplicate receipts and refunds, and account for refunds after payout. Payout method, timing and thresholds require explicit commercial terms.
4. Implement account/data deletion, native Android/iOS setup and device purchase/restore testing. Developer accounts remain outstanding.

## Validation evidence
- SQL RED: missing current-account RPC (42883), before implementation.
- SQL integration: regional prices, equal features, own-record access, denied self-activation, Basic 16th/Pro 51st denial, idempotent managed creation, explicit beta seats, expiration/history preservation, past_due exclusion and exact net commission/override assertions passed in BEGIN/ROLLBACK.
- Persistent rollback check: Auth users 7, profiles 7, links 4; no test tables/functions remained.
- Browser RED: missing rendering module; later language-switch regression reproduced stale catalog and was fixed with an explicit refresh.
- Browser suite results are recorded in docs/commercial-foundation-progress.md and artifacts/*.log.
- PGlite package is unavailable in this environment; its two pre-existing standalone database runners cannot run here. The new database rules were exercised against PostgreSQL in a fully rolled-back transaction instead.

## Deployment
STAGED ONLY: hold schema and frontend release together. No Stripe account or public beta-grant process exists, so publishing zero-seat onboarding now would block new trainers without providing a purchase path. Existing production remains unchanged.

Seat activation supports READ COMMITTED transactions. REPEATABLE READ and SERIALIZABLE activations fail explicitly instead of using stale quota snapshots.

Independent review findings on post-save quota refresh, terminal zero-seat errors, async profile headings and historical subscription provenance were fixed with regression coverage.

Concurrency fixture generator: run node tests/build-commercial-concurrency.cjs monolith_qa_<unique_name>, execute setup in a non-exposed QA schema, then the two race queries from independently overlapping SQL sessions. Require one admitted result, one MONOLITH_STUDENT_LIMIT and evidence that the rejected session waited for the trainer lock (elapsed_ms >= 1000 with distinct backend processes). Run assertRace and isolation checks, then cleanup. The two connector-dispatched requests in this environment did not exhibit measurable overlap, so true overlapping execution remains a release check; do not call that proof of concurrency.

Deferred minor presentation items: initial hidden capacity markup still says 0/15 until JS replaces it; localized affiliate copy displays the currently approved 15% rather than formatting a future policy change dynamically. Neither changes server enforcement.

