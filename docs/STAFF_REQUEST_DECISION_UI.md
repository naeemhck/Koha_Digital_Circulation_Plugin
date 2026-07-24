# Staff request-decision interface

## Scope

The Koha staff tool is a client-enhanced request view for librarians who already
hold `circulate_remaining_permissions`. The REST endpoint remains the
authoritative authentication, authorization, validation, concurrency, and
persistence boundary.

Only requests whose authoritative status is `PENDING` receive **Approve** and
**Reject** controls. Approved, rejected, cancelled, and unknown states remain
read-only. The page provides no generic status editor and no create, delete,
loan, renewal, return, revoke, entitlement, or reader-session control.

**Approval does not yet create a digital loan or grant protected-content
access.**

## Page workflow

The template renders the Koha staff-page structure and accessible dialog. The
plugin-local JavaScript loads the selected view through the existing
same-origin staff GET endpoint. Request rows display an explicit allowlist of
operational fields: request ID, safe patron and bibliographic labels, status,
requested time, row version, decision details, and rejection reason.

Internal persistence fields, idempotency data, pending guards, previous
correlation IDs, event payloads, protected-content details, and raw patron
objects are not rendered.

## Approval

Approve opens a native browser confirmation:

> Approve this digital request?
>
> This records the librarian decision only. It does not create a loan or grant
> digital access.

After confirmation, both controls for that row are disabled and the page sends:

```json
{
  "expected_row_version": 1,
  "decision": "APPROVE",
  "reason": null
}
```

The actual positive `row_version` displayed for the request replaces the
example value.

## Rejection

Reject opens a labelled native `<dialog>` with a required plain-text textarea,
Cancel button, and Reject Request button. The reason must be nonblank and at
most 4,096 characters. It is never truncated and is rendered only through DOM
`textContent`. A native prompt is the narrow fallback when `<dialog>` is not
supported.

The command contains only `expected_row_version`, `decision`, and `reason`.
Actor, patron, biblio, status, event, source, and circulation fields are never
sent by the UI.

## REST and correlation behavior

Every attempt calls only:

```text
POST /api/v1/contrib/jzl-digital-circulation/requests/{request_id}/decision
```

The request uses `credentials: "same-origin"` and does not construct an
Authorization header. A new correlation UUID is generated for every attempt
with `crypto.randomUUID()`. The fallback uses `crypto.getRandomValues()` and
sets RFC 4122 version and variant bits. Correlation IDs are not displayed,
logged, placed in URLs, or stored in browser storage.

## Success and authoritative refresh

The page does not change status before HTTP 200. It validates the success
shape, replaces only public decision fields, updates the status, actor,
timestamp, reason, and row version, removes active controls, and announces:

```text
Request approved successfully.
```

or:

```text
Request rejected successfully.
```

It then performs a background GET for the authoritative request. Success
wording never claims that a loan, issue, reader, entitlement, or protected
access was created.

## Conflicts and failures

`VERSION_CONFLICT`, `REQUEST_ALREADY_DECIDED`, and `INVALID_STATE` display
fixed safe messages and refresh the authoritative list. The UI never retries a
decision automatically. Request-not-found, unavailable-service, internal,
malformed-response, and network outcomes also refresh before another decision
can be attempted.

All known errors map to fixed product messages. Raw response bodies, exception
text, SQL/DBI details, filesystem paths, credentials, cookies, and stack traces
are never rendered.

## Duplicate-submission and accessibility behavior

An in-memory per-request lock disables both controls for the selected row while
a request is active. Unrelated rows remain available. The rejection form has a
second submission lock, disables its controls while submitting, and prevents
Escape from closing a submitting dialog. Server-side `row_version` remains the
authoritative concurrency control.

Controls are real buttons with request-specific labels. The rejection textarea
has an explicit label and description. Focus enters the reason field and
returns to the triggering button after cancellation. Validation uses an
assertive alert region; page and success status use polite live regions.
Status is communicated as text as well as scoped badge styling.

## CSP and dependency choice

All behavior is in the existing plugin-local JavaScript asset. The template has
no inline event handlers, executable strings, remote scripts, external fonts,
or new frontend framework. Dynamic operational content uses DOM nodes and
`textContent`, never `innerHTML`.

## Remaining live verification

This source unit performs static Windows validation only. A later controlled
deployment should verify keyboard focus, dialog layout, Koha session expiry,
permission denial, simultaneous staff decisions, and authoritative row refresh
in supported staff browsers.

## Deployment hardening

Configured portal service accounts, including actor 53, are denied by the
staff decision endpoint even if they hold `circulate_remaining_permissions`.
The browser receives only the existing safe `STAFF_NOT_AUTHORIZED` response;
it receives no account-classification detail. Do not remove actor 53's
circulation permission yet: Phase 2A `/requests` creation currently uses the
same Koha permission gateway. A future narrower permission or redesigned
portal authentication boundary can restore a portal-only permission posture.

## Future work

Approved-request loan issuance is a separate future unit. It must not be
inferred from, or added to, this request-decision interface.
