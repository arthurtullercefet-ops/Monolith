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
14. Paste and run `monolith-production-step-11-anamnesis.sql`.
   This adds the student health questionnaire. Students own their answers; linked trainers have read-only access.
15. Paste and run `monolith-production-step-12-anamnesis-workflow.sql`.
   This adds private drafts, explicit consent timestamps, important-answer updates and linked-trainer read receipts.
16. Paste and run `monolith-production-step-13-idempotency.sql`.
   This prevents duplicate check-ins, measurements, workouts, diets, photos, anamneses and invite uses when a request is retried.
17. Paste and run `monolith-production-step-14-validation-audit.sql`.
   This adds server-side numeric validation, immutable authorship, correction reasons, scoped writes and a private audit trail without deleting legacy QA records.
18. Paste and run `monolith-production-step-15-programs.sql`.
   This adds trainer-authored 4, 8 and 12-week programs with a weekly workout/rest calendar.
19. Paste and run `monolith-production-step-16-anamnesis-history.sql`.
   This preserves immutable questionnaire versions and adds an auditable linked-trainer review action.
20. Paste and run `monolith-production-step-17-measurement-history.sql`.
   This adds reversible measurement archiving and allows a linked trainer to manage the selected student's physical records under RLS.
21. Paste and run `monolith-production-step-18-pulse.sql`.
   This stores private review receipts for Monolith Pulse alerts without duplicating student health data.
22. Paste and run `monolith-production-step-19-feedback-timeline.sql`.
   This adds contextual feedback without media and the private transformation timeline.
23. Paste and run `monolith-production-step-20-onboarding-leads-achievements.sql`.
   This adds configurable onboarding, the Instagram lead funnel and transparent student achievements.
24. Paste and run `monolith-production-step-21-spaces.sql`.
   This adds isolated Monolith Spaces, memberships and partner themes while keeping Monolith visible.
25. Paste and run `monolith-production-step-22-voice.sql`.
   This adds private, two-hour Monolith Voice sessions and idempotent command receipts. Raw audio is not stored.
26. Paste and run `monolith-production-step-23-language-preferences.sql`.
   This persists application language, Monolith Voice language, weight unit and voice preference in each user's protected profile.
27. Paste and run `monolith-production-step-24-programs-voice-workout-scope.sql`.
   This repairs the exact Programs and Monolith Voice tables expected by the app, reloads the PostgREST schema cache and prevents students from changing workout templates or global check-in tasks. Linked trainers retain scoped access under RLS.
28. Paste and run `monolith-production-step-28-alerts-space-assets.sql`.
   This renames the product surface from Pulse to Alertas, deprecates Leads access without deleting old records, adds private Space logo/cover Storage paths, creates the `space-assets` bucket policies and exposes safe Space address availability checks.
29. Confirm these tables exist:
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
   - `student_anamneses`
   - `student_anamnesis_reads`
   - `student_anamnesis_versions`
   - `checkin_corrections`
   - `data_change_audit`
   - `workout_programs`
   - `monolith_pulse_reviews`
   - `contextual_feedback`
   - `transformation_events`
   - `onboarding_configs`
   - `onboarding_progress`
   - `trainer_leads`
   - `trainer_lead_events`
   - `student_achievements`
   - `monolith_spaces`
   - `space_memberships`
   - `workout_voice_sessions`
   - `workout_voice_commands`
   - `app_plans`
   - `subscriptions`
   - `influencer_codes`
   - `referral_attributions`
29. Confirm these functions exist:
   - `create_trainer_invite`
   - `create_trainer_invite_idempotent`
   - `accept_trainer_invite`
   - `accept_influencer_code`
   - `correct_daily_checkin`
   - `is_space_member`
30. Confirm Storage has private buckets called `progress-photos` and `space-assets`.

All step files are additive and idempotent. Run them in numerical order. Do not reset the database or delete QA records before running a step.

For an existing Monolith project that already completed step 12, run only steps 13 through 24 in order. Re-running any of those files is safe; they contain no bulk deletion, table reset or QA cleanup.

### Repair for PGRST205 in Programs or Monolith Voice

If the current project reports `PGRST205` for `workout_programs`, `workout_voice_sessions` or `workout_voice_commands`, run exactly:

`monolith-production-step-24-programs-voice-workout-scope.sql`

This single repair migration contains the same table structure already defined by steps 15 and 22; it does not create a parallel model and does not delete existing rows. It can be run even when one or all three tables already exist. The migration requires the base schema and production step 14, then reloads the PostgREST schema cache automatically.

