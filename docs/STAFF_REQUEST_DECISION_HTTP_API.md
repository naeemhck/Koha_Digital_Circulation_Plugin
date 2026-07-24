# Staff request-decision HTTP API

The Phase 2B staff endpoint is:

```text
POST /api/v1/contrib/jzl-digital-circulation/requests/{request_id}/decision
```

Its operation ID is `jzlDecideDigitalRequest`. Koha authenticates the request
and enforces `circulate => circulate_remaining_permissions` through the
OpenAPI route. The controller then invokes `StaffRequestDecisionApplication`,
which independently reads `stash('koha.user')`, derives the librarian
borrowernumber, and repeats the supported staff permission check. A
borrowernumber configured as a portal service account is explicitly denied
before that permission can authorize a staff decision. The response remains
`403 STAFF_NOT_AUTHORIZED`; it does not reveal the actor classification.

## Request

`request_id` is a required positive integer path value. The request must use
`Content-Type: application/json` and include a valid UUID:

```http
X-Correlation-ID: db421a13-f74a-4388-a681-897ec46156f4
```

Approval:

```json
{
  "expected_row_version": 1,
  "decision": "APPROVE",
  "reason": null
}
```

Rejection:

```json
{
  "expected_row_version": 1,
  "decision": "REJECT",
  "reason": "Request does not meet circulation requirements."
}
```

Only `expected_row_version`, `decision`, and optional `reason` are accepted.
The body is closed to additional properties. Actor, patron, biblio, status,
timestamp, source, event, loan, and renewal fields are prohibited. The
correlation ID is mandatory and is never generated or replaced by the
controller.

## Decisions and concurrency

Successful approval or rejection returns HTTP 200 with the public request,
`PENDING` as the previous status, the new decision status, previous and new
row versions, and the supplied correlation ID. Approval fields or rejection
fields are populated according to the outcome. Idempotency keys, generated
guards, audit payloads, protected-content metadata, database details, and
plugin paths are filtered.

`expected_row_version` is passed unchanged into the application and
persistence boundary. A stale version returns `409 VERSION_CONFLICT`; the
controller never retries, changes the expected version, or converts the
conflict to success. An already approved or rejected request returns
`409 REQUEST_ALREADY_DECIDED` and the original decision remains unchanged.

## Error mapping

All errors use:

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
| `INVALID_DECISION` | 400 |
| `INVALID_REASON` | 400 |
| `AUTHENTICATION_REQUIRED` | 401 |
| `STAFF_NOT_AUTHORIZED` | 403 |
| `REQUEST_NOT_FOUND` | 404 |
| `VERSION_CONFLICT` | 409 |
| `REQUEST_ALREADY_DECIDED` | 409 |
| `INVALID_STATE` | 409 |
| `DIGITAL_CIRCULATION_UNAVAILABLE` | 503 |
| `INTERNAL_ERROR` | 500 |

Unknown results and controller/application exceptions fail closed as
`INTERNAL_ERROR`. Responses never include raw exceptions, SQL, DBI data, DSNs,
paths, cookies, OAuth values, permission structures, or Koha patron objects.
All responses set `Cache-Control: no-store`.

## Layer boundaries

The controller owns HTTP extraction, mapping, and response filtering only.
`StaffRequestDecisionApplication` owns trusted actor authorization and
orchestration. `RequestDecisionService` owns validation, state enforcement,
locking, optimistic concurrency, request mutation, event insertion, commit,
rollback, and database failure classification.

This endpoint does not create a loan, renewal, entitlement, or native Koha
issue. The staff interface presents pending-only decision controls, but the
endpoint remains authoritative. Phase 2A portal request creation remains
available to configured actor 53; removing its circulation permission is not
currently safe because `/requests` uses the same permission gateway. Controlled
Debian/Koha verification must confirm OpenAPI loading, authentication
middleware, real staff permission outcomes, configured-service-account denial,
application construction, HTTP response validation, MariaDB concurrency, and
safe logs. No live Debian or Koha verification is claimed by the Windows tests.
