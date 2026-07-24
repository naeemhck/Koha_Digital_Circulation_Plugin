# Portal request application orchestration

## Internal boundary

`Service::PortalRequestApplication::create_request` coordinates portal-originated request creation without exposing HTTP behavior. It accepts a trusted Koha controller/request context plus the subject patron ID, biblio ID, portal request UUID, idempotency UUID, and correlation UUID.

The production constructor composes the existing `PortalServiceAuthorization`, `EbookContentEligibility`, and `RequestService`. Each dependency and the patron validator can be injected for deterministic tests.

## Security-sensitive order

The application performs:

1. `PortalServiceAuthorization::authorize_controller`
2. Extract the allowlisted service actor borrowernumber
3. Structurally validate the subject patron ID
4. Confirm the patron through the existing validation helper
5. Structurally validate the biblionumber
6. Call `EbookContentEligibility::check_biblio_eligibility`
7. Call `RequestService::create_portal_request`
8. Normalize the application result

Authorization always precedes patron, biblio, and protected-content existence checks. An unauthenticated or unlisted caller therefore cannot use this service to probe institutional records.

## Actor and subject

The actor comes only from Koha's authenticated controller context and the configured exact service-account allowlist. Arbitrary actor or source arguments are ignored. The subject patron is independently validated as a complete positive borrowernumber and confirmed through Koha.

Persistence receives the authorized actor as `actor_id`, the validated subject as `patron_id`, and a forced `PORTAL` source. Protected filename, upload ID, checksum, path, and other content metadata are not forwarded because the request schema is biblio-based.

## Stable results

Successful `CREATED`, `IDEMPOTENT_REPLAY`, and `DUPLICATE_PENDING` results retain the authoritative request, flags, and supplied correlation ID. Safe persistence failures retain their existing codes.

Application failures are limited to the approved codes: malformed input, malformed idempotency key, authentication/authorization denial, missing patron or biblio, ineligible content, idempotency conflict, dependency unavailability, and internal error. Exceptions and malformed dependency results fail closed. Diagnostic callbacks receive only safe categories and cannot change results.

`CONTENT_LOOKUP_UNAVAILABLE` from eligibility becomes `DIGITAL_CIRCULATION_UNAVAILABLE`; other verified ineligibility becomes `CONTENT_NOT_ELIGIBLE`. The application never returns protected-content metadata or dependency exceptions.

## Separation and remaining work

The application contains no SQL, audit encoding, duplicate-key handling, transaction ownership, HTTP status mapping, response rendering, controller logic, or OpenAPI definition. Persistence remains in `RequestService`; HTTP mapping belongs to the later controller unit.

On the controlled Debian/Koha 26.05 environment, verify construction with the installed plugin instance, OAuth `koha.user` context, configured allowlist, real patron lookup, EbookContent v0.1.2 eligibility, and the transactional persistence service. No live integration is claimed by the Windows dependency-double tests.
