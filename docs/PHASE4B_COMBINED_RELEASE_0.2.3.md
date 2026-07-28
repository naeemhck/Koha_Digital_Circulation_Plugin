# Digital Circulation 0.2.3 combined release

Version **0.2.3** combines two already-reviewed feature sets:

- the Koha 26.05 Circulation-home **Digital Circulation** staff shortcut; and
- the Phase 4B authoritative `POST /loans/{loan_id}/return` endpoint.

The shortcut is navigation only. It uses the stable
`jzl-digital-circulation-shortcut` ID, is restricted to
`circulation-home.pl`, inserts at most once, uses a host-independent plugin
tool URL, and relies on the plugin tool's server-side staff authorization.

The return endpoint requires an allowlisted portal service actor, exact loan,
request, patron, biblio, portal-request, and expected-row-version correlation,
and a transactional `ACTIVE` to `RETURNED` transition. It records one
authoritative UTC return timestamp, one row-version increment, and one
`LOAN_RETURNED` event. Idempotent replay, terminal-state conflicts, and
concurrent-return protection remain intact. Native Koha circulation is not
modified.

Schema version remains **1**, the minimum Koha version remains
**26.05.00.000**, and no migration is added. Upgrading from the live
shortcut-only 0.2.2 release preserves plugin requests, loans, renewals,
events, schema audit data, and native Koha circulation records. The installer
uses idempotent schema creation followed by a transactional schema-state
upsert. The upsert advances the existing schema-1 `plugin_version` stamp from
0.2.2 to 0.2.3 before strict verification and commit. Repeated 0.2.3 upgrade
is idempotent; invalid schema state or a failed version write rolls back and
fails closed. This metadata maintenance is not a new schema migration.
Uninstall preserves institutional plugin tables.

The earlier undeployed artifact with SHA-256
`2130ce2c6385c2a506ee9899ad6e958c8266c896ffda1fb462215c896f0eb8ba`
contains the stale-version-stamp defect. It is superseded and must not be
installed. The corrected package remains undeployed and receives a new hash
after rebuilding from the correction commit.

This release implements no renewal, revocation, or automatic expiry. Version
0.2.3 has not been deployed, the combined KPZ has not been installed, and no
live patron return has been performed as part of release preparation.
