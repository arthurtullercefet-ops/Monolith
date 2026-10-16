# Named diet variants and prescribed repetition ranges

Apply `monolith-production-step-36-diet-variants-rep-ranges.sql` once after step 35, before deploying the matching frontend.

## Diet identity and access

The same `diet_plans` table, student IDs and existing RLS policies are retained. Each plan has a trainer-authored `plan_name` and a stable `variant_key`. Existing rows receive the default column values (`plan_name = ''`, `variant_key = 'default'`) without any UPDATE, content conversion or timestamp change. Blank legacy names display as the localized “Default diet”.

The old monthly uniqueness constraint is replaced by `(trainer_id, student_id, month_key, variant_key)`. Additional diets use a generated UUID independent of their display names. Renaming a plan retains its identity. Every upsert, delete, cache key, history entry, duplicate and CSV round-trip identifies the individual variant. A duplicate is a separate draft; it never replaces another diet. The trainer, student, month and variant identity are immutable after creation.

The student selects among the month's published diets; drafts and archived plans remain hidden under the existing RLS. High Day and Low Day are independent prescriptions, each with its own meals, macros, notes and supplements. Their names can indicate the intended training/rest days. This release does not infer or prescribe daily calorie changes.

## Exercise prescriptions and results

Prescribed repetitions accept a single integer or an ascending range with endpoints from 1 through 100. Hyphens and common Unicode dashes normalize to `-`. A mobile 3×10–12 preset is available. CSV import/export preserves ranges.

Only the `workout_templates` check constraint changes to accept prescribed ranges. The completed-workout validator remains unchanged. Sessions show the range as a target and leave the actual count blank until entered. The completed numeric count and `targetReps` are separate; a range is never substituted for a performed count or used to estimate volume.

## Meal presentation

Explicit newlines render as separate food rows. Old comma/semicolon lists render as separate rows while decimal commas remain intact. Commas inside explicitly separated lines are retained. The saved meal text is never rewritten. Food text is escaped in the student view, trainer preview and report HTML.

## Isolated verification

- `node tests/qa-diet-variants-browser.cjs`: real demo UI flows for creating/publishing two diets, independent editing, canceling unsaved navigation, student selection, PT/EN/ES, meal line formatting, CSV identity round-trip and range-workout execution.
- `node tests/qa-diet-variants-rep-ranges.cjs`: ephemeral Postgres migrations, unchanged legacy values, independent variant IDs/updates/deletes, student publication visibility, cross-trainer isolation, valid/invalid ranges and separation from actual numeric repetition counts.
- The Postgres test uses `@electric-sql/pglite@0.3.14` or the installed module path supplied through `MONOLITH_PGLITE`. No test writes to production or creates live Auth users.

## Non-destructive rollback

The frontend can be rolled back independently only while no additional variant exists. A structural rollback must refuse to restore the old monthly unique constraint whenever a student has multiple diets in a month, and must refuse the old workout-template constraint while prescribed ranges exist. Never delete, merge or coerce diets/ranges to force a rollback. Keep the additive columns and existing data until a deliberate compatible rollback is prepared.
