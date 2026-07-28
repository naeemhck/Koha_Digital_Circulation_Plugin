# Upgrade

Back up first, preserve the installed KPZ, record the current plugin/schema versions, inspect the replacement KPZ, and use Koha's supported plugin upgrade workflow. Version **0.3.1** retains schema version **1**, requires no new migration, and upgrades the Phase 5 **0.3.0** release.

The schema-1 DDL remains unchanged and idempotent. After the existing migration check, the transactional schema-state upsert updates the canonical schema-1 row's `plugin_version` from **0.3.0** to **0.3.1**. Strict verification requires exactly one canonical row with schema version 1 and the current plugin version before commit. A failed stamp write or invalid schema state rolls back the metadata update. This is release-metadata maintenance, not schema migration 2; it does not rewrite requests, loans, renewals, events, lifecycle values, or native Koha circulation.

Version 0.3.1 preserves the authenticated actor context in renewal and staff-revocation lifecycle commands. It makes no HTTP-contract or schema change and requires no portal source change. Phase 5 renewal, revocation, expiry, return, row-version concurrency, correlation idempotency, and native-circulation isolation remain unchanged.

This release excludes reporting and native physical circulation. Verify the recorded v0.3.1 KPZ SHA-256 before supported upgrade.

After a future authorized upgrade, restart or reload only services required by the supported Koha workflow; check Plack/Apache, health/version, plugin configuration, permissions, the staff shortcut, existing plugins, and portal integration. Regression-test every later Koha 26.05 maintenance release; do not extend this compatibility claim to Koha 26.11 or later.
