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
uses idempotent schema creation and version recording; uninstall preserves
institutional plugin tables.

This release implements no renewal, revocation, or automatic expiry. Version
0.2.3 has not been deployed, the combined KPZ has not been installed, and no
live patron return has been performed as part of release preparation.