After it finishes, the result row must show all three readiness columns as `true`. You can also verify them without changing data:

```sql
select
  to_regclass('public.workout_programs') is not null as workout_programs_ready,
  to_regclass('public.workout_voice_sessions') is not null as voice_sessions_ready,
  to_regclass('public.workout_voice_commands') is not null as voice_commands_ready;
```

## Step 2: connect the frontend

The production frontend uses Supabase for real accounts. Demo/local accounts remain only as a development fallback.

For real Supabase users, large datasets are not kept permanently in `localStorage`; they are loaded from Supabase and held in memory during the browser session.

| Current local key | Database table |
| --- | --- |
| `monolith.accounts` and language/voice preferences | `profiles` plus Supabase Auth |
| `monolith.factors` | `checkin_factors` |
| `monolith.studentFactors` | memory cache of `checkin_factors` per student |
| `monolith.checkins` | `daily_checkins` |
| `monolith.bodyMeasures` | `body_measurements` |
| `monolith.workouts` | `workout_templates` |
| `monolith.completedWorkouts` | `completed_workouts` |
| `monolith.dietPlans` | `diet_plans` |
| `monolith.foodLogs` | `food_logs` |
| `monolith.progressPhotos` | `progress_photos` plus Storage |
| `monolith.anamneses` | `student_anamneses` |
| `monolith.pulseReviews` | `monolith_pulse_reviews` |
| active Monolith Voice state | `workout_voice_sessions` |
| Monolith Voice command receipts | `workout_voice_commands` |
| `monolith.contextualFeedback` | `contextual_feedback` |
| `monolith.transformationEvents` | `transformation_events` |
| `monolith.onboardingConfigs` | `onboarding_configs` |
| `monolith.onboardingProgress` | `onboarding_progress` |
| `monolith.trainerLeads` | Deprecated; old `trainer_leads` and `trainer_lead_events` rows are retained but no longer exposed to trainers |
| `monolith.achievements` | `student_achievements` |
| `monolith.spaces` | `monolith_spaces`, `space_memberships` and private `space-assets` Storage paths |

## Step 3: production rules

Before public launch:

- Do not store real passwords in `localStorage`.
- Do not expose private photos in public buckets.
- Keep Row Level Security enabled on every user table.
- Use the anon public key in the frontend, never the Supabase service role key.
- Test one student and one trainer account before adding payments.

## Monolith Voice Beta on the web

- Voice is available only to a student inside an active workout and requires HTTPS (or localhost) for microphone permission.
- Continuous `Hey Monolith` listening is enabled only when the browser reports on-device speech recognition support.
- On browsers without confirmed on-device recognition, the two-hour Voice session remains ready but the microphone opens only for the 10-second `Talk now` action, then closes again.
- The workout page must remain open. Moving to another page or sending the browser to the background pauses Voice.
- Raw audio is never stored by Monolith. The database receives only normalized command payloads and idempotent command receipts; transcript excerpts remain null by default.
- The web beta uses a compatible voice installed on the device for spoken replies. A proprietary Monolith voice and reliable locked-screen operation require a later native-app phase.

## Release verification

After steps 13 through 24 are installed, test with fictitious accounts:

- A student cannot read another student's workouts, diet, measures, photos, anamnesis, feedback or timeline.
- A student can execute an assigned workout but cannot insert, update or delete `workout_templates` or `checkin_factors` through the API.
- A trainer can read only active linked students and cannot assign data without an explicit destination.
- A linked trainer can read the student's Programs and Voice records; an unlinked trainer cannot.
- A student with no remote program sees the real empty state and never a failed local draft as synchronized.
- Two quick clicks create one check-in, workout, diet, measurement or feedback.
- Opening a trainer map profile or Instagram does not create a lead or identifiable visitor event.
- A trainer cannot read unknown users, visitor lists, lead events or unlinked prospects.
- A Space owner and its members can read only their own Space and memberships.
- A Space owner can upload, replace and remove only their own logo/cover files in `space-assets`; linked students can only read them through signed URLs.
- Monolith Voice is hidden for trainers, stops after two hours or workout completion, rejects doubtful values and does not duplicate a repeated command.
- A browser without on-device recognition releases the microphone between push-to-talk commands.
- Demo and QA records remain intact and suspicious legacy values remain flagged rather than deleted.
