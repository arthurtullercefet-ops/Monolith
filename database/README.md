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
4. Confirm these tables exist:
   - `profiles`
   - `trainer_students`
   - `daily_checkins`
   - `body_measurements`
   - `workout_templates`
   - `completed_workouts`
   - `diet_plans`
   - `food_logs`
   - `progress_photos`
5. Confirm Storage has a private bucket called `progress-photos`.

## Step 2: connect the frontend

The current app is still local-first and uses `localStorage`.

Next implementation pass:

1. Add Supabase client config.
2. Replace local demo login with Supabase Auth.
3. Keep demo mode as fallback for development.
4. Migrate each localStorage group to a table:

| Current local key | Database table |
| --- | --- |
| `monolith.accounts` | `profiles` plus Supabase Auth |
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
