# Phase 3A — Portal loan-read API

This unit exposes a read-only, backend-service-only endpoint that returns
authoritative plugin-owned digital-loan rows for one Koha patron.

## Route

Plugin-relative path:

`GET /patrons/{patron_id}/loans`

Full Koha path:

`GET /api/v1/contrib/jzl-digital-circulation/patrons/{patron_id}/loans`

Operation ID:

`jzlListPatronDigitalLoans`

Controller:

`Controller::Patrons#list_loans`

Application:

`Service::PortalLoanReadApplication`

Authorization:

`Service::PortalServiceAuthorization`

Repository:

`LoanRepository::list_for_patron`

## Backend-service-only intent

This endpoint must be called by a trusted allowlisted portal service account.
It must not be called from browser JavaScript or an end-user portal session
cookie.

The portal backend is responsible for deriving `patron_id` from its own
authenticated session before calling Koha.

## Portal-service authorization

Processing requires:

1. an authenticated Koha actor from `stash('koha.user')`;
2. a canonical borrowernumber;
3. membership in `portal_service_account_ids`.

Staff circulation permissions do not authorize this endpoint.

Existing denial code is preserved:

`SERVICE_ACCOUNT_NOT_AUTHORIZED`

## Actor separation

- Actor 53 (allowlisted portal service) may read patron loans.
- Actor 51 (staff, not allowlisted) receives HTTP 403
  `SERVICE_ACCOUNT_NOT_AUTHORIZED`.
- Portal allowlisting still does not authorize staff decisions or issuance.

## Correlation ID

Header `X-Correlation-ID` is required and must be a canonical UUID.
Malformed, blank, padded, or missing values fail as HTTP 400 `INVALID_INPUT`.
The server does not generate a replacement UUID.

## Patron ID trust model

`patron_id` comes only from the path and must be a canonical positive integer.
Unknown patrons and patrons with no digital loans both return HTTP 200 with an
empty `loans` array. The endpoint never queries or discloses borrower profile
data.

## Pagination

- default `page`: 1
- default `per_page`: 20
- minimum `per_page`: 1
- maximum `per_page`: 100

Malformed values are rejected.

Ordering is fixed:

1. `created_at DESC`
2. `loan_id DESC`

## Safe response fields

```json
{
  "loans": [
    {
      "loan_id": 1,
      "request_id": 7,
      "portal_request_id": "canonical UUID",
      "patron_id": 50,
      "biblio_id": 1,
      "status": "ACTIVE",
      "started_at": "...",
      "due_at": "...",
      "returned_at": null,
      "revoked_at": null,
      "expired_at": null,
      "renewal_count": 0,
      "row_version": 1,
      "created_at": "...",
      "updated_at": "..."
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total": 1,
    "total_pages": 1
  }
}
```

## `portal_request_id` meaning

`portal_request_id` is the authoritative correlation identifier of the portal
request that produced the digital request. It is not a portal eBook identifier.
The portal integration layer will resolve its local eBook record using the
existing portal request relationship and the authoritative Koha `biblio_id`.

No schema migration was introduced because the plugin request table already
stores `portal_request_id`. `portal_ebook_uuid` is not emitted because it is
not an authoritative plugin field and must not be fabricated from `biblio_id`
or any other value.

## Request join

`list_for_patron` joins:

`plugin_jzl_ebook_loans` → `plugin_jzl_ebook_requests` on `request_id`

Integrity mismatches (patron or biblio disagreement between loan and request)
and malformed authoritative `portal_request_id` values fail closed as
`INTERNAL_ERROR`.

## Status handling

All authoritative loan lifecycle statuses are returned:

`ACTIVE`, `RENEWAL_PENDING`, `RETURNED`, `EXPIRED`, `REVOKED`

This unit does not expose a status query filter.

## HTTP mappings

| Result | HTTP | Code |
| --- | --- | --- |
| Success, including empty list | 200 | — |
| Malformed input | 400 | `INVALID_INPUT` |
| Missing/invalid authentication | 401 | `AUTHENTICATION_REQUIRED` |
| Authenticated non-allowlisted actor | 403 | `SERVICE_ACCOUNT_NOT_AUTHORIZED` |
| Internal malformed authoritative data | 500 | `INTERNAL_ERROR` |
| Repository/dependency failure | 503 | `DIGITAL_CIRCULATION_UNAVAILABLE` |

## Non-goals

- no portal My Loans synchronization
- no portal repository changes
- no reader access, tokens, or PDF paths
- no writes, renewals, returns, revocation, or expiry jobs
- no new POST routes
- no schema migration
- no RC7 package or deployment in this unit

## Next unit

A later unit may integrate the portal server and local shadow read model using
this authoritative feed.
