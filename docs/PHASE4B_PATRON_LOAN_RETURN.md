# Phase 4B — Authoritative patron loan return

## Endpoint

`POST /api/v1/contrib/jzl-digital-circulation/loans/{loan_id}/return`

Backend portal-service endpoint only. Browser clients must never call this route.

## Authentication and authorization

- Requires a Koha-authenticated API actor.
- Authorization uses `PortalServiceAuthorization` (portal service account allowlist).
- Staff decision authorization is not used and must not authorize this write.
- The authenticated API actor (for example service actor `53`) is recorded on the audit event as `actor_patron_id`.
- The business initiator is the subject patron on the loan (`patron_id` in the command and event).
- Event `source` is `PORTAL`. Payload `origin` is `portal_patron_return`.

The plugin does not infer that the service actor is the patron.

## Request contract

Headers:

- `Authorization: Bearer …`
- `X-Correlation-ID: <uuid>` (required)
- `Content-Type: application/json`

Body (closed; additional properties rejected):

| Field | Meaning |
| --- | --- |
| `patron_id` | Trusted Koha borrowernumber from the portal session |
| `portal_request_id` | Portal request UUID correlated to the loan’s request |
| `expected_row_version` | Optimistic concurrency token for ACTIVE writes |

Path `loan_id` must identify the exact plugin loan.

## Correlation checks

Before any write, the locked loan+request join must match:

- loan exists
- loan `request_id` joins a request
- request `portal_request_id` matches
- loan `patron_id` matches supplied `patron_id`
- request `patron_id` matches
- loan and request `biblio_id` match

Failures return `409 LOAN_CORRELATION_MISMATCH` with no write.

## ACTIVE → RETURNED

In one database transaction:

1. Lock the loan row (`FOR UPDATE`) with request join.
2. Verify correlation and `expected_row_version`.
3. Conditionally update `ACTIVE` → `RETURNED` with matching `row_version`.
4. Set `returned_at` to authoritative UTC clock time.
5. Increment `row_version` exactly once.
6. Leave `started_at`, `due_at`, `renewal_count` unchanged; leave `revoked_at` / `expired_at` null.
7. Insert exactly one `LOAN_RETURNED` event.
8. Commit and return the canonical loan DTO with `idempotent_replay=false`.

Native Koha `issues` / checkouts are never created, updated, or deleted.

## Idempotent repeated return

When the loan is already `RETURNED` and identities still match:

- return HTTP `200` with the canonical loan
- `idempotent_replay=true`
- do not change `returned_at`
- do not increment `row_version`
- do not create another event

## Terminal-state conflicts

| Status | Result |
| --- | --- |
| `REVOKED` | `409 LOAN_NOT_RETURNABLE` — not rewritten to `RETURNED` |
| `EXPIRED` | `409 LOAN_NOT_RETURNABLE` — not rewritten to `RETURNED` |
| other non-ACTIVE (except RETURNED) | `409 LOAN_NOT_RETURNABLE` |

## Row-version conflicts

For a genuinely stale `ACTIVE` write (`expected_row_version` mismatch or lost conditional update):

- `409 VERSION_CONFLICT`
- no partial write

For already `RETURNED` loans, identity match alone is sufficient for idempotent success (version need not match the pre-return token).

## Concurrent returns

Two simultaneous returns cannot create two events or increment `row_version` twice. Only one `ACTIVE` → `RETURNED` transition succeeds; the other receives either canonical idempotent success or a normalized conflict the portal can reconcile.

## Success response

```json
{
  "loan": {
    "loan_id": 31,
    "request_id": 91,
    "portal_request_id": "…",
    "patron_id": 157,
    "biblio_id": 13,
    "status": "RETURNED",
    "started_at": "…",
    "due_at": "…",
    "returned_at": "…",
    "revoked_at": null,
    "expired_at": null,
    "renewal_count": 0,
    "row_version": 2,
    "created_at": "…",
    "updated_at": "…"
  },
  "idempotent_replay": false,
  "correlation_id": "…"
}
```

Safe error envelope: `{ "error": { "code", "message" } }` only.
