# Installation

1. Back up the Koha database and `/etc/koha`; record the installed plugin list, exact `Koha->VERSION`, `dpkg-query` package version, and `sudo koha-plack --status library`.
2. On Debian install build prerequisites (`perl`, `python3`, `unzip`) and build in the instance environment: `sudo koha-shell -c "cd /path/to/repository && ./build-kpz.sh" library`.
3. Run `./scripts/validate-package.sh dist/JunaidZaidiLibrary-DigitalCirculation-v0.2.1.kpz` and `unzip -l` to inspect every member. Confirm the package includes the Circulation shortcut staff asset and does **not** include an authoritative return endpoint.
4. In Koha staff Administration → Manage plugins, upload the KPZ and install or upgrade it over the prior version. Do not uninstall first. Do not edit Koha core. Manual installation, when local policy permits it, uses Koha's supported plugin installer with the same KPZ, not copying individual files.
5. Run the plugin installation/upgrade action and confirm schema version remains **1** and plugin version is **0.2.1**. DDL is idempotent, serialized with a named database lock, and each migration is recorded. Patch upgrades only refresh the recorded `plugin_version` stamp; existing tables/data are never dropped.
6. Restart Plack using the instance's normal service procedure (`sudo koha-plack --restart library`) and reload Apache only if local operations require it. Verify both statuses.
7. As authorized circulation staff, verify `/api/v1/contrib/jzl-digital-circulation/health`, `/version`, and the Circulation → **Digital Circulation** shortcut (opens the plugin staff tool). Verify an unauthenticated user, an ordinary patron, and staff without the circulation permission are denied.
8. Verify `EbookContent` and all other plugins still work and the existing portal request/approval/reader behavior is unchanged. Digital circulation remains separate from native Koha physical `issues`.

Prerequisites: Koha 26.05.x with plugins enabled, database backup, staff permission planning, and a maintenance window. Only 26.05.01.000 is presently tested.
