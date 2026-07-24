# Request-creation MariaDB integration specification

Run this specification only on the controlled Koha 26.05 test instance with synthetic patrons, biblios, portal UUIDs, and an eligible protected EbookContent mapping.

1. Start with no matching request or correlation event.
2. Call the internal persistence service and verify one committed `PENDING` request and one `REQUEST_CREATED` event.
3. Verify the request/event timestamps, canonical JSON validity, actor-versus-subject IDs, null loan/renewal IDs, `NOT_REQUIRED`, and zero delivery attempts.
4. Repeat the exact idempotency command and verify the original request is returned with no second event.
5. Reuse the key while changing each effective field and verify `IDEMPOTENCY_CONFLICT` with no writes.
6. Use another key for the same patron/biblio and verify `DUPLICATE_PENDING` with no writes.
7. Force event insertion failure and verify the request insert rolls back.
8. Run two concurrent transactions for the same idempotency key and verify one request/event, one `CREATED`, and one authoritative replay.
9. Run two concurrent transactions with different keys for the same patron/biblio and verify one request/event plus one authoritative duplicate-pending result.
10. Confirm MariaDB reports duplicate-key code 1062 for both unique-guard race paths and that the service's locking reread sees the committed winner.
11. Verify no raw SQL, index name, DSN, path, or driver exception reaches the service result.
12. Remove only the synthetic request/event rows after verification.

Record the Koha version, MariaDB version, isolation level, plugin version, synthetic identifiers, assertion results, and cleanup result. Do not run this against production data.
