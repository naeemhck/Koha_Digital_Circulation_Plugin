# Testing

On the Koha 26.05.01.000 host run the tests and build inside `koha-shell`, for example `sudo koha-shell -c "cd /path/to/repository && prove -I. -v t && ./build-kpz.sh" library`, then run `./scripts/validate-package.sh dist/*.kpz`. For database integration, install into a disposable test instance, select dedicated test patron/biblio records, and run `KOHA_INSTANCE=library-test KOHA_JZL_FIXTURES=1 koha-shell library-test -c 'perl scripts/load-test-fixtures.pl --patron ID --biblio ID'`. Cleanup adds `--cleanup` and affects only `TEST-JZL-*` records.

Verify clean/repeated install, migration rows/indexes/checks, partial-failure rerun, preserved uninstall, invalid patron/biblio service validation, uniqueness guards, state transitions, API authentication/permissions/filter/pagination/not-found/safe errors, staff tabs/empty/error/denial/read-only states, navigation, keyboard focus, and absence of write controls. Fixture code refuses to run unless both explicit test guards are present and never runs automatically.

On Windows, run `powershell -ExecutionPolicy Bypass -File .\scripts\Validate-Source.ps1`, `prove -I. -v t` when a compatible Perl/Koha library environment is available, and `powershell -ExecutionPolicy Bypass -File .\build-kpz.ps1`. The PowerShell validator checks SQL balance, the deployed events-table regression, pending-only uniqueness, migration verification, runtime paths, archive membership, and forbidden content. MariaDB execution, Koha template resolution, route loading, and staff-session authorization still require the controlled Debian test deployment; Windows static/package checks do not establish live installation success.

## Validation matrix

Plain Strawberry Perl on Windows does not provide Koha runtime modules such as
`Koha::Plugins::Base` and `C4::Context`. Do not install or broadly stub Koha
server modules merely to make the complete suite run on Windows. The required
Windows gate is the portable test subset plus both source validators,
JavaScript syntax, OpenAPI parsing, and `git diff --check`.

Run the portable Perl subset from PowerShell:

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

The eight excluded tests are not skipped from release validation. Run the
complete suite, including those tests, inside the controlled Koha instance:

```sh
sudo koha-shell -c "cd /path/to/repository && prove -I. -v t" library
```

Release packaging requires both gates. Helpers under `t/lib` are test-only,
are not listed in `MANIFEST`, and must not be included in a KPZ. The controlled
Koha-host gate uses the real Koha modules and remains authoritative for runtime
integration.

For Phase 5 also run `scripts/simulate_phase5_lifecycle.py`. It covers renewal
replay/version contention, every terminal race pairing, past-due behavior,
bounded repeated expiry, named/row-lock source contracts, event rollback,
progress preservation, route/event inventory, database UTC, and native
circulation isolation. `t/lifecycle_contract.t` is part of the complete Perl
gate; a simulation pass is not a claim that Perl tests passed.
