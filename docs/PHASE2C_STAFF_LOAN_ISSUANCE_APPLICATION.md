# Phase 2C — Staff loan-issuance application

`StaffLoanIssuanceApplication` is the HTTP-independent Phase 2C boundary that
authorizes trusted Koha staff, validates a minimal issuance command, and
delegates to `LoanIssuanceService`.

The staff issuance application does not alter Phase 2B approval behavior. It is
now reachable through the controlled staff REST endpoint documented in
`docs/PHASE2C_STAFF_LOAN_ISSUANCE_HTTP_API.md`. The staff Issue Loan UI is
documented in `docs/PHASE2C_STAFF_LOAN_ISSUANCE_UI.md`.

## Trusted Koha actor source

The authenticated actor is derived only from trusted Koha request context:

`stash('koha.user')`

via reused `StaffDecisionAuthorization`. Actor authority is never accepted from
body, query string, path, headers, environment variables, or caller-supplied
hash fields.

## Authorization order

Fail-closed processing order:

1. authenticated Koha context
2. staff authorization
3. command validation
4. `LoanIssuanceService->issue_loan`

Unauthorized actors do not learn whether a request exists, is approved, already
has a loan, or has invalid content. Actor 53 receives only
`STAFF_NOT_AUTHORIZED`, and `LoanIssuanceService` is not invoked.

## Portal-service exclusion

Configured identities in `portal_service_account_ids` are denied staff loan
issuance before the circulation permission check. Portal allowlist membership
authorizes portal request creation only; it never authorizes staff issuance.

Ordinary librarians are not required to appear in the portal allowlist.

## Required staff permission

Authorized staff must have:

`circulate_remaining_permissions`

Circulation permission does not override portal-service exclusion.

## Strict command allowlist

Accepted application command keys:

- `controller` (trusted Koha context)
- `request_id` (canonical positive integer)

Any other field—including `actor_id`, `patron_id`, `biblio_id`, `status`,
`started_at`, `due_at`, duration, content path, entitlement, or token—is
rejected as `INVALID_INPUT`.

`expected_request_row_version` is not part of the current
`LoanIssuanceService` command contract and is not accepted here.

## Request ID validation

`request_id` must match the established positive-decimal convention
(`[1-9][0-9]*`). Missing, zero, negative, decimal, exponent, partial, padded,
leading-zero, reference, and other noncanonical values fail as
`INVALID_INPUT`.

## Caller-authority rejection

Caller-supplied `actor_id` never grants authority and never replaces the
authenticated actor. The authorized borrowernumber is forwarded exactly once to
`LoanIssuanceService`.

## LoanIssuanceService delegation

Conceptual call:

```perl
$loan_issuance_service->issue_loan({
    request_id => $validated_request_id,
    actor_id   => $authorized_actor_id,
});
```

The application does not calculate due dates, look up protected content, open
transactions, or invent patron/biblio identity. Those remain
`LoanIssuanceService` responsibilities.

## Due-date policy boundary

The application does not calculate due dates. When constructed through the
plugin factory, `LoanIssuanceService` receives `ConfiguredLoanPeriodPolicy`.
Blank or invalid `default_loan_duration_days` still fails closed as
`INVALID_LOAN_PERIOD`. See `docs/PHASE2C_PRODUCTION_LOAN_PERIOD_POLICY.md`.

## Result-field allowlist

Successful application results return only:

- `loan_id`
- `request_id`
- `patron_id`
- `biblio_id`
- `status` (`ACTIVE`)
- `started_at`
- `due_at`
- `row_version`

Known safe service extras may be present on the service result and are stripped.
Unsafe or malformed success payloads fail closed as `INTERNAL_ERROR`.

## Failure codes

Authorization:

- `AUTHENTICATION_REQUIRED`
- `STAFF_NOT_AUTHORIZED`

Input:

- `INVALID_INPUT`

Service-forwarded:

- `REQUEST_NOT_FOUND`
- `REQUEST_NOT_APPROVED`
- `LOAN_ALREADY_EXISTS`
- `PROTECTED_CONTENT_UNAVAILABLE`
- `INVALID_MAPPING`
- `INVALID_LOAN_PERIOD`
- `DIGITAL_CIRCULATION_UNAVAILABLE`
- `INTERNAL_ERROR`

HTTP status mappings for the staff issuance REST adapter are defined in
`docs/PHASE2C_STAFF_LOAN_ISSUANCE_HTTP_API.md`. Raw exceptions are not exposed.

## Diagnostics

Optional normalized diagnostic categories include:

- `authentication_missing`
- `staff_not_authorized`
- `invalid_command`
- `issuance_service_failure`
- `malformed_service_result`
- `issuance_application_exception`

Diagnostic callback failure must not replace the safe application result.

## Explicit non-goals retained

- no staff UI Issue control yet
- no live loan issuance during verification of this application boundary alone
- no schema change
- no native Koha issue creation
- no reader token / entitlement / PDF access behavior

## Current integration status

The authenticated Koha staff HTTP adapter is now wired. See
`docs/PHASE2C_STAFF_LOAN_ISSUANCE_HTTP_API.md`. OpenAPI POST routes are exactly:

- `POST /requests`
- `POST /requests/{request_id}/decision`
- `POST /requests/{request_id}/issue`
