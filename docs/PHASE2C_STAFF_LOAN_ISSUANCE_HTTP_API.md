# Phase 2C — Staff loan-issuance HTTP API

This unit exposes `StaffLoanIssuanceApplication` through one controlled Koha
staff REST endpoint. Approval remains separate from issuance. No staff UI Issue
control is added in this unit.

## Route and operation

Plugin-relative route:

`POST /requests/{request_id}/issue`

Full Koha route:

`POST /api/v1/contrib/jzl-digital-circulation/requests/{request_id}/issue`

Operation ID:

`jzlIssueDigitalLoan`

Controller:

`Controller::Requests#issue`

Final POST write routes are exactly:

1. `POST /requests`
2. `POST /requests/{request_id}/decision`
3. `POST /requests/{request_id}/issue`

## Authentication and permission

The route declares the same Koha staff permission gateway as decision:

`circulate => circulate_remaining_permissions`

`StaffLoanIssuanceApplication` remains authoritative for:

- authenticated actor extraction from `stash('koha.user')`
- portal-service actor exclusion
- staff permission verification

## Portal-service actor exclusion

Configured identities in `portal_service_account_ids` are denied staff issuance
before permission lookup and before any request/loan inspection. Portal
allowlist membership authorizes portal request creation only.

Actor 53 therefore receives only:

HTTP `403` / `STAFF_NOT_AUTHORIZED`

No request-state, content, loan, or configuration detail is disclosed.

## Required correlation ID

Header:

`X-Correlation-ID`

Must be a canonical UUID matching the decision endpoint pattern. Missing,
blank, malformed, whitespace-padded, and ambiguous multi-value headers fail as:

HTTP `400` / `INVALID_INPUT`

The server does not generate a replacement UUID.

## Request body

Preferred request:

```http
POST /requests/{request_id}/issue
X-Correlation-ID: <uuid>
```

No body.

An empty JSON object `{}` is accepted only because Koha/Mojolicious request
parsing may present an empty object when no meaningful body is supplied.
Any non-empty body is rejected as:

HTTP `400` / `INVALID_INPUT`

Caller-controlled authority fields are never accepted, including `actor_id`,
`patron_id`, `biblio_id`, `portal_ebook_uuid`, `status`, `started_at`,
`due_at`, `duration`, `duration_days`, `approved_by`, `renewal_count`,
`content_path`, `token`, and `entitlement`.

## Request ID

`request_id` comes only from the path and must be a canonical positive integer
(`[1-9][0-9]*`). Zero, negative, decimal, exponent, partial, padded, and other
noncanonical values fail as `INVALID_INPUT` before application business work
that would disclose request existence to unauthorized callers.

## Processing order

1. validate correlation header
2. validate path request ID shape
3. reject non-empty request body
4. construct `StaffLoanIssuanceApplication`
5. application authenticates and authorizes staff
6. application validates request ID and invokes `LoanIssuanceService`
7. controller validates the application result
8. controller returns the safe HTTP response

## Application invocation

```perl
$application->issue_loan({
    controller => $c,
    request_id => $request_id,
});
```

The controller does not call `LoanIssuanceService` directly and does not pass
actor, patron, biblio, due date, status, duration, or content fields.

## Success response

First successful issuance returns HTTP `201` with only:

```json
{
  "loan_id": 1,
  "request_id": 6,
  "patron_id": 12,
  "biblio_id": 34,
  "status": "ACTIVE",
  "started_at": "YYYY-MM-DD HH:MM:SS",
  "due_at": "YYYY-MM-DD HH:MM:SS",
  "row_version": 1
}
```

A successful response means only that an authoritative ACTIVE plugin-owned
digital-loan row was created. It does not grant PDF/reader access and does not
create a native Koha issue.

## HTTP status mappings

| Application code | HTTP |
|---|---|
| `AUTHENTICATION_REQUIRED` | 401 |
| `STAFF_NOT_AUTHORIZED` | 403 |
| `INVALID_INPUT` | 400 |
| `REQUEST_NOT_FOUND` | 404 |
| `REQUEST_NOT_APPROVED` | 409 |
| `LOAN_ALREADY_EXISTS` | 409 |
| `INVALID_MAPPING` | 409 |
| `PROTECTED_CONTENT_UNAVAILABLE` | 503 |
| `INVALID_LOAN_PERIOD` | 503 |
| `DIGITAL_CIRCULATION_UNAVAILABLE` | 503 |
| `INTERNAL_ERROR` | 500 |
| unknown / malformed result | 500 `INTERNAL_ERROR` |

Public bodies use fixed safe messages. Raw service messages and stack traces are
not returned.

## Malformed-result handling

Undefined results, non-hash results, missing `ok`, unknown codes, success
without a safe loan, non-`ACTIVE` status, malformed timestamps, or unexpected
nested objects fail closed as HTTP `500` / `INTERNAL_ERROR`.

## Idempotency and concurrency

Repeated issuance for the same approved request returns:

HTTP `409` / `LOAN_ALREADY_EXISTS`

No second loan row and no second `LOAN_CREATED` event are created. The unique
`request_id` loan constraint remains unchanged.

## Transactions

Loan insert and `LOAN_CREATED` event insert remain atomic inside
`LoanIssuanceService`. Event failure rolls back the loan. Policy and
protected-content failures create zero writes.

## Configured duration and content revalidation

Due dates come from `ConfiguredLoanPeriodPolicy` /
`default_loan_duration_days` (strict range 1–365). Blank or invalid duration
fails as `INVALID_LOAN_PERIOD`.

Protected-content eligibility is revalidated through the existing EbookContent
boundary before insert.

## Explicit non-goals in this unit

- staff Issue Loan UI is documented in `docs/PHASE2C_STAFF_LOAN_ISSUANCE_UI.md`
- no automatic loan creation during approval
- no PDF reader access / tokens / entitlements
- no protected-content streaming changes
- no portal My Loans synchronization
- no renew / return / revoke / expiry routes
- no native Koha issue creation
- no schema change
- no KPZ packaging or deployment
- no live loan creation in this unit

## Current UI status

The pending-safe Issue Loan staff control now exists and calls this REST
endpoint. See `docs/PHASE2C_STAFF_LOAN_ISSUANCE_UI.md`.
