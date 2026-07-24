# Pending request persistence

## Internal command boundary

`Service::RequestService::create_portal_request` is an internal persistence API. It accepts the authenticated service actor ID, subject patron ID, Koha biblionumber, portal request UUID, idempotency UUID, correlation UUID, and the forced source `PORTAL`.

The method validates only this structural write contract. Service-account authorization, patron existence, biblio existence, and protected EbookContent eligibility remain responsibilities of the future application/controller orchestration layer.

No HTTP route invokes this command yet.

## Transaction and atomicity

`RequestService` obtains one Koha database handle and owns one DML transaction. The request and event repositories receive that same handle and never begin or complete transactions themselves.

Within the transaction the service:

1. Checks the idempotency key.
2. Checks for an existing `PENDING` request for the subject patron and biblio.
3. Inserts one `PENDING`, `PORTAL` request with `row_version = 1`.
4. Inserts one `REQUEST_CREATED` event.
5. Commits both.

Any repository, encoding, clock, or commit failure triggers a rollback attempt and returns only `DIGITAL_CIRCULATION_UNAVAILABLE`. The raw exception is retained only on the service instance for internal diagnosis and is never copied into the result.

The default handle comes from Koha's database context. The default clock uses `Koha::DateUtils`, and canonical JSON is generated with sorted keys.

## Repeat classifications

- `IDEMPOTENT_REPLAY`: the key and effective payload (`portal_request_id`, subject patron, biblio, and source) match. The authoritative existing request is returned and no event is added.
- `IDEMPOTENCY_CONFLICT`: the key exists but an effective field differs. Nothing is written.
- `DUPLICATE_PENDING`: another key was supplied but the patron/biblio already has a pending request. The authoritative pending request is returned and no event is added.

The schema's idempotency and generated pending-guard unique indexes are the final concurrency guards. Initial prechecks are non-locking, so correctness does not depend on them serializing competing creators. If an insert loses a duplicate-key race, the service uses locking/current rereads in the same transaction rather than relying on an older repeatable-read snapshot, then applies the same classifications. It does not retry the insert or expose driver errors or index names.

## Audit record

The event records `REQUEST_CREATED` for aggregate `REQUEST`. Its request and aggregate IDs are the new request ID; loan and renewal IDs are null. `patron_id` is the subject patron while `actor_patron_id` is the authenticated portal service actor. Delivery is `NOT_REQUIRED` with zero attempts.

The canonical JSON payload contains only request ID, portal request ID, previous/new status, actor ID, subject patron ID, biblio ID, and source. It excludes credentials, headers, protected-content metadata, filesystem paths, and exception details.

## Remaining integration verification

Windows tests use deterministic database and repository doubles. On the controlled Koha 26.05/MariaDB host, verify transaction isolation, duplicate-key error code 1062, both unique-index race paths, rollback after an event failure, and the timestamp/JSON behavior using synthetic records. These tests do not claim live MariaDB concurrency verification.
