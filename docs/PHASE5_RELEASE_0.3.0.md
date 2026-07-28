# Digital Circulation 0.3.0

Version **0.3.0** completes authoritative digital-loan lifecycle management while retaining schema **1**, minimum Koha **26.05.00.000**, the existing namespace, patron return, and the staff Circulation shortcut.

The release includes patron renewal, librarian revocation, bounded automatic expiry, row-version concurrency control, correlation-based idempotency, one transactional audit event per mutation, ReaderSession invalidation, authoritative portal-shadow reconciliation, diagnostics, configuration, simulations, tests, and validators.

Renewal, staff revocation, and automatic expiry remain disabled by default. Reporting, native physical circulation, deployment, and live Phase 5 mutation verification are excluded from this release checkpoint.
