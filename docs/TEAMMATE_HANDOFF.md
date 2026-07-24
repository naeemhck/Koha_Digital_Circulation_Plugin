# Teammate Handoff — Digital Circulation Plugin

This document is the continuation guide for another developer cloning the
repository on a new computer. Prefer this file for orientation; detailed phase
docs remain under `docs/`.

## Repository

| Item | Value |
|------|-------|
| GitHub URL | https://github.com/naeemhck/Koha_Digital_Circulation_Plugin |
| Active branch | `feature/phase2c-loan-issuance-foundation` |
| Checkpoint base commit | `e19a669` (Phase 2C–3A source) |
| Plugin Perl package | `Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation` |
| API namespace | `jzl-digital-circulation` |
| Plugin version | `0.2.0` |
| Minimum Koha version | `26.05.00.000` |
| Tested Koha version | `26.05.01.000` |
| Schema version | `1` |
| Draft PR | https://github.com/naeemhck/Koha_Digital_Circulation_Plugin/pull/1 |

KPZ release artifacts under `dist/` are **not** source-controlled. Download RC7
from the GitHub prerelease (see below).

## Environment

Verified controlled host profile (see also `docs/COMPATIBILITY.md`):

- Debian-hosted Koha `26.05.01.000` (`koha-common` `26.05.01-1`)
- MariaDB `10.11.18` (`utf8mb4`)
- EbookContent dependency: `Koha::Plugin::Com::Ecombranding::EbookContent` **v0.1.2**
- Perl environment: Koha instance shell (`koha-shell`), not a bare laptop Perl install

Configuration key names used by this plugin (values never belong in Git):

- `portal_service_account_ids`
- `default_loan_duration_days`
- related plugin configuration fields documented in `docs/PHASE2A_CONFIGURATION.md`

Portal OAuth client credentials (`KOHA_CLIENT_ID`, `KOHA_CLIENT_SECRET`, tokens)
live only in the **portal** environment, never in this plugin repository.

## Architecture

- This plugin is the **authoritative** store for protected eBook digital
  requests and digital loans.
- The student **portal** (separate repo) authenticates patrons, stores local
  shadows, and calls Koha with a backend service OAuth actor.
- **EbookContent** remains the owner of protected PDF bytes and mapping
  eligibility; this plugin never streams PDFs.
- Actor **51** represents staff circulation boundaries for decision/issuance UI
  and staff REST actions (not portal-allowlisted).
- Actor **53** is the controlled portal-service allowlisted borrowernumber for
  portal request creation and portal loan-read.
- Native Koha physical issues/checkouts remain untouched; digital loans live
  only in plugin tables.

## Database

Schema version **1**. Idempotent install/upgrade records migration
`001_initial_schema`. Normal uninstall **preserves** plugin tables.

| Table | Role |
|-------|------|
| `plugin_jzl_ebook_requests` | Authoritative digital requests |
| `plugin_jzl_ebook_loans` | Authoritative digital loans |
| `plugin_jzl_ebook_renewals` | Renewal history (unused by current workflows) |
| `plugin_jzl_ebook_events` | Append-only audit events |
| `plugin_jzl_ebook_schema_versions` | Migration ledger |

Do not create or edit rows with ad-hoc SQL in shared/test data that must remain
auditable.

## Implemented phases

| Phase | Status |
|-------|--------|
| Phase 1 foundation | Complete (read/health/version + schema) |
| Phase 2A request creation | Complete (`POST /requests`) |
| Phase 2B staff decisions | Complete (`POST /requests/{id}/decision` + UI) |
| Phase 2C loan issuance | Complete (`POST /requests/{id}/issue` + UI + duration policy) |
| Phase 3A portal patron-loan read | Complete (`GET /patrons/{patron_id}/loans`) |

## REST routes

Base prefix:

`/api/v1/contrib/jzl-digital-circulation`

| Method | Path | Actor requirement | Notes |
|--------|------|-------------------|-------|
| `POST` | `/requests` | Allowlisted portal service | Creates pending request; idempotency + correlation headers |
| `POST` | `/requests/{request_id}/decision` | Staff circulate permission | Approve/reject PENDING requests |
| `POST` | `/requests/{request_id}/issue` | Staff circulate permission | Issues ACTIVE loan from APPROVED request |
| `GET` | `/patrons/{patron_id}/loans` | Allowlisted portal service **only** | Read-only; staff actor 51 denied |

Also present for ops/staff reads: `/health`, `/version`, and staff list routes
defined in `openapi.json`.

Shared contract rules:

- `X-Correlation-ID` must be a canonical UUID where required; the server does
  not invent a replacement.
- Patron-loan pagination: default `page=1`, `per_page=20`, max `per_page=100`.
- Safe response fields only (no OAuth secrets, PDF paths, borrower PII dumps).
- Patron-loan read never writes loans, renewals, events, or native issues.

Detailed contracts: `docs/PORTAL_REQUEST_HTTP_API.md`,
`docs/STAFF_REQUEST_DECISION_HTTP_API.md`,
`docs/PHASE2C_STAFF_LOAN_ISSUANCE_HTTP_API.md`,
`docs/PHASE3A_PORTAL_LOAN_READ_API.md`.

## Current validation

Previously verified on the controlled Koha host:

- **35** test files
- **2,884** assertions
- **0** failures
- RC7 **live verification passed**

Windows/local gate (portable subset + validators) must still be run after every
documentation or packaging change; see `docs/TESTING.md`.

## RC7

