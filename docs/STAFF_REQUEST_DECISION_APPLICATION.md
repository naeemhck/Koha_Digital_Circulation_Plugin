# Staff request-decision application

`StaffRequestDecisionApplication` is the HTTP-independent Phase 2B boundary
between an authenticated Koha staff context and
`RequestDecisionService::decide_request`. It does not expose a route, render a
response, execute SQL, own a transaction, or create a loan.

## Authentication and authorization

The application first calls `StaffDecisionAuthorization`. That service reads
only `$controller->stash('koha.user')`, obtains the trusted Koha patron
`borrowernumber`, and validates it as a complete positive decimal integer.
Caller-supplied bodies, parameters, headers, actor IDs, patron IDs, and portal
configuration cannot replace this identity.

The selected supported Koha permission is:

```text
circulate => circulate_remaining_permissions
```

This is the existing permission protecting the plugin staff tool and its
Digital Circulation GET routes, and it is the narrowest supported circulation
permission already established by the plugin. Authentication without this
permission is insufficient. The production checker resolves the authenticated
Koha patron's `userid` and calls `C4::Auth::haspermission`.

`PortalServiceAuthorization` is never used to authorize a staff decision. Its
canonical configuration loader and parser are reused only to identify the
configured portal service-account IDs. A configured service actor is denied
staff decisions even when Koha independently grants
`circulate_remaining_permissions`; the external result remains
`STAFF_NOT_AUTHORIZED`. Portal allowlist membership never grants staff
authority, and ordinary staff do not need to appear in that allowlist.

## Orchestration

The order is fixed:

1. Confirm `koha.user` exists.
2. extract and validate its borrowernumber;
3. fail closed if plugin configuration cannot be loaded or parsed;
4. reject a configured portal service-account ID;
5. verify `circulate_remaining_permissions`;
6. validate the decision command using
   `RequestDecisionService::validate_command`;
7. invoke `RequestDecisionService::decide_request` with the trusted actor;
8. validate, allowlist, and normalize the dependency result.

Authorization therefore completes before request existence, status, version,
patron, or biblio can be queried. Failed authorization never invokes the
decision service.

The internal API is:

```perl
my $result = $application->decide_request(
    controller           => $controller,
    request_id           => 2,
    expected_row_version => 1,
    decision             => 'APPROVE', # or REJECT
    reason               => undef,
    correlation_id       => $uuid,
);
```

The application accepts no subject patron identifier. The actor is the
authenticated librarian; the request subject remains the patron loaded by the
persistence service. Approval keeps the optional/blank-reason behavior.
Rejection still requires a nonblank safe plain-text reason with the persistence
service's 4,096-character limit.

## Result and error boundary

Valid `APPROVED` and `REJECTED` results retain the persistence service's safe
contract. Outcome, status transition, request ID, row versions, correlation ID,
request actor, and safe request fields must agree with the authorized command.
Extra request fields are discarded. A malformed success or unknown dependency
failure becomes `INTERNAL_ERROR`.

The application returns only these failure codes:

```text
AUTHENTICATION_REQUIRED
STAFF_NOT_AUTHORIZED
INVALID_INPUT
INVALID_DECISION
INVALID_REASON
REQUEST_NOT_FOUND
VERSION_CONFLICT
REQUEST_ALREADY_DECIDED
INVALID_STATE
DIGITAL_CIRCULATION_UNAVAILABLE
INTERNAL_ERROR
```

Exceptions from authorization, validation, persistence, or diagnostics are
caught. Diagnostics receive only fixed safe categories. No exception, Koha
user object, permission structure, SQL, DSN, path, cookie, OAuth value, or
credential is returned.

## Separation and remaining work

`RequestDecisionService` continues to own locking, optimistic concurrency,
request mutation, audit insertion, commit, rollback, and database failure
classification. This application adds none of those responsibilities and does
not create a loan or entitlement.

Phase 2A portal request creation remains available to a configured portal
service actor. Actor 53 must retain `circulate_remaining_permissions` for now:
the existing `/requests` route uses the same Koha permission gateway. Future
hardening may introduce a narrower supported Koha permission or redesign the
portal authentication gateway. On controlled Debian/Koha 26.05, verify the
real `koha.user` patron shape, `userid` permission lookup,
unauthenticated/ordinary/unauthorized/service-account denial, and authorized
staff invocation. No live Koha or MariaDB verification is claimed by the
Windows dependency-double tests.
