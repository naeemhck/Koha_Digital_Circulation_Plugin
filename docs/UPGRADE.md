# Upgrade

Back up first, preserve the installed KPZ, record the current plugin/schema versions, inspect the replacement KPZ, and use Koha's supported plugin upgrade workflow. Version **0.3.0** retains schema version **1**, requires no new migration, and upgrades the corrected **0.2.3** combined release.

The schema-1 DDL remains unchanged and idempotent. After the existing migration check, the transactional schema-state upsert updates the canonical schema-1 row's `plugin_version` from **0.2.3** to **0.3.0**. Strict verification requires exactly one canonical row with schema version 1 and the current plugin version before commit. A failed stamp write or invalid schema state rolls back the metadata update. This is release-metadata maintenance, not schema migration 2; it does not rewrite requests, loans, renewals, events, lifecycle values, or native Koha circulation.

Version 0.3.0 adds service-authorized patron renewal, authorized staff revocation, bounded automatic authoritative expiry, row-version concurrency handling, correlation idempotency, transactional audit events, ReaderSession invalidation support, portal-shadow reconciliation, diagnostics, and configuration. It preserves patron return and the Circulation-home staff shortcut. Renewal, staff revocation, and automatic expiry are disabled by default.

This release excludes reporting and native physical circulation. The v0.3.0 KPZ produced by the release checkpoint is not installed or deployed, and renewal, revocation, and expiry are not verified through live mutation in this unit. Verify the recorded KPZ SHA-256 before any separately authorized installation.

After a future authorized upgrade, restart or reload only services required by the supported Koha workflow; check Plack/Apache, health/version, plugin configuration, permissions, the staff shortcut, existing plugins, and portal integration. Regression-test every later Koha 26.05 maintenance release; do not extend this compatibility claim to Koha 26.11 or later.
