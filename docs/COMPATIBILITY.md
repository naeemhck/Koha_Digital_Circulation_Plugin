# Compatibility findings

Inspected live on 2026-07-21: Koha 26.05.01.000, Debian package 26.05.01-1, MariaDB 10.11.18, database charset/collation `utf8mb4`/`utf8mb4_general_ci`. Plugin tables use the installed plugin convention `InnoDB utf8mb4_unicode_ci`. `Koha::Plugins::Base`, `Koha::Plugins`, `Koha::Plugins::Handler`, and `Koha::REST::Plugin::PluginRoutes` confirm metadata as a Perl hash, minimum version `26.05.00.000`, `api_namespace` plus `api_routes`, and `/api/v1/contrib/<namespace>` injection with collision rejection. Official `intranet_head` and page-aware `intranet_js` hooks are present.

Installed plugin inspected: `Koha::Plugin::Com::Ecombranding::EbookContent` v0.1.2, namespace `ebookcontent`, route prefix `/api/v1/contrib/ebookcontent`, qualified mapping table, configuration keys `api_enabled`, `allowed_upload_category`, `service_account_ids`, and `max_range_bytes`. No namespace, route, explicit table, template, asset, label, or configuration-key collision was found. It was not modified.

Minimum intended release is 26.05.00.000. Only 26.05.01.000 is tested. Later 26.05 maintenance releases require regression testing; 26.11+ is unsupported until tested.

Digital Circulation plugin version covered by this compatibility claim is
**0.3.1** (schema 1), with EbookContent **0.1.2** as the protected-content
dependency. See [TEAMMATE_HANDOFF.md](TEAMMATE_HANDOFF.md) for continuation
guidance. Release **0.3.1** combines the Circulation staff shortcut for the Koha
26.05 `.circulation-actions` button list with the Phase 4B authoritative
patron-return endpoint. It does not change schema version 1 or native Koha
circulation.

## Circulation staff shortcut

The Circulation home shortcut is injected only through the plugin’s
`intranet_js` / `intranet_head` hooks. No Koha core template modification is
required. Existing Koha installations receive the shortcut only after an
updated plugin KPZ is installed or upgraded. The shortcut opens the plugin
staff tool; digital circulation remains separate from native physical
`issues` checkout. Shortcut visibility is not a substitute for server-side
authorization on the tool.

Phase 5 retains the same compatibility floor, plugin version, and schema. It
uses existing plugin loan/event columns and MariaDB transaction, row-lock,
UTC timestamp, and named-lock behavior. Runtime integration still requires the
complete controlled Koha-host test gate before release.
