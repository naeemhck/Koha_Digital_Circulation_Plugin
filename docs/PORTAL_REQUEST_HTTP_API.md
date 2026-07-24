# Portal Request HTTP API

## Endpoint

`POST /api/v1/contrib/jzl-digital-circulation/requests` is the only Phase 2A write route. It accepts `application/json` and is not intended for direct browser or ordinary patron/staff use.

Koha authenticates the bearer token and applies the route's `circulate_remaining_permissions` gateway permission. That permission is necessary but not sufficient: `PortalRequestApplication` then calls `PortalServiceAuthorization`, which reads the exact service-account allowlist from plugin configuration and distinguishes an absent authenticated actor (`401 AUTHENTICATION_REQUIRED`) from an authenticated, non-allowlisted actor (`403 SERVICE_ACCOUNT_NOT_AUTHORIZED`). Actor identity comes only from `stash('koha.user')`.

## Request

Required headers:

- `Content-Type: application/json`
- `Idempotency-Key: <UUID>`
- `X-Correlation-ID: <UUID>`
- `Authorization: Bearer <service-token>` (processed by Koha, never by this controller)

The JSON body has exactly three required fields:

```json
{
  "portal_request_id": "3c90bf2e-d3d8-4db2-9f5d-d36f792340cd",
  "patron_id": 123,
  "biblio_id": 456
}
```

Additional body fields are rejected. In particular, the caller cannot supply actor identity, source, status, timestamps, version values, decisions, loans, renewals, or audit data. The application/persistence boundary always forces `source = PORTAL`.

## Responses

A new authoritative request returns `201`. An exact idempotent replay or an already-pending request returns the same authoritative request with `200`. The response flags identify `idempotent_replay` and `duplicate_pending`, and the successful response includes the caller's validated correlation ID.

Only these request fields are exposed: `request_id`, `portal_request_id`, `patron_id`, `biblio_id`, `status`, `requested_at`, and `row_version`. Internal pending guards, payloads, events, protected-content metadata, and database fields are filtered out. All route responses set `Cache-Control: no-store`.

Errors use only:

```json
{
  "error": {
    "code": "ERROR_CODE",
    "message": "Safe message"
  }
}
```

| Code | HTTP |
| --- | ---: |
| `INVALID_INPUT` | 400 |
| `INVALID_IDEMPOTENCY_KEY` | 400 |
| `AUTHENTICATION_REQUIRED` | 401 |
| `SERVICE_ACCOUNT_NOT_AUTHORIZED` | 403 |
| `PATRON_NOT_FOUND` | 404 |
| `BIBLIO_NOT_FOUND` | 404 |
| `CONTENT_NOT_ELIGIBLE` | 409 |
| `IDEMPOTENCY_CONFLICT` | 409 |
| `INTERNAL_ERROR` | 500 |
| `DIGITAL_CIRCULATION_UNAVAILABLE` | 503 |

Messages are stable and never include SQL, DBI errors, stack traces, paths, tokens, secrets, DSNs, configured allowlist values, raw request bodies, or dependency exceptions.

## Separation of responsibilities

The controller performs only HTTP parsing, strict boundary validation, dependency construction, application invocation, status mapping, and response filtering. `PortalRequestApplication` remains responsible for authorization-first orchestration, patron validation, content eligibility, and request creation through the transactional persistence service. The production application receives the real Digital Circulation plugin instance for both plugin configuration and table-name resolution. Tests replace the application through a per-controller method override; no dependency is stored globally.

## Deployment verification still required

Local tests verify the OpenAPI and deterministic controller/application contracts. A controlled Debian Koha 26.05 environment must still verify route loading, OAuth authentication behavior, permission enforcement, plugin configuration retrieval, MariaDB transaction/concurrency behavior, and the installed EbookContent dependency. This phase does not change the portal repository or add portal integration.
