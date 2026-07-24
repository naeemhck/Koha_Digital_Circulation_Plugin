# Request decision persistence

Phase 2B adds an internal transactional boundary for deciding an existing
digital-circulation request. It does not add an HTTP route, staff action,
permission check, loan, renewal, entitlement, reader session, or native Koha
circulation write.

## Internal API

`RequestDecisionService->decide_request` accepts:

```perl
my $result = $service->decide_request(
    actor_id             => 53,
    request_id           => 2,
    expected_row_version => 1,
    decision             => 'APPROVE', # or REJECT
    reason               => undef,
    correlation_id       => 'db421a13-f74a-4388-a681-897ec46156f4',
);
```

Only `APPROVE` and `REJECT` are accepted. Identifiers must be complete positive
decimal integers, and the correlation ID must be a valid UUID. The service
returns normalized request fields and never returns SQL, DBI errors, table or
index names, credentials, paths, or stack traces.

Authentication, librarian permissions, HTTP status mapping, CSRF behavior, and
staff UI controls remain future application/controller work.

## State transitions

The existing `StateMachine` remains authoritative:

```text
PENDING -> APPROVED
PENDING -> REJECTED
```

An already approved or rejected request returns
`REQUEST_ALREADY_DECIDED`. Cancelled, expired, and unknown states return
`INVALID_STATE`. A completed decision is never overwritten and never creates a
second audit event.

An approved request may exist before loan issuance. The schema does not require
a loan for an approved request, and this unit intentionally creates no loan or
access entitlement.

## Decision fields and reasons

Approval writes the existing `approved_at` and `approved_by` columns. Rejection
writes `rejected_at`, `rejected_by`, and `rejection_reason`. Both transitions
increment `row_version` exactly once.

Rejection requires a nonblank reason. Approval may omit its reason or supply a
safe reason. The request schema has no approval-reason column, so an approval
reason is included only in the immutable audit payload; it is never written to
`rejection_reason`.

Reasons are scalar plain text with a service limit of 4,096 characters, well
below the MariaDB `TEXT` column capacity even for utf8mb4 content. The service
does not trim or truncate nonblank text. It rejects references, control
characters, HTML delimiters, executable URI schemes, and oversized text. A
blank approval reason normalizes to null; a blank rejection reason fails with
`INVALID_REASON`.

## Transaction and optimistic concurrency

One service owns one database transaction:

```text
begin
-> locking request read
-> state and expected-version validation
-> guarded pending-request update
-> authoritative reread
-> canonical audit payload encoding
-> one audit-event insert
-> commit
```

The repositories receive the transaction-owned database handle and never
commit or roll back independently. A request update, event insert, encoding,
clock, or commit failure triggers a rollback attempt. Diagnostic callback
failure cannot replace the stable safe result.

The guarded update matches `request_id`, `status = 'PENDING'`, and the supplied
`row_version`. It increments `row_version` in SQL and is never blindly retried.
If no row is updated, an authoritative reread classifies the outcome as:

- `REQUEST_NOT_FOUND`;
- `VERSION_CONFLICT`;
- `REQUEST_ALREADY_DECIDED`;
- `INVALID_STATE`; or
- `DIGITAL_CIRCULATION_UNAVAILABLE`.

## Audit events

Approval creates `REQUEST_APPROVED`; rejection creates `REQUEST_REJECTED`.
Both use:

```text
aggregate_type: REQUEST
aggregate_id: request_id
request_id: request_id
loan_id: null
renewal_id: null
patron_id: subject patron
biblio_id: requested biblio
actor_patron_id: librarian actor
source: STAFF
correlation_id: supplied UUID
delivery_status: NOT_REQUIRED
delivery_attempts: 0
```

Payloads use canonical JSON and distinguish the staff actor from the subject
patron. They contain request identity, portal request identity, previous and
new status, actor, patron, biblio, and source. Rejection includes its safe
reason; approval includes its safe reason only when one was supplied. Payloads
do not imply that a loan or entitlement exists.

## Stable failures

The internal failure codes are:

- `INVALID_INPUT`
- `INVALID_DECISION`
- `INVALID_REASON`
- `REQUEST_NOT_FOUND`
- `VERSION_CONFLICT`
- `REQUEST_ALREADY_DECIDED`
- `INVALID_STATE`
- `DIGITAL_CIRCULATION_UNAVAILABLE`
- `INTERNAL_ERROR`

HTTP status mapping is deliberately absent.

## Remaining integration work

A later unit must add authenticated librarian authorization, controller and
REST mapping, CSRF-aware staff actions, UI controls, and the separate
loan-issuance transaction. Approval in this unit must not be treated as active
digital access.

Debian/MariaDB integration testing must still verify real InnoDB rollback,
locking behavior, concurrent guarded updates, affected-row semantics, JSON
storage, check constraints, and event uniqueness. Windows tests use injected
repositories and transaction fakes and do not claim live database concurrency
coverage.
