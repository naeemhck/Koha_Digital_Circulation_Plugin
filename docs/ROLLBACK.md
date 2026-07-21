# Rollback

Disable or uninstall the plugin using Koha's plugin manager, remove any local operational shortcut if separately created, restart Plack if required, and confirm Apache/Plack, existing plugins, and the current portal approval/reader workflow. `uninstall` intentionally returns without dropping any table, so requests, loans, renewals, events, and schema history remain recoverable. The official navigation hook disappears with the disabled runtime. No portal or Koha core configuration is changed by this package.

## Irreversible data removal

This is separate from normal uninstall. Take and verify a database backup, obtain institutional records-retention approval, disable the plugin, confirm the exact `plugin_jzl_ebook_*` targets, then run `scripts/destructive-cleanup.sql` from an authenticated administrative database session. It drops only the five named tables in dependency order. This cannot be triggered by HTTP and cannot be undone without the backup.