| Item | Value |
|------|-------|
| Tag | `v0.2.0-rc7` |
| Release URL | https://github.com/naeemhck/Koha_Digital_Circulation_Plugin/releases/tag/v0.2.0-rc7 |
| Filename | `JunaidZaidiLibrary-DigitalCirculation-v0.2.0-rc7.kpz` |
| Size | 66,120 bytes |
| SHA-256 | `68e7c33f65d397c840e8de21e38bb6bc3ab9cd253af7667e3ed953aec4b4d92e` |
| Archive members | 34 |
| Prerelease | yes |

Do not commit KPZ binaries. Rebuild with `./build-kpz.sh` (Debian/`koha-shell`)
or `.\build-kpz.ps1` (Windows packaging helper) when a new candidate is required.

## Current controlled live state

Safe identifiers only (no patron names, cards, passwords, or tokens):

- Digital Circulation plugin `0.2.0` enabled; EbookContent `0.1.2` enabled
- `portal_service_account_ids` includes **53**
- `default_loan_duration_days` = **14**
- Request **7**: `APPROVED`
- Loan **1**: `ACTIVE`
- Patron ID **50**, biblio ID **1**
- Portal request correlation UUID:
  `3e5e9b3c-6e6d-4219-ab4c-71a316c663b1`
- Renewals: **0**
- Native Koha issues: **0**
- Events: one `LOAN_CREATED`

## Local setup

Exact commands derived from `README.md`, `docs/INSTALLATION.md`,
`docs/TESTING.md`, `build-kpz.sh`, and `build-kpz.ps1`.

### Clone and checkout

```powershell
git clone https://github.com/naeemhck/Koha_Digital_Circulation_Plugin.git
cd Koha_Digital_Circulation_Plugin
git checkout feature/phase2c-loan-issuance-foundation
git log -1 --oneline
```

### Inspect plugin metadata

```powershell
Select-String -Path .\Koha\Plugin\Com\JunaidZaidiLibrary\DigitalCirculation.pm -Pattern "VERSION|SCHEMA_VERSION|minimum_version|api_namespace"
Get-Content .\MANIFEST | Select-Object -First 20
```

### Windows validation gate

```powershell
$kohaHostOnly = @(
    'migration_retry.t'
    'plugin_configuration.t'
    'portal_request_application.t'
    'request_creation_service.t'
    'request_creation_transaction.t'
    'request_decision_service.t'
    'request_decision_transaction.t'
    'staff_request_decision_application.t'
)
$portableTests = Get-ChildItem .\t -Filter *.t |
    Where-Object Name -NotIn $kohaHostOnly |
    ForEach-Object FullName
prove -I. -v $portableTests
py -3.13 .\scripts\validate_source.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Validate-Source.ps1
node --check .\Koha\Plugin\Com\JunaidZaidiLibrary\DigitalCirculation\static\js\jzl-digital-circulation.js
git diff --check
```

### Build a KPZ

Debian / Koha instance shell (preferred for installable packages):

```sh
sudo koha-shell -c "cd /path/to/repository && ./build-kpz.sh" library
./scripts/validate-package.sh dist/JunaidZaidiLibrary-DigitalCirculation-v0.2.0.kpz
unzip -l dist/JunaidZaidiLibrary-DigitalCirculation-v0.2.0.kpz
```

Windows packaging helper (validates source/archive; live Koha install still
requires Debian):

```powershell
powershell -ExecutionPolicy Bypass -File .\build-kpz.ps1
```

Use `-ReleaseSuffix rcN` only when intentionally creating a named candidate and
the output path does not already exist.

### Install into a Koha test instance

Follow `docs/INSTALLATION.md`:

1. Back up Koha DB and `/etc/koha`.
2. Upload/install the KPZ through Administration → Manage plugins.
3. Confirm schema version **1**.
4. Restart Plack (`sudo koha-plack --restart library`) as local ops require.
5. Verify `/health`, `/version`, staff tool, and that EbookContent still works.

### Full Koha-host test suite

```sh
sudo koha-shell -c "cd /path/to/repository && prove -I. -v t" library
```

## Important safety rules

- Do not edit production plugin tables manually.
- Do not create requests or loans with SQL.
- Do not expose service OAuth credentials in docs, logs, or Git.
- Do not mix native Koha physical issues with digital loans.
- Do not enable protected-reader entitlement until that phase is implemented.
- Preserve actor separation (staff vs portal-service allowlist).
- Preserve correlation IDs and all audit events.
- Keep `dist/*.kpz` out of Git; use GitHub Releases for artifacts.

## Remaining work

- Portal local live synchronization verification (portal repo)
- Protected-reader entitlement
- Return workflow
- Renewal workflow
- Revocation workflow
- Expiry processing
- Final production deployment documentation

## Exact next step

The portal database currently lacks a local `EbookAccessRequest` shadow for the
historical live loan correlation UUID. Do **not** insert that row with SQL.

Instead:

1. In the portal repository branch
   `feature/koha-backed-request-orchestration`, use the supported request
   workflow to create a **fresh** protected-eBook request for the controlled
   test patron/biblio.
2. In Koha staff Digital Circulation UI, approve and **Issue Loan**.
3. Enable portal loan sync (`DIGITAL_CIRCULATION_PLUGIN_LOANS_ENABLED`) only in
   the controlled portal environment and verify My Loans against the new loan.
4. Keep KOHA_PLUGIN shadows unreadable until a later entitlement phase.

## Repository relationship

Portal repository:

https://github.com/naeemhck/Ebook_issuing

Required portal branch:

`feature/koha-backed-request-orchestration`

Portal draft PR:

https://github.com/naeemhck/Ebook_issuing/pull/1

Related local checkpoint:

`docs/PROJECT_CHECKPOINT_PHASE3A.md`
