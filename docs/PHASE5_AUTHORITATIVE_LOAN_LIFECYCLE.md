# Phase 5 authoritative loan lifecycle

Phase 5 completes the plugin-owned digital-loan lifecycle without changing
plugin version `0.3.0`, schema version `1`, the namespace, or native Koha
circulation. This implementation was prepared in an isolated worktree and was
not packaged, installed, enabled, or exercised against live business data.

## Operator and librarian model

- **Return**: the patron voluntarily ends access.
- **Renewal**: the patron requests more time, subject to library policy.
- **Revocation**: an authorized librarian immediately withdraws access and
  supplies a plain-text audit reason.
- **Expiry**: the system ends access when the authoritative due date passes.

The authoritative states are `ACTIVE`, `RETURNED`, `REVOKED`, and `EXPIRED`.
Only `ACTIVE` may transition to a terminal state. Renewal is an
`ACTIVE -> ACTIVE` mutation that extends the existing `due_at`, increments
`renewal_count`, and increments `row_version`. Terminal states never reopen.

## Configuration

All new features default to disabled. Plugin settings are
`renewals_enabled`, `staff_revocations_enabled`, and
`automatic_expiry_enabled`. Policy defaults are 14 renewal days, two maximum
renewals, and an expiry batch size of 100. Values are strictly validated; the
batch size is restricted to 1–500.

The patron portal must independently enable
`DIGITAL_CIRCULATION_PLUGIN_RENEWALS_ENABLED`. The scheduler runs only when
`DIGITAL_CIRCULATION_PLUGIN_EXPIRY_ENABLED` is true and the plugin reports
automatic expiry enabled. Its default interval is 300000 ms. A portal flag
cannot override a disabled plugin capability.

Staff revocation uses the established circulation permission and trusted Koha
actor. UI visibility is only a convenience; the server rechecks feature state,
authentication, permission, row version, and loan state.

## API and concurrency

- `POST /loans/{loan_id}/renew` is allowlisted portal-service-only.
- `POST /loans/{loan_id}/revoke` is authorized-staff-only.
- `POST /maintenance/expire-loans` is allowlisted portal-service-only.

Each write requires a correlation UUID. Renewal and revocation lock the
authoritative loan and use optimistic `row_version` guards. Expiry uses a
scoped database named lock, deterministic due-date/loan ordering, a bounded
batch, and row locks. The database UTC clock is authoritative and callers
cannot supply a clock.

Return, renewal, revocation, and expiry contend on the same authoritative
record. Only one operation can use a given row version. A terminal winner
prevents all later transitions; a renewal winner requires any following
terminal action to use its new row version. A past-due loan cannot renew.

Correlation replay is idempotent. A successful retry returns the canonical
result without changing dates, counters, versions, reasons, or events again.
The loan mutation and its `LOAN_RENEWED`, `LOAN_REVOKED`, or `LOAN_EXPIRED`
event share one transaction, so event failure rolls back the mutation.
Events separate actor from subject, classify source, and contain only safe
lifecycle facts.

## Operations

The portal scheduler is disabled unless explicitly configured, prevents
same-process overlap, and stops with the server. The plugin lock protects
against multiple portal instances. Safe run diagnostics contain only state,
counts, and correlation identifiers.

Canonical list refresh reconciles renewal fields and `RETURNED`, `REVOKED`,
or `EXPIRED` state only for exact `KOHA_PLUGIN` mappings and only when
`rowVersion` is monotonic. Revocation and expiry invalidate ReaderSessions.
Reading progress and request/issue history are preserved. Fresh reader
entitlement remains fail-closed even before shadow reconciliation.

Deployment requires a separate authorized release unit. Before enabling,
validate on Koha 26.05, configure the portal-service allowlist, confirm staff
permissions, choose renewal/batch policy, enable the plugin feature first,
then the corresponding portal flag, and monitor sanitized health/job output.
Rollback is configuration-first: disable portal scheduling/renewal and plugin
capabilities. Existing terminal data and audit history must not be rewritten.

Native `AddIssue`, `AddReturn`, physical checkout, hold, fine, and `issues`
table writes are outside this lifecycle. Digital renewal never renews a native
checkout, and digital revocation/expiry never checks in a physical item.
