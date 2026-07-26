# Junaid Zaidi Library Digital eBook Circulation

Version **0.2.2**, schema **1**, tested against Koha **26.05.01.000**
(`koha-common` 26.05.01-1, MariaDB 10.11.18).

Koha-authoritative plugin for protected institutional eBook requests, staff
approval/rejection, digital-loan issuance, and portal-service loan reads.
Native Koha physical issues remain untouched. Protected PDF bytes remain in
EbookContent **0.1.2**. Version **0.2.2** adds a Circulation-home
**Digital Circulation** staff shortcut for the Koha 26.05 button layout and
includes the Phase 4B authoritative patron-return endpoint. It is safe to
upgrade over **0.2.0** / **0.2.1** without changing schema version 1.

## Developer Handoff

For cloning, architecture, REST contracts, RC7, safety rules, and the exact
next implementation step, start here:

**[docs/TEAMMATE_HANDOFF.md](docs/TEAMMATE_HANDOFF.md)**

Also see:

- [docs/PROJECT_CHECKPOINT_PHASE3A.md](docs/PROJECT_CHECKPOINT_PHASE3A.md)
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)
- [docs/INSTALLATION.md](docs/INSTALLATION.md)
- [docs/TESTING.md](docs/TESTING.md)

## Branch and status

- Feature branch: `feature/phase2c-loan-issuance-foundation`
- Completed through Phase 3A portal loan-read API
- RC7 prerelease:
  https://github.com/naeemhck/Koha_Digital_Circulation_Plugin/releases/tag/v0.2.0-rc7

## Build and install

Build on Debian inside the instance environment with `./build-kpz.sh`, inspect
with `unzip -l dist/JunaidZaidiLibrary-DigitalCirculation-v0.2.2.kpz`, then
follow `docs/INSTALLATION.md`. On Windows, packaging validation uses
`.\build-kpz.ps1` and `.\scripts\Validate-Source.ps1`.

Normal uninstall preserves all plugin tables. KPZ files under `dist/` are
release artifacts and are not committed.

## API

Namespace path: `/api/v1/contrib/jzl-digital-circulation`.

Access uses Koha authentication plus the narrow existing
`circulate_remaining_permissions` staff permission for staff routes. Portal
service routes additionally require membership in
`portal_service_account_ids`.
