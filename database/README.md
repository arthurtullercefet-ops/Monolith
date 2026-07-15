# Monolith database setup

## Recommended first backend

Use Supabase for the first production pass:

- Auth: email/password login for students, influencers and trainers.
- Postgres: real database for check-ins, workouts, measures, diets and reports.
- Row Level Security: students only see their own data; trainers see linked students.
- Storage: private progress photos.

Official docs:

- Auth: https://supabase.com/docs/guides/auth
- Row Level Security: https://supabase.com/docs/guides/database/postgres/row-level-security
- Storage uploads: https://supabase.com/docs/guides/storage/uploads/standard-uploads

## Step 1: create the database

1. Create a Supabase project.
2. Open SQL Editor.
3. Paste and run `monolith-supabase-schema.sql`.
4. Paste and run `monolith-production-step-01.sql`.
   This adds production invite codes, signup profile sync, plans, subscriptions and influencer attribution.
5. Paste and run `monolith-production-step-02-trainer-map.sql`.
   This adds the one-time trainer professional profile used by the future trainer map/search.
6. Paste and run `monolith-production-step-03-checkin-factors.sql`.
   This syncs each student's custom daily checklist/factors for reports and trainer follow-up.
7. Paste and run `monolith-production-step-04-trainer-checkin-write.sql`.
   This lets linked trainers edit student check-in factors and save daily check-ins for students.
8. Paste and run `monolith-production-step-05-linked-scope.sql`.
   This tightens production scope: trainers can assign workouts/diets only to linked students, and food diaries stay private to students.
9. Paste and run `monolith-production-step-06-invite-repair.sql`.
   This repairs trainer invite code creation/acceptance.
10. Paste and run `monolith-production-step-07-production-data-bridge.sql`.
   This confirms the production tables, keeps the photo bucket private, reapplies key production policies and adds report indexes.
11. Paste and run `monolith-production-step-08-scope-audit.sql`.
   This reapplies the final student/trainer scope rules: students only see their own data, trainers only see linked students, and food diaries stay private to students.
12. Paste and run `monolith-production-step-09-photo-storage.sql`.
   This repairs the private `progress-photos` bucket and Storage policies used by progress photo uploads.
13. Paste and run `monolith-production-step-10-student-unlink.sql`.
   This allows a student to unlink their own trainer relationship from the profile screen.
14. Confirm these tables exist:
   - `profiles`
   - `trainer_students`
   - `trainer_invites`
   - `trainer_public_profiles`
   - `daily_checkins`
   - `checkin_factors`
   - `body_measurements`
   - `workout_templates`
   - `completed_workouts`
   - `diet_plans`
   - `food_logs`
   - `progress_photos`
   - `app_plans`
   - `subscriptions`
   - `influencer_codes`
   - `referral_attributions`
15. Confirm these functions exist:
   - `create_trainer_invite`
   - `accept_trainer_invite`
   - `accept_influencer_code`
16. Confirm Storage has a private bucket called `progress-photos`.

## Step 2: connect the frontend

The production frontend uses Supabase for real accounts. Demo/local accounts remain only as a development fallback.

For real Supabase users, large datasets are not kept permanently in `localStorage`; they are loaded from Supabase and held in memory during the browser session.

| Current local key | Database table |
| --- | --- |
| `monolith.accounts` | `profiles` plus Supabase Auth |
| `monolith.factors` | `checkin_factors` |
| `monolith.studentFactors` | memory cache of `checkin_factors` per student |
| `monolith.checkins` | `daily_checkins` |
| `monolith.bodyMeasures` | `body_measurements` |
| `monolith.workouts` | `workout_templates` |
| `monolith.completedWorkouts` | `completed_workouts` |
| `monolith.dietPlans` | `diet_plans` |
| `monolith.foodLogs` | `food_logs` |
| `monolith.progressPhotos` | `progress_photos` plus Storage |

## Step 3: production rules

Before public launch:

- Do not store real passwords in `localStorage`.
- Do not expose private photos in public buckets.
- Keep Row Level Security enabled on every user table.
- Use the anon public key in the frontend, never the Supabase service role key.
- Test one student and one trainer account before adding payments.
