# Flutter Nest notes (Phase 3)

## Online
- `HatchlogApiClient` calls Nest REST: `/api/v1/me`, `/farms`, `/livestock`, `/houses`, `/eggs`, `/feeding`, `/mortality` with `farm_id` query where needed.
- Envelope `{ success, data, error }` is unwrapped in the client.
- Sync engines prefer Nest for livestock/house online reads when API URL is configured.

## Offline
- Egg / feed / mortality outbox still pushes to `POST /api/v1/sync/push`.
- Drift/sqflite local stores are unchanged.
