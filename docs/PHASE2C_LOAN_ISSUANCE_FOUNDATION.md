# Phase 2C — Loan issuance foundation

Phase 2C foundation does not alter the verified Phase 2B approval behavior.

Verified Phase 2B contract remains:

`APPROVE` → request becomes `APPROVED` → no loan → no protected access

This unit adds an internal transactional service that can create one
authoritative digital loan from an already-approved request. It is not wired
into the approval endpoint or staff UI. Staff REST exposure is documented
separately in `docs/PHASE2C_STAFF_LOAN_ISSUANCE_HTTP_API.md`.

## Authoritative request identity

`LoanIssuanceService->issue_loan` accepts only trusted application command
fields:

- `request_id` (required positive decimal)
- `actor_id` (required positive decimal issuer)
- optional `correlation_id` UUID (generated when omitted)

Patron ID, biblio ID, and approval metadata are read from the locked request
row. Caller-supplied patron/biblio/status/timestamp/content fields are ignored.

The request table does not store a portal eBook UUID; content identity continues
to be resolved through Koha `biblio_id` and EbookContent eligibility.

## Required request state

Only `APPROVED` may be issued.

`PENDING`, `REJECTED`, `CANCELLED`, unknown statuses, and missing requests fail
closed with zero loan rows and zero events. The request row is not mutated;
approval metadata and `row_version` remain unchanged.

## Loan table mapping

Existing schema version 1 table `plugin_jzl_ebook_loans` is used unchanged:

- unique `request_id` (`jzl_loan_request_uq`) enforces one loan per request
- FK to `plugin_jzl_ebook_requests`
- start timestamp column: `started_at` (no `issued_at` column)
- due timestamp column: `due_at` with `due_at > started_at`
- issuer column: `approved_by`
- concurrency: `row_version`

No schema migration is required.

## Selected active loan status

Newly issued loans use canonical status `ACTIVE`.

Later units may transition to `RENEWAL_PENDING`, `RETURNED`, `EXPIRED`, or
`REVOKED`. Those transitions are out of scope here.

## Loan-period policy boundary

Issuance requires an injected `due_date_policy` that returns either:

- `{ ok => 1, due_at => 'YYYY-MM-DD HH:MM:SS' }`; or
- `{ ok => 1, duration_seconds => N }` with `N >= 1`

Invalid, missing, equal, or earlier due times fail closed as
`INVALID_LOAN_PERIOD`. The no-policy default still fails closed.

Production construction now supplies
`ConfiguredLoanPeriodPolicy`, which reads
`default_loan_duration_days` from plugin configuration. Blank or invalid
configuration continues to fail closed as `INVALID_LOAN_PERIOD`. Due dates are
not accepted from HTTP callers. See
`docs/PHASE2C_PRODUCTION_LOAN_PERIOD_POLICY.md`.

## Protected-content revalidation

Before insert, the service calls the existing
`EbookContentEligibility->check_biblio_eligibility` boundary for the request
biblio. It does not duplicate EbookContent lookup logic and does not fetch or
stream PDF bytes.

Failure mappings:

- lookup unavailable / missing content → `PROTECTED_CONTENT_UNAVAILABLE`
- invalid/disabled/ineligible mapping → `INVALID_MAPPING`

## Idempotency and concurrency

Duplicate issuance returns `LOAN_ALREADY_EXISTS`.

Within a transaction the service:

1. locks the request (`get_for_issuance` / `FOR UPDATE`)
2. rejects non-`APPROVED` states
3. looks up any existing loan for the request
4. inserts at most one loan
5. inserts at most one `LOAN_CREATED` event

The unique request index is a second defense against concurrent winners.

## Transaction boundary

Loan insert and `LOAN_CREATED` event insert share one DB transaction
(`begin_work` / `commit` / `rollback`). Any failure rolls back both. No native
Koha `issues` / `old_issues` rows are written. No reader session, token, or
entitlement is created.

## Audit event

Event type: `LOAN_CREATED`

Aggregate: `LOAN` / loan ID

Safe payload links include loan ID, request ID, patron ID, biblio ID, actor ID,
`started_at`, `due_at`, and resulting `ACTIVE` status. Payload excludes PDF
paths, tokens, cookies, credentials, SQL, and stack traces.

## Failure codes

Internal service codes only (no HTTP mapping in this unit):

- `INVALID_INPUT`
- `REQUEST_NOT_FOUND`
- `REQUEST_NOT_APPROVED`
- `LOAN_ALREADY_EXISTS`
- `PROTECTED_CONTENT_UNAVAILABLE`
- `INVALID_MAPPING`
- `INVALID_LOAN_PERIOD`
- `DIGITAL_CIRCULATION_UNAVAILABLE`
- `INTERNAL_ERROR`

## Diagnostics

Optional normalized categories:

- `request_not_found`
- `request_not_approved`
- `duplicate_loan`
- `protected_content_validation_failed`
- `loan_policy_failed`
- `transaction_failed`

Diagnostic callback failure cannot replace the safe domain result.

## Integration status

Not in this unit:

- wiring into `APPROVE`
- REST `/loans` or issue routes
- staff Issue UI controls
- PDF access / reader tokens
- renewals, returns, revocation, expiry jobs
- portal My Loans sync

Next integration options:

1. invoke issuance immediately after successful approval in a later unit; or
2. expose a separate staff-triggered issue command after approval; or
3. orchestrate issuance from a dedicated application service with an explicit
   institutional due-date policy.
