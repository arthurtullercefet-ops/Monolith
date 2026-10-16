# Managed students — production step 35

Apply `monolith-production-step-35-managed-students.sql` once, after step 34, before deploying the updated `index.html`.

The existing `profiles.id` remains the student ID for every clinical, workout, program, calendar, timeline and billing record. `trainer_students` remains the only active-student count. No parallel student table, Auth account, session, password, invitation, notification or Lead is created.

The existing mandatory FK from `profiles.id` to Auth is replaced by a nullable `auth_user_id` FK with the same delete cascade for authenticated profiles. Existing identities are copied into this new column without changing original fields, IDs, roles, entitlements or timestamps. A check constraint requires authenticated profiles to retain `auth_user_id = id`. Managed profiles require `access_mode = managed`, a null Auth identity, a student role and an immutable trainer owner. Existing profiles are never converted. Contact email may be null and is never used for linking or authentication.

`managed_space_id` records the owner's active, entitled Space, when present. Managed students do not become Space members: Space colleagues receive no access. Changing ownership, identity, registration mode or Space after creation is unsupported in this release. Contact information and trainer notes can be edited by the owner.

## Permissions

- `profiles_managed_scope` and `managed_owner_scope` are restrictive AND policies. They preserve existing operation-specific permissions and additionally require the managed owner (or an already authorized admin). The owner has explicit profile read/update policies; neither direct creation nor identity conversion is granted.
- `managed_owner_scope` is added to every existing public base table with `student_id` or `assigned_student_id`, including diet, workout, program, measurement, calendar, billing and timeline tables. Child tables continue to use their existing scoped parent policies.
- `memberships_no_managed_identity` prevents managed IDs from being added to Space memberships, even when another user knows the ID.
- The existing duplicate report view uses `security_invoker`, so its underlying RLS applies.
- Privileged implementations and trigger helpers live in `monolith_private`, outside exposed API schemas. Do not add that schema to PostgREST's exposed schemas. The public creation RPC is an invoker wrapper; the private implementation validates the authenticated trainer and Space ownership and executes an atomic insert of profile + active relationship.
- The existing 15-seat rule displayed by the application is enforced at the active relationship, for all current trainer plans. No commercial limits or entitlements are added or changed. Count distinct active student IDs; paused/ended links consume no seat. A trainer row lock serializes managed creation, invitation acceptance and reactivation. Existing over-limit trainers are untouched; further activation is blocked.
- Per-trainer UUID request IDs make retries idempotent. The form retains an unresolved creation request across refresh and retries the same payload. UI state/count changes only after server persistence and a successful list reload.

## Verification

`tests/qa-managed-students.cjs` runs the existing migrations and step 35 in an ephemeral PGlite Postgres, with local-only fixtures. It tests Auth count preservation, null contact email, owner isolation, anon/student rejection, immutable identity, normal diet/workout/measure writes, billing/payment and calendar RPCs, Space isolation, retry idempotency, rollback on limit errors and shared active-seat accounting. It never connects to Supabase.

Install the exact test dependency `@electric-sql/pglite@0.3.14` or set `MONOLITH_PGLITE` to its installed module path, then run `node tests/qa-managed-students.cjs`. Browser flows: `node tests/qa-managed-students-browser.cjs`. Existing browser regression: `node tests/qa-v109-pending-fixes.cjs`. No live fixture accounts are needed or permitted.

## Rollback

`rollback-step-35-managed-students.sql` restores the original identity FK only if no managed profile exists. Otherwise it refuses the rollback without deleting anything. To disable creation while retaining managed records, hide the button and revoke authenticated execution on `public.create_managed_student(text,text,text,date,text,uuid,uuid)` and its private implementation. Keep the schema, RLS and existing records. The reporting view retains its safer invoker setting.
