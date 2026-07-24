# Phase 2C — Staff loan-issuance UI

This unit adds a pending-safe Issue Loan control for already-approved requests
in the Koha staff Digital eBook Requests tool. The control calls the verified
issuance REST endpoint and does not invent loan authority fields.

## Eligibility

Show Issue Loan only when all authoritative conditions are true:

- request status is exactly `APPROVED`
- the request loan summary is authoritatively absent

Do not show Issue Loan for PENDING, REJECTED, CANCELLED, unknown statuses,
APPROVED requests that already have a loan, or malformed loan summaries.

Approve and Reject remain available only for PENDING requests.

## Approval versus issuance

Approval records the librarian decision only. Issuance is a separate action that
creates one ACTIVE plugin-owned digital loan. The staff banner and confirmation
dialog both state this separation.

## Existing-loan presentation

When a request already has a loan, the UI shows a read-only summary:

- label: Active digital loan
- loan status
- started timestamp
- due timestamp

Issue Loan is suppressed. No reader-access, PDF, return, renew, revoke, delete,
or edit controls are shown.

## Authoritative loan summary

Staff GET `/requests` and GET `/requests/{request_id}` reuse the existing routes
and left-join `plugin_jzl_ebook_loans` once per list/get query.

Safe summary fields:

- `loan_id`
- `loan_status`
- `loan_started_at`
- `loan_due_at`
- `loan_row_version`

Null values mean no loan. The UI fails closed when the summary is ambiguous.

## Server-authoritative duration

The UI never calculates due dates and never accepts duration input. Due dates
come from configured `default_loan_duration_days` on the server.

## HTTP request

On confirmation:

`POST /api/v1/contrib/jzl-digital-circulation/requests/{request_id}/issue`

- same-origin URL
- `credentials: 'same-origin'`
- fresh canonical `X-Correlation-ID`
- no request body
- no Authorization header
- no actor, patron, biblio, due date, duration, status, token, or entitlement

## Duplicate-submission protection

Issuance uses the existing per-row `inFlight` lock. While pending, Issue Loan is
semantically disabled, progress text is shown, and duplicate mouse/keyboard
activation is blocked. No optimistic ACTIVE state is applied before HTTP 201.

## Success handling

HTTP 201 is accepted only with the exact safe loan payload and `ACTIVE` status
for the same request ID. The UI then:

1. updates the loan summary
2. removes Issue Loan
3. announces “Digital loan issued successfully.”
4. performs an authoritative background refresh

## Fixed safe errors

Issuance uses fixed messages for 400, 401, 403, 404, the documented 409 codes,
the documented 503 codes, and 500. Raw API bodies, SQL, paths, tokens, and
configuration values are never rendered.

## Conflict and stale state

`LOAN_ALREADY_EXISTS`, `REQUEST_NOT_APPROVED`, `REQUEST_NOT_FOUND`, and
`INVALID_MAPPING` show a fixed message and refresh authoritative state. The UI
does not retry issuance automatically.

## Accessibility and DOM safety

Issue Loan is a real labelled button with confirmation, disabled state, polite
success announcement, and assertive errors where appropriate. Dynamic values use
`textContent` only. Correlation UUIDs are not stored in browser storage.

## Explicit non-goals

- no automatic issuance during approval
- no reader entitlement or PDF access
- no renew / return / revoke UI
- no native Koha issue creation
- no schema change
- no KPZ packaging or deployment in this unit
- no live loan creation during this local unit

## Next step

RC6 packaging and controlled live verification of staff issuance.
