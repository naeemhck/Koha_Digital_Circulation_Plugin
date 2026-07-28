# Installation

1. Back up the Koha database and `/etc/koha`; record the installed plugin list, exact `Koha->VERSION`, `dpkg-query` package version, and `sudo koha-plack --status library`.
2. On Debian install build prerequisites (`perl`, `python3`, `unzip`) and build in the instance environment: `sudo koha-shell -c "cd /path/to/repository && ./build-kpz.sh" library`.
3. Run `./scripts/validate-package.sh dist/JunaidZaidiLibrary-DigitalCirculation-v0.3.1.kpz` and `unzip -l` to inspect every member. Confirm the package includes renewal, revocation, expiry, return, and Circulation-shortcut runtime.
4. In Koha staff Administration → Manage plugins, use the page-level **Upload plugin** action (not a per-plugin Actions item) to upload the KPZ and upgrade over the prior version. Do not uninstall first. Do not edit Koha core. Manual installation, when local policy permits it, uses Koha's supported plugin installer with the same KPZ, not copying individual files.
5. Run the plugin installation/upgrade action and confirm schema version remains **1** and plugin version is **0.3.1**. DDL is idempotent, serialized with a named database lock, and each migration is recorded. Upgrades refresh only the recorded `plugin_version` stamp; existing tables/data are never dropped.
6. Restart Plack using the instance's normal service procedure (`sudo koha-plack --restart library`) and reload Apache only if local operations require it. Verify both statuses.
7. As authorized circulation staff, verify `/api/v1/contrib/jzl-digital-circulation/health`, `/version`, and the Circulation → **Digital Circulation** shortcut. Verify an unauthenticated user, an ordinary patron, and staff without the circulation permission are denied.
8. Verify `EbookContent` and all other plugins still work and the existing portal request/approval/reader behavior is unchanged.

Prerequisites: Koha 26.05.x with plugins enabled, database backup, staff permission planning, and a maintenance window. Only 26.05.01.000 is presently tested.

Phase 5 source adds lifecycle settings but does not enable them. A future
authorized deployment must leave renewal, staff revocation, and automatic
expiry disabled until the allowlist, circulation permissions, renewal policy,
portal flags, scheduler interval, and rollback procedure have been verified.
See [PHASE5_AUTHORITATIVE_LOAN_LIFECYCLE.md](PHASE5_AUTHORITATIVE_LOAN_LIFECYCLE.md).
