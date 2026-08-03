# Flutter Nest notes (mobile) — Nest required

## Transport
- **Farm / commerce data:** Nest REST + `/api/v1/sync/push` only. `HATCHLOG_API_URL` is **required** at bootstrap (`HatchlogApiConfig.requireConfigured()`).
- **Auth / identity leftovers:** Supabase Auth (JWT for Nest Bearer), license RPCs, team provision / invitations / `user_permissions` live reads.

## Online
- Ops: `/me`, `/farms`, `/livestock`, `/houses`, `/eggs`, `/feeding`, `/mortality`, isolation, health schedules
- Commerce: `/inventory`, `/customers`, `/suppliers`, `/sales`, `/expenses`, `/feeding/feed-formulations`, egg-categories
- Mutations: worker_log update/delete, farm/sales settings → Nest domain REST (not Supabase)
- Universal dashboard Nest-owned modules read **local cache** after Nest hydrate (no Supabase `.stream` on those tables)
- Nest-owned outbox types never fall back to Supabase

## Offline
- Egg / feed / mortality outbox → `POST /api/v1/sync/push` only
- Do **not** expand offline sync beyond those three entities

## Smoke checklist
- Missing `HATCHLOG_API_URL` → bootstrap fails with clear `StateError`
- Nest up: commerce/ops push does not hit Supabase tables
- Auth / license / team provision still use Supabase
