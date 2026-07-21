# Junaid Zaidi Library Digital eBook Circulation

Version 0.1.0, schema 1, tested against Koha 26.05.01.000 (`koha-common` 26.05.01-1, MariaDB 10.11.18).

Phase 1 is a read-only foundation. The existing student portal remains operational and authoritative; this plugin makes no production access decision and exposes no mutation route or staff action. Koha becomes authoritative only after a controlled Phase 2 cutover. Standard holds, issues/checkouts, item availability, physical limits, fines, pickup notices, and overdue notices are intentionally not used. The model supports unlimited simultaneous readers of one biblio.

Build on Debian with `./build-kpz.sh`, inspect with `unzip -l dist/JunaidZaidiLibrary-DigitalCirculation-v0.1.0.kpz`, then follow `docs/INSTALLATION.md`. Normal uninstall preserves all plugin tables.

The read API is `/api/v1/contrib/jzl-digital-circulation`; access uses Koha authentication plus the narrow existing `circulate_remaining_permissions` permission because Koha 26.05 has no clean plugin-owned permission registration facility.
