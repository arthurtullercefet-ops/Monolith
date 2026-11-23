# Monolith commercial foundation — approved direction (2026-11-23)

## Decisions
- Monetize trainers; students and professional discovery are included/free.
- Basic: 15 active students, USD 34.99/month in US, BRL 29.90/month in BR.
- Pro: 50 active students, USD 49.99/month in US, BRL 39.90/month in BR.
- Managed and authenticated active students share the same quota.
- Core features are equal. Space remains a separate existing entitlement; no new Space sale.
- New influencer partnerships: 1500 basis points (15%) recurring on eligible trainer subscription receipts, after sales taxes, channel fees and refunds. Existing negotiated agreements must be preserved.
- No general free trial/month or public lifetime offer.
- User has no Stripe account. No checkout, payment collection, payout, recurring billing or store purchase may be represented as working.

## Deliverable
Implement the server catalog, protected trainer capacity, current-account read API, settings/capacity display and server-only commission preview. Document the provider integration contract for the next phase. Preserve existing users and all their records. Do not infer a paid Pro subscription from trainer_plus role or grant Space from Pro.

## Access model
New subscriptions require verified server writes. Only active Stripe/Apple/Google subscriptions with a started, unexpired period confer purchased capacity. A separate server-owned access grant preserves current trainers' existing capacity (15 or their existing larger count); existing beta/Space identities are not guessed or rewritten. Future beta grants may explicitly set a seat allowance. No active subscription/grant means zero new seats; existing data stays readable. Over-quota downgrade prevents additions/reactivations, never deletes links or students.

## API
- public.get_monolith_commercial_state(): current authenticated identity only; returns trainer flag, plan/source, student_limit, active_students, can_add_student, over_limit, checkout_available=false, prices and policy.
- Private capacity helper, used by the existing student activation trigger under the trainer row lock.
- public.preview_monolith_referral_commission(influencer UUID, currency TEXT, paid BIGINT, tax BIGINT, channel_fee BIGINT, refund BIGINT): service_role only; integer minor-unit arithmetic, nonnegative inputs and total deductions <= paid, optional server-owned agreement override, 15% otherwise. This is a preview, not a payment ledger or payout.
- Catalog/policy readable; all writes to commercial data remain server-owned.

## Verification / deployment
Existing in-memory Postgres runner dependency is unavailable and shell network fetch failed. Validate new SQL in one explicit production transaction that is rolled back, without creating Auth accounts or sending notifications; use only transient managed fixtures and existing account identities. Verify persistent row counts unchanged afterward. Never include fixture code in the deployed migration.
Run browser regressions against local QA accounts; no real-user login or notifications. Review before deployment. Keep checkout disabled.

