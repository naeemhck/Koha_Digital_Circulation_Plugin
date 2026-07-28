param([string]$Kpz)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bundle = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation'
$main = Join-Path $root 'Koha\Plugin\Com\JunaidZaidiLibrary\DigitalCirculation.pm'
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$phase2Boundary = 'Authoritative digital circulation'
$phase2PackedBoundary = 'Phase 2B ' + [char]0x2014 + ' request decisions'

function Read-Utf8TextFile([string]$Path) {
    return [IO.File]::ReadAllText($Path, $script:utf8Strict)
}

$source = Read-Utf8TextFile $main
$manifest = @(
    (Read-Utf8TextFile (Join-Path $root 'MANIFEST')) -split '\r?\n' |
        Where-Object { $_ }
)

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Output "ok - $Message"
}

function Read-ArchiveText($Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) { throw "Missing archive entry: $Name" }
    $reader = [IO.StreamReader]::new($entry.Open(), $script:utf8Strict, $true)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

Assert-Contract ($source.Contains("our `$VERSION             = '0.4.0';")) 'plugin version is 0.4.0'
Assert-Contract ($source.Contains('our $SCHEMA_VERSION      = 1;')) 'schema version remains 1'
Assert-Contract ($source.Contains("minimum_version => '26.05.00.000'")) 'minimum Koha version remains 26.05.00.000'

$pattern = 'CREATE TABLE IF NOT EXISTS `\$[rlnve]` \(.*?\) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci'
$statements = [regex]::Matches($source, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
Assert-Contract ($statements.Count -eq 5) 'exactly five CREATE TABLE statements'
for ($index = 0; $index -lt $statements.Count; $index++) {
    $sql = $statements[$index].Value
    $opens = ($sql.ToCharArray() | Where-Object { $_ -eq '(' }).Count
    $closes = ($sql.ToCharArray() | Where-Object { $_ -eq ')' }).Count
    Assert-Contract ($opens -eq $closes) "CREATE TABLE $($index + 1) parentheses balanced"
    Assert-Contract ($sql.EndsWith('ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci')) "CREATE TABLE $($index + 1) engine/charset declaration"
}
Assert-Contract (-not ($statements[3].Value -match 'ON DELETE RESTRICT\s*\)\s*\) ENGINE')) 'events foreign key has no redundant closing parenthesis'
foreach ($name in @('requests','loans','renewals','events','schema_versions')) {
    Assert-Contract ($source.Contains("table('$name')")) "expected table mapping: $name"
}
$stampHelper = [regex]::Match($source, 'sub _stamp_schema_state \{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($stampHelper.Contains('INSERT INTO `$versions`') -and $stampHelper.Contains('ON DUPLICATE KEY UPDATE') -and ($stampHelper -match 'plugin_version\s*=\s*VALUES\(plugin_version\)')) 'schema state uses an explicit idempotent plugin-version upsert'
Assert-Contract (-not $source.Contains('INSERT IGNORE INTO `$v`')) 'stale INSERT IGNORE version-stamp path is absent'
Assert-Contract (([regex]::Matches($source, 'CREATE TABLE IF NOT EXISTS')).Count -eq 5) 'partial migration retry preserves existing tables'
$installFlow = [regex]::Match($source, 'sub install \{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($installFlow.Contains('$self->_migration_001($dbh);') -and $installFlow.Contains('$dbh->begin_work;') -and $installFlow.Contains('$self->_stamp_schema_state($dbh);') -and $installFlow.Contains('$self->_verify_schema($dbh);') -and $installFlow.Contains('$dbh->commit;') -and $installFlow.Contains('$dbh->rollback;')) 'install transactionally stamps and strictly verifies after schema migration'
Assert-Contract ($source.Contains('Schema state must contain exactly one canonical row') -and $source.Contains('Schema version 1 was not recorded')) 'install verifies one canonical schema-1/current-version state'
Assert-Contract (-not ($source -match '(?i)\bDROP\s+TABLE\b')) 'upgrade source never drops plugin tables'
Assert-Contract (Test-Path (Join-Path $root 't/plugin_upgrade_version_stamp.t')) 'focused prior-version upgrade test exists'
Assert-Contract (Test-Path (Join-Path $root 't/lib/PluginUpgradeFakes.pm')) 'focused upgrade database fake exists'
Assert-Contract (Test-Path (Join-Path $root 'scripts/simulate_upgrade_version_stamp.py')) 'isolated upgrade simulation exists'
Assert-Contract ($source.Contains('SELECT GET_LOCK(?, 30)') -and $source.Contains('lock_acquired == 1')) 'migration lock result is checked'
Assert-Contract ($source.Contains('SELECT RELEASE_LOCK(?)')) 'migration lock release is attempted'
Assert-Contract ($source.Contains('migration failed: ') -and $source.Contains('_safe_install_error')) 'safe detailed migration logging'

$requestGuard = [regex]::Match($source, 'pending_guard VARCHAR\(80\).*?STORED', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($requestGuard.Contains("status = 'PENDING'") -and $requestGuard.Contains('ELSE NULL')) 'request guard applies only to PENDING'
Assert-Contract ($source.Contains('UNIQUE KEY jzl_req_pending_uq (pending_guard)')) 'request pending guard is unique'
Assert-Contract (-not ($source -match 'UNIQUE[^\r\n]*patron_id[^\r\n]*biblio_id[^\r\n]*status')) 'no historical-status uniqueness constraint'
$renewalGuard = [regex]::Match($source, 'pending_guard BIGINT UNSIGNED.*?STORED', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($renewalGuard.Contains("status = 'PENDING'") -and $renewalGuard.Contains('ELSE NULL')) 'renewal guard applies only to PENDING'

$toolPath = "$bundle/tool.tt"
$configurePath = "$bundle/configure.tt"
Assert-Contract (Test-Path (Join-Path $root $toolPath)) 'tool.tt exists at bundle root'
Assert-Contract ($manifest -contains $toolPath) 'tool.tt bundle-root path is in MANIFEST'
Assert-Contract (Test-Path (Join-Path $root $configurePath)) 'configure.tt exists at bundle root'
Assert-Contract ($manifest -contains $configurePath) 'configure.tt bundle-root path is in MANIFEST'
Assert-Contract (-not (Test-Path (Join-Path $root "$bundle/templates/tool.tt"))) 'no duplicate guessed template path'
Assert-Contract (-not (Test-Path (Join-Path $root "$bundle/templates/configure.tt"))) 'no obsolete configuration template path'
foreach ($runtime in @("$bundle.pm", "$bundle/openapi.json", "$bundle/Controller/Requests.pm", "$bundle/Controller/Patrons.pm", "$bundle/Controller/Loans.pm", "$bundle/Service/EbookContentAdapter.pm", "$bundle/Service/EbookContentEligibility.pm", "$bundle/Service/PortalServiceAuthorization.pm", "$bundle/Service/PortalRequestApplication.pm", "$bundle/Service/PortalLoanReadApplication.pm", "$bundle/Service/PortalLoanReturnApplication.pm", "$bundle/Repository/RequestRepository.pm", "$bundle/Repository/EventRepository.pm", "$bundle/Repository/LoanRepository.pm", "$bundle/Service/RequestDecisionService.pm", "$bundle/Service/RequestService.pm", "$bundle/Service/LoanIssuanceService.pm", "$bundle/Service/LoanReturnService.pm", "$bundle/Service/ConfiguredLoanPeriodPolicy.pm", "$bundle/Service/StaffDecisionAuthorization.pm", "$bundle/Service/StaffRequestDecisionApplication.pm", "$bundle/Service/StaffLoanIssuanceApplication.pm", "$bundle/static/css/jzl-digital-circulation.css", "$bundle/static/js/jzl-digital-circulation.js")) {
    Assert-Contract (($manifest -contains $runtime) -and (Test-Path (Join-Path $root $runtime))) "runtime file packaged: $runtime"
}
$tool = Read-Utf8TextFile (Join-Path $root $toolPath)
$staffJs = Read-Utf8TextFile (Join-Path $root "$bundle/static/js/jzl-digital-circulation.js")
$staffUi = $tool + "`n" + $staffJs
Assert-Contract ($tool.Contains($phase2Boundary) -and $tool.Contains('never create, renew, or return a native Koha checkout')) 'staff tool states the authoritative/native circulation boundary'
Assert-Contract ($staffJs.Contains("approve.textContent = 'Approve'") -and $staffJs.Contains("reject.textContent = 'Reject'") -and $staffJs.Contains("request.status === 'PENDING'")) 'staff tool exposes Approve and Reject only for pending requests'
Assert-Contract ($staffJs.Contains("issue.textContent = 'Issue Loan'") -and $staffJs.Contains('canIssueRequest(request)') -and $staffJs.Contains("loanPresence(request) === 'absent'") -and $staffJs.Contains("request.status === 'APPROVED'")) 'Issue Loan appears only for APPROVED requests without a loan'
Assert-Contract ($staffJs.Contains("DECISION_PATH = '/requests/'") -and $staffJs.Contains("'/decision'") -and $staffJs.Contains("ISSUE_PATH = '/requests/'") -and $staffJs.Contains("'/issue'") -and $staffJs.Contains("method: 'POST'") -and $staffJs.Contains("credentials: 'same-origin'")) 'staff decisions and issuance use only the same-origin verified REST endpoints'
Assert-Contract ($staffJs.Contains("'X-Correlation-ID': correlationId") -and $staffJs.Contains('expected_row_version: version') -and $staffJs.Contains('window.crypto.randomUUID()') -and $staffJs.Contains('window.crypto.getRandomValues(bytes)') -and $staffJs.Contains('submitIssuance')) 'staff writes use a fresh secure correlation UUID and dedicated issuance submit helper'
Assert-Contract (-not $staffJs.Contains('innerHTML') -and -not $staffJs.Contains('Authorization') -and -not $staffUi.Contains('portal_service_account_ids') -and -not $staffJs.Contains('grantAccess') -and -not $staffJs.Contains('activateReader')) 'staff UI contains no unsafe HTML, authorization header, portal allowlist, or reader access'
foreach ($control in @('Create','Delete','Return','Renew','Edit')) {
    Assert-Contract (-not ($tool -match ">\s*$control(?: Request)?\s*<") -and -not ($staffJs -match "\.textContent\s*=\s*['""]$control(?: Request)?['""]")) "staff tool has no $control write control"
}
$pluginMain = Read-Utf8TextFile (Join-Path $root "$bundle.pm")
Assert-Contract ($pluginMain.Contains('sub intranet_js') -and ($pluginMain.Contains('circulation-home.pl') -or $pluginMain.Contains('circulation-home\.pl')) -and $pluginMain.Contains('method=tool') -and $pluginMain.Contains('data-jzl-url')) 'intranet_js emits the Circulation-home plugin-tool shortcut script'
Assert-Contract ($staffJs.Contains("textContent = 'Digital Circulation'") -and $staffJs.Contains('jzl-digital-circulation-shortcut') -and $staffJs.Contains("getElementById('jzl-digital-circulation-shortcut')")) 'Circulation shortcut uses Digital Circulation label, stable ID, and duplicate guard'
Assert-Contract ($staffJs.Contains('.circulation-actions ul.buttons-list,#circ-menu ul,nav[aria-label="Circulation"] ul') -and $staffJs.Contains('dataset.jzlUrl')) 'Circulation shortcut targets Circulation menu selectors with data-jzl-url'
Assert-Contract (-not ($pluginMain -match 'https?://') -and -not $pluginMain.Contains('192.168.') -and -not ($staffJs -match 'https?://') -and -not $staffJs.Contains('192.168.')) 'Circulation shortcut has no hard-coded host'
Assert-Contract (-not $staffJs.Contains('/cgi-bin/koha/circ/circulation.pl') -and -not $staffJs.Contains('/cgi-bin/koha/circ/returns.pl') -and -not $pluginMain.Contains('AddIssue') -and -not $pluginMain.Contains('AddReturn')) 'Circulation shortcut does not use native circulation routes'
$baseRepo = Read-Utf8TextFile (Join-Path $root "$bundle/Repository/Base.pm")
Assert-Contract ($baseRepo.Contains('LEFT JOIN plugin_jzl_ebook_loans l ON l.request_id=r.request_id') -and $baseRepo.Contains('l.loan_id AS loan_id') -and $baseRepo.Contains('l.status AS loan_status')) 'request read model left-joins a safe loan summary'
$portalAuth = Read-Utf8TextFile (Join-Path $root "$bundle/Service/PortalServiceAuthorization.pm")
Assert-Contract ($portalAuth.Contains("CONFIG_KEY => 'portal_service_account_ids'")) 'portal service allowlist has one stable configuration key'
Assert-Contract ($portalAuth.Contains('retrieve_data(CONFIG_KEY)') -and $portalAuth.Contains('store_data( { CONFIG_KEY()')) 'portal service allowlist uses Koha plugin data API'
Assert-Contract ($portalAuth.Contains('sub load_config') -and $portalAuth.Contains('sub store_config')) 'one service owns configuration loading and storage'
Assert-Contract ($portalAuth.Contains("stash('koha.user')")) 'portal service actor comes from Koha authentication context'
Assert-Contract (-not $portalAuth.Contains('haspermission')) 'portal service authorization does not rely on general circulation permission'
$contentAdapter = Read-Utf8TextFile (Join-Path $root "$bundle/Service/EbookContentAdapter.pm")
$contentEligibility = Read-Utf8TextFile (Join-Path $root "$bundle/Service/EbookContentEligibility.pm")
Assert-Contract ($contentAdapter.Contains('Koha::Plugins->get_enabled_plugins')) 'EbookContent adapter uses enabled Koha plugin discovery'
Assert-Contract ($contentAdapter.Contains('validated_mapping')) 'EbookContent adapter uses the verified metadata/content validation boundary'
Assert-Contract ($contentAdapter.Contains("DEPENDENCY_VERSION => '0.1.2'")) 'EbookContent adapter pins the verified dependency contract'
Assert-Contract ($contentAdapter.Contains("reason    => 'CONTENT_LOOKUP_UNAVAILABLE'")) 'EbookContent adapter fails closed when its dependency is unavailable'
Assert-Contract ($contentEligibility.Contains("REQUIRED_CATEGORY => 'EBOOK_PDF'") -and $contentEligibility.Contains("REQUIRED_MIME     => 'application/pdf'")) 'eligibility enforces verified protected PDF type and category'
Assert-Contract ($contentEligibility.Contains('Koha::Biblios->find($biblio_id)')) 'eligibility verifies Koha biblio existence'
Assert-Contract (-not (($contentAdapter + $contentEligibility) -match 'https?://|Authorization:\s*Bearer|/var/lib/koha|[A-Za-z]:[\\/]|KohaPluginWorkspace|SELECT\s+.*ebook')) 'content integration avoids HTTP, OAuth, deployed paths, Windows paths, and private-table coupling'
$requestRepository = Read-Utf8TextFile (Join-Path $root "$bundle/Repository/RequestRepository.pm")
$eventRepository = Read-Utf8TextFile (Join-Path $root "$bundle/Repository/EventRepository.pm")
$requestService = Read-Utf8TextFile (Join-Path $root "$bundle/Service/RequestService.pm")
Assert-Contract ($requestRepository.Contains('find_by_idempotency_key') -and $requestRepository.Contains('find_pending_by_patron_and_biblio') -and $requestRepository.Contains('insert_pending_request') -and $requestRepository.Contains('get_by_id')) 'request repository exposes narrow persistence methods'
Assert-Contract ($eventRepository.Contains('insert_request_created_event')) 'event repository exposes request-created insertion'
Assert-Contract ($requestService.Contains('begin_work') -and $requestService.Contains('commit') -and $requestService.Contains('rollback')) 'request service owns the DML transaction'
Assert-Contract ($requestService.Contains('REQUEST_CREATED') -and $requestService.Contains('IDEMPOTENT_REPLAY') -and $requestService.Contains('DUPLICATE_PENDING') -and $requestService.Contains('IDEMPOTENCY_CONFLICT')) 'request service implements creation and repeat classifications'
Assert-Contract (([regex]::Matches($requestRepository, '\?')).Count -ge 9 -and ([regex]::Matches($eventRepository, '\?')).Count -ge 15) 'request and event repositories use bound SQL placeholders'
Assert-Contract (-not (($requestRepository + $eventRepository + $requestService) -match 'INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)|\b(?:issues|old_issues|reserves|items)\b')) 'request persistence does not write later-phase or native circulation domains'
$loanRepository = Read-Utf8TextFile (Join-Path $root "$bundle/Repository/LoanRepository.pm")
$loanIssuance = Read-Utf8TextFile (Join-Path $root "$bundle/Service/LoanIssuanceService.pm")
$decisionService = Read-Utf8TextFile (Join-Path $root "$bundle/Service/RequestDecisionService.pm")
Assert-Contract ($loanIssuance.Contains('sub issue_loan') -and $loanIssuance.Contains('get_for_issuance') -and $loanIssuance.Contains('insert_active_loan') -and $loanIssuance.Contains('insert_loan_created_event') -and $loanIssuance.Contains('check_biblio_eligibility') -and $loanIssuance.Contains('due_date_policy') -and $loanIssuance.Contains('begin_work') -and $loanIssuance.Contains('commit') -and $loanIssuance.Contains('rollback') -and $loanIssuance.Contains('ACTIVE') -and $loanIssuance.Contains('LOAN_ALREADY_EXISTS') -and $eventRepository.Contains('LOAN_CREATED') -and $eventRepository.Contains('insert_loan_created_event')) 'loan issuance service exists with transactional loan and event creation'
Assert-Contract ($loanIssuance.Contains('request->{patron_id}') -and $loanIssuance.Contains('request->{biblio_id}')) 'loan issuance uses trusted request-derived patron and biblio identity'
Assert-Contract ($loanIssuance.Contains('check_biblio_eligibility') -and $loanIssuance.Contains('PROTECTED_CONTENT_UNAVAILABLE') -and $loanIssuance.Contains('INVALID_MAPPING')) 'loan issuance requires protected-content revalidation'
Assert-Contract ($loanRepository.Contains('find_by_request_id') -and $loanRepository.Contains('insert_active_loan') -and $requestRepository.Contains('get_for_issuance') -and $eventRepository.Contains('insert_loan_created_event')) 'loan issuance persistence methods are narrow and explicit'
Assert-Contract ($source.Contains('our $SCHEMA_VERSION      = 1')) 'schema version remains unchanged for loan issuance foundation'
Assert-Contract (-not ($loanIssuance -match '\b(?:status\s*=>\s*\d{3}|render\s*\(|haspermission|AddIssue|GetIssue)\b|\b(?:issues|old_issues|reserves|items)\b|reader[_-]?token|byte-range|entitlement')) 'loan issuance contains no HTTP, native issue, or reader-access behavior'
Assert-Contract (-not $decisionService.Contains('LoanIssuanceService') -and -not $decisionService.Contains('issue_loan')) 'approval decision service remains unwired from loan issuance'
$loanPeriodPolicy = Read-Utf8TextFile (Join-Path $root "$bundle/Service/ConfiguredLoanPeriodPolicy.pm")
$configureTemplate = Read-Utf8TextFile (Join-Path $root "$bundle/configure.tt")
Assert-Contract ($loanPeriodPolicy.Contains("CONFIG_KEY => 'default_loan_duration_days'") -and $loanPeriodPolicy.Contains('MIN_DAYS   => 1') -and $loanPeriodPolicy.Contains('MAX_DAYS   => 365') -and $loanPeriodPolicy.Contains('sub resolve_due_at')) 'configured production loan policy exists with validated duration range'
Assert-Contract ($loanPeriodPolicy.Contains('loan_duration_missing') -and $loanPeriodPolicy.Contains('INVALID_LOAN_PERIOD')) 'blank configuration fails closed as INVALID_LOAN_PERIOD'
Assert-Contract ($source.Contains('_build_loan_issuance_service') -and $source.Contains('ConfiguredLoanPeriodPolicy')) 'LoanIssuanceService production wiring receives the configured policy'
Assert-Contract ($configureTemplate.Contains('default_loan_duration_days') -and $configureTemplate.Contains('Default digital loan duration (days)')) 'configure page exposes the loan duration setting'
Assert-Contract (-not ($loanPeriodPolicy -match '\b(?:AddIssue|GetIssue)\b|reader[_-]?token|entitlement|byte-range|\bstatus\s*=>\s*\d{3}\b|\brender\s*\(')) 'loan period policy contains no HTTP, native issue, or reader-access behavior'
$staffAuthorization = Read-Utf8TextFile (Join-Path $root "$bundle/Service/StaffDecisionAuthorization.pm")
$staffDecisionApplication = Read-Utf8TextFile (Join-Path $root "$bundle/Service/StaffRequestDecisionApplication.pm")
Assert-Contract ($staffAuthorization.Contains("stash('koha.user')") -and $staffAuthorization.Contains('C4::Auth::haspermission') -and $staffAuthorization.Contains('circulate_remaining_permissions')) 'staff decision authorization uses trusted Koha actor and established permission'
Assert-Contract ($staffAuthorization.Contains('PortalServiceAuthorization->new') -and $staffAuthorization.Contains('load_config') -and $staffAuthorization.Contains('_parse_allowlist') -and -not $staffAuthorization.Contains('PortalServiceAuthorization->authorize_controller')) 'staff decisions reuse canonical portal identity parsing without portal authorization'
Assert-Contract ($staffAuthorization.IndexOf('my $is_service_account') -lt $staffAuthorization.IndexOf('my $permission') -and $staffAuthorization.Contains('STAFF_NOT_AUTHORIZED')) 'configured portal service accounts are denied before staff permission lookup'
$staffDecideRequest = [regex]::Match($staffDecisionApplication, 'sub decide_request \{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($staffDecideRequest.Length -gt 0) 'staff decision application exposes internal decide_request'
Assert-Contract ($staffDecideRequest.IndexOf('_authorize') -lt $staffDecideRequest.IndexOf('_validate_command') -and $staffDecideRequest.IndexOf('_validate_command') -lt $staffDecideRequest.IndexOf('decision_service') -and $staffDecideRequest.IndexOf('decision_service') -lt $staffDecideRequest.IndexOf('_normalize_result')) 'staff decision application preserves authorization-first orchestration order'
Assert-Contract ($staffDecisionApplication.Contains('StaffDecisionAuthorization') -and $staffDecisionApplication.Contains('RequestDecisionService')) 'staff decision application composes authorization and persistence boundaries'
Assert-Contract ($staffDecisionApplication -match 'StaffDecisionAuthorization->new\(\s*plugin\s*=>\s*\$args\{plugin\}') 'staff decision application supplies plugin configuration to authorization'
Assert-Contract (-not $staffDecisionApplication.Contains('PortalServiceAuthorization')) 'staff decision application has no portal authorization dependency'
Assert-Contract (-not ($staffDecisionApplication -match '\b(?:SELECT|INSERT|UPDATE|DELETE)\b|\b(?:begin_work|commit|rollback)\b|\bstatus\s*=>\s*\d{3}\b|\brender\s*\(|plugin_jzl_ebook_(?:loans|renewals)|\b(?:issues|old_issues|reserves|items)\b')) 'staff decision application contains no SQL, transaction, HTTP, loan, or renewal work'
$staffLoanIssuanceApplication = Read-Utf8TextFile (Join-Path $root "$bundle/Service/StaffLoanIssuanceApplication.pm")
Assert-Contract ($staffLoanIssuanceApplication.Contains('sub issue_loan') -and $staffLoanIssuanceApplication.Contains('StaffDecisionAuthorization') -and $staffLoanIssuanceApplication.Contains('LoanIssuanceService')) 'StaffLoanIssuanceApplication exists with staff authorization and issuance delegation'
Assert-Contract ($staffLoanIssuanceApplication -match 'StaffDecisionAuthorization->new\(\s*plugin\s*=>\s*\$args\{plugin\}') 'staff loan issuance application supplies plugin configuration to authorization'
$staffIssueLoan = [regex]::Match($staffLoanIssuanceApplication, 'sub issue_loan \{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($staffIssueLoan.Length -gt 0) 'staff loan issuance application exposes internal issue_loan'
Assert-Contract ($staffIssueLoan.IndexOf('_authorize') -lt $staffIssueLoan.IndexOf('_validate_command') -and $staffIssueLoan.IndexOf('_validate_command') -lt $staffIssueLoan.IndexOf('issuance_service') -and $staffIssueLoan.IndexOf('issuance_service') -lt $staffIssueLoan.IndexOf('_normalize_result')) 'staff loan issuance application preserves authorization-first orchestration order'
Assert-Contract ($staffLoanIssuanceApplication.Contains('request_id => $command->{request_id}') -and $staffLoanIssuanceApplication.Contains('actor_id   => $actor_id')) 'LoanIssuanceService receives trusted actor and validated request ID only'
Assert-Contract (-not $staffLoanIssuanceApplication.Contains('PortalServiceAuthorization')) 'staff loan issuance application has no portal authorization dependency'
Assert-Contract ($staffLoanIssuanceApplication.Contains('ALLOWED_COMMAND_KEYS') -and $staffLoanIssuanceApplication.Contains('INVALID_INPUT')) 'staff loan issuance command rejects caller authority fields'
Assert-Contract (-not ($staffLoanIssuanceApplication -match '\b(?:SELECT|INSERT|UPDATE|DELETE)\b|\b(?:begin_work|commit|rollback)\b|\bstatus\s*=>\s*\d{3}\b|\brender\s*\(|\b(?:AddIssue|GetIssue)\b|reader[_-]?token|entitlement|byte-range|plugin_jzl_ebook_(?:loans|renewals)|\b(?:issues|old_issues|reserves|items)\b')) 'staff loan issuance application contains no SQL, HTTP, native issue, or reader-access behavior'
$requestApplication = Read-Utf8TextFile (Join-Path $root "$bundle/Service/PortalRequestApplication.pm")
$createRequest = [regex]::Match($requestApplication, 'sub create_request \{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($createRequest.Length -gt 0) 'portal request application exposes internal create_request'
Assert-Contract ($createRequest.IndexOf('_authorize') -lt $createRequest.IndexOf('patron_validator') -and $createRequest.IndexOf('patron_validator') -lt $createRequest.IndexOf('_check_eligibility') -and $createRequest.IndexOf('_check_eligibility') -lt $createRequest.IndexOf('create_portal_request')) 'portal request application preserves authorization-first orchestration order'
Assert-Contract ($requestApplication.Contains('PortalServiceAuthorization') -and $requestApplication.Contains('EbookContentEligibility') -and $requestApplication.Contains('RequestService')) 'portal request application reuses existing services'
Assert-Contract (-not ($requestApplication -match '\b(?:SELECT|INSERT|UPDATE|DELETE)\b|\b(?:begin_work|commit|rollback)\b|\bstatus\s*=>\s*\d{3}\b|\brender\s*\(')) 'portal request application contains no SQL, transaction, or HTTP mapping'
Assert-Contract (([regex]::Matches($source, 'use base qw\(Koha::Plugins::Base\)')).Count -eq 1) 'single Koha::Plugins::Base inheritance declaration'
Assert-Contract (-not $source.Contains('use parent')) 'no conflicting parent declaration'
$uninstall = [regex]::Match($source, 'sub uninstall \{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract (-not $uninstall.Contains('DROP TABLE')) 'normal uninstall preserves tables'
$openapiText = Read-Utf8TextFile (Join-Path $root "$bundle/openapi.json")
$openapi = $openapiText | ConvertFrom-Json
$writeRoutes = @()
foreach ($pathProperty in $openapi.PSObject.Properties) {
    foreach ($methodProperty in $pathProperty.Value.PSObject.Properties) {
        if ($methodProperty.Name -match '^(?:post|put|patch|delete)$') {
            $writeRoutes += "$($methodProperty.Name) $($pathProperty.Name)"
        }
    }
}
Assert-Contract ($writeRoutes.Count -eq 7 -and $writeRoutes -contains 'post /requests' -and $writeRoutes -contains 'post /requests/{request_id}/decision' -and $writeRoutes -contains 'post /requests/{request_id}/issue' -and $writeRoutes -contains 'post /loans/{loan_id}/return' -and $writeRoutes -contains 'post /loans/{loan_id}/renew' -and $writeRoutes -contains 'post /loans/{loan_id}/revoke' -and $writeRoutes -contains 'post /maintenance/expire-loans') 'source OpenAPI has exactly seven required POST routes'
$portalLoanGet = $openapi.'/patrons/{patron_id}/loans'.get
Assert-Contract ($portalLoanGet.operationId -eq 'jzlListPatronDigitalLoans' -and $portalLoanGet.'x-mojo-to' -eq 'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Patrons#list_loans') 'portal loan-read OpenAPI route and controller operation agree'
$portalLoanPatron = $portalLoanGet.parameters | Where-Object { $_.in -eq 'path' -and $_.name -eq 'patron_id' }
$portalLoanCorrelation = $portalLoanGet.parameters | Where-Object { $_.in -eq 'header' -and $_.name -eq 'X-Correlation-ID' }
$portalLoanStatus = $portalLoanGet.parameters | Where-Object { $_.in -eq 'query' -and $_.name -eq 'status' }
Assert-Contract ($portalLoanPatron.required -and $portalLoanCorrelation.required -and -not $portalLoanStatus) 'portal loan-read requires path patron_id and correlation UUID without status filter'
Assert-Contract ($portalLoanGet.responses.'200'.schema.additionalProperties -eq $false -and $portalLoanGet.responses.'200'.schema.properties.loans.items.properties.portal_request_id -and -not $portalLoanGet.responses.'200'.schema.properties.loans.items.properties.portal_ebook_uuid -and -not $portalLoanGet.responses.'200'.schema.properties.loans.items.properties.approved_by) 'portal loan-read schema uses portal_request_id and forbids ebook UUID/approved_by'
Assert-Contract ($portalLoanGet.responses.'200' -and $portalLoanGet.responses.'400' -and $portalLoanGet.responses.'401' -and $portalLoanGet.responses.'403' -and $portalLoanGet.responses.'500' -and $portalLoanGet.responses.'503') 'portal loan-read response statuses are complete'
$portalLoanApplication = Read-Utf8TextFile (Join-Path $root "$bundle/Service/PortalLoanReadApplication.pm")
$patronsController = Read-Utf8TextFile (Join-Path $root "$bundle/Controller/Patrons.pm")
$loanRepository = Read-Utf8TextFile (Join-Path $root "$bundle/Repository/LoanRepository.pm")
Assert-Contract ($portalLoanApplication.Contains('PortalServiceAuthorization') -and -not $portalLoanApplication.Contains('StaffDecisionAuthorization') -and $portalLoanApplication.Contains('sub list_patron_loans') -and $portalLoanApplication.Contains('list_for_patron') -and -not $portalLoanApplication.Contains('portal_ebook_uuid')) 'PortalLoanReadApplication uses portal authorization and repository list_for_patron'
Assert-Contract ($patronsController.Contains('sub list_loans') -and $patronsController.Contains('PortalLoanReadApplication') -and -not $patronsController.Contains('StaffDecisionAuthorization') -and $patronsController.Contains('X-Correlation-ID') -and -not $patronsController.Contains('selectrow') -and -not $patronsController.Contains('INSERT')) 'patrons controller is a thin read adapter without SQL writes'
Assert-Contract ($loanRepository.Contains('sub list_for_patron') -and $loanRepository.Contains('INNER JOIN') -and $loanRepository.Contains('portal_request_id')) 'list_for_patron joins requests for portal_request_id'
$returnPost = $openapi.'/loans/{loan_id}/return'.post
Assert-Contract ($returnPost.operationId -eq 'jzlReturnDigitalLoan' -and $returnPost.'x-mojo-to' -eq 'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Loans#return_loan') 'patron return OpenAPI route and controller operation agree'
Assert-Contract ($returnPost.'x-koha-authorization'.permissions.circulate -eq 'circulate_remaining_permissions') 'patron return route declares established Koha permission'
$returnPath = $returnPost.parameters | Where-Object { $_.in -eq 'path' -and $_.name -eq 'loan_id' }
$returnCorrelation = $returnPost.parameters | Where-Object { $_.in -eq 'header' -and $_.name -eq 'X-Correlation-ID' }
$returnBody = $returnPost.parameters | Where-Object { $_.in -eq 'body' -and $_.name -eq 'body' }
Assert-Contract ($returnPath.required -and $returnCorrelation.required -and $returnBody.required) 'patron return requires path, correlation header, and body'
Assert-Contract ($returnBody.schema.additionalProperties -eq $false -and $returnBody.schema.required.Count -eq 3 -and $returnBody.schema.properties.patron_id -and $returnBody.schema.properties.portal_request_id -and $returnBody.schema.properties.expected_row_version) 'patron return body is closed and carries correlation fields'
Assert-Contract ($returnPost.responses.'200' -and $returnPost.responses.'400' -and $returnPost.responses.'401' -and $returnPost.responses.'403' -and $returnPost.responses.'404' -and $returnPost.responses.'409' -and $returnPost.responses.'500' -and $returnPost.responses.'503') 'patron return response statuses are complete'
$loanReturnService = Read-Utf8TextFile (Join-Path $root "$bundle/Service/LoanReturnService.pm")
$loanLifecycleService = Read-Utf8TextFile (Join-Path $root "$bundle/Service/LoanLifecycleService.pm")
$lifecyclePolicy = Read-Utf8TextFile (Join-Path $root "$bundle/Service/LifecyclePolicy.pm")
$portalLoanReturnApplication = Read-Utf8TextFile (Join-Path $root "$bundle/Service/PortalLoanReturnApplication.pm")
$loansController = Read-Utf8TextFile (Join-Path $root "$bundle/Controller/Loans.pm")
Assert-Contract ($loanReturnService.Contains('RETURNED') -and $loanReturnService.Contains('insert_loan_returned_event') -and $loanReturnService.Contains('update_active_return') -and $loanReturnService.Contains('idempotent_replay') -and -not ($loanReturnService -match '\b(?:AddIssue|AddReturn|GetIssue)\b')) 'LoanReturnService returns ACTIVE loans without native Koha circulation mutation'
$eventRepository = Read-Utf8TextFile (Join-Path $root "$bundle/Repository/EventRepository.pm")
Assert-Contract ($eventRepository.Contains("event_type = 'LOAN_RETURNED'") -or $eventRepository.Contains('LOAN_RETURNED')) 'event repository records LOAN_RETURNED'
Assert-Contract ($portalLoanReturnApplication.Contains('PortalServiceAuthorization') -and -not $portalLoanReturnApplication.Contains('StaffDecisionAuthorization') -and $portalLoanReturnApplication.Contains('sub return_loan')) 'PortalLoanReturnApplication uses portal service authorization'
Assert-Contract ($loansController.Contains('sub return_loan') -and $loansController.Contains('PortalLoanReturnApplication') -and $loansController.Contains('X-Correlation-ID') -and -not $loansController.Contains('StaffDecisionAuthorization')) 'loans controller exposes thin portal return adapter'
Assert-Contract ($loanRepository.Contains('sub get_for_return') -and $loanRepository.Contains('sub update_active_return') -and $loanRepository.Contains('FOR UPDATE')) 'loan repository supports locked return reads and conditional ACTIVE updates'
Assert-Contract ($loanLifecycleService.Contains('sub renew') -and $loanLifecycleService.Contains('sub revoke') -and $loanLifecycleService.Contains('sub expire_due') -and $loanLifecycleService.Contains('GET_LOCK') -and $loanLifecycleService.Contains("'renewed'") -and $loanLifecycleService.Contains("'revoked'") -and $loanLifecycleService.Contains("'expired'")) 'authoritative lifecycle service implements renewal, revocation, expiry, locking, and event insertion'
Assert-Contract ($lifecyclePolicy.Contains('renewals_enabled') -and $lifecyclePolicy.Contains('staff_revocations_enabled') -and $lifecyclePolicy.Contains('automatic_expiry_enabled') -and $lifecyclePolicy.Contains('renewal_days') -and $lifecyclePolicy.Contains('maximum_renewals') -and $lifecyclePolicy.Contains('expiry_batch_size')) 'lifecycle policy owns all disabled-by-default controls and bounded policy values'
$issuePost = $openapi.'/requests/{request_id}/issue'.post
Assert-Contract ($issuePost.operationId -eq 'jzlIssueDigitalLoan' -and $issuePost.'x-mojo-to' -eq 'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#issue') 'staff issuance OpenAPI route and controller operation agree'
Assert-Contract ($issuePost.'x-koha-authorization'.permissions.circulate -eq 'circulate_remaining_permissions') 'staff issuance route declares established Koha permission'
$issuePath = $issuePost.parameters | Where-Object { $_.in -eq 'path' -and $_.name -eq 'request_id' }
$issueCorrelation = $issuePost.parameters | Where-Object { $_.in -eq 'header' -and $_.name -eq 'X-Correlation-ID' }
$issueBody = $issuePost.parameters | Where-Object { $_.in -eq 'body' -and $_.name -eq 'body' }
Assert-Contract ($issuePath.required -and $issueCorrelation.required -and -not $issueBody) 'staff issuance requires path and correlation header and no body'
Assert-Contract ($issuePost.responses.'201' -and $issuePost.responses.'400' -and $issuePost.responses.'401' -and $issuePost.responses.'403' -and $issuePost.responses.'404' -and $issuePost.responses.'409' -and $issuePost.responses.'500' -and $issuePost.responses.'503') 'staff issuance response statuses are complete'
$decisionPost = $openapi.'/requests/{request_id}/decision'.post
Assert-Contract ($decisionPost.operationId -eq 'jzlDecideDigitalRequest' -and $decisionPost.'x-mojo-to' -eq 'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#decide') 'staff decision OpenAPI route and controller operation agree'
Assert-Contract ($decisionPost.'x-koha-authorization'.permissions.circulate -eq 'circulate_remaining_permissions') 'staff decision route declares established Koha permission'
$decisionPath = $decisionPost.parameters | Where-Object { $_.in -eq 'path' -and $_.name -eq 'request_id' }
$decisionCorrelation = $decisionPost.parameters | Where-Object { $_.in -eq 'header' -and $_.name -eq 'X-Correlation-ID' }
$decisionBody = $decisionPost.parameters | Where-Object { $_.in -eq 'body' -and $_.name -eq 'body' }
Assert-Contract ($decisionPath.required -and $decisionCorrelation.required -and $decisionBody.required) 'staff decision path, correlation header, and body are required'
Assert-Contract ($decisionBody.schema.additionalProperties -eq $false -and $decisionBody.schema.required.Count -eq 2 -and $decisionBody.schema.properties.decision.enum[0] -eq 'APPROVE' -and $decisionBody.schema.properties.decision.enum[1] -eq 'REJECT') 'staff decision body is closed and command enum is exact'
Assert-Contract ($decisionPost.responses.'200' -and $decisionPost.responses.'400' -and $decisionPost.responses.'401' -and $decisionPost.responses.'403' -and $decisionPost.responses.'404' -and $decisionPost.responses.'409' -and $decisionPost.responses.'500' -and $decisionPost.responses.'503') 'staff decision response statuses are complete'
$requestController = Read-Utf8TextFile (Join-Path $root "$bundle/Controller/Requests.pm")
Assert-Contract ($requestController.Contains('sub decide') -and $requestController.Contains('_staff_request_decision_application') -and $requestController.Contains('StaffRequestDecisionApplication->new')) 'request controller exposes decision application adapter'
Assert-Contract ($requestController.Contains('sub issue') -and $requestController.Contains('_staff_loan_issuance_application') -and $requestController.Contains('StaffLoanIssuanceApplication->new') -and $requestController.Contains('issue_loan')) 'request controller exposes staff loan issuance application adapter'
$staffIssueAction = [regex]::Match($requestController, 'sub issue \{.*?\nsub ', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($staffIssueAction.Length -gt 0) 'issuance controller action body is extractable'
Assert-Contract ($staffIssueAction.Contains('X-Correlation-ID') -and $staffIssueAction.Contains('_uuid($correlation_id)') -and $staffIssueAction.Contains('_issue_body_rejected') -and $staffIssueAction.Contains('_staff_loan_issuance_application')) 'issuance action requires correlation UUID and rejects authority-bearing bodies'
Assert-Contract (-not $staffIssueAction.Contains('patron_id =>') -and -not $staffIssueAction.Contains('biblio_id =>') -and -not $staffIssueAction.Contains('due_at =>') -and -not $staffIssueAction.Contains('actor_id =>') -and -not $staffIssueAction.Contains('duration')) 'issuance controller does not accept caller patron, biblio, due date, or actor fields'
Assert-Contract ($requestController.Contains('@PUBLIC_LOAN_FIELDS') -and $requestController.Contains('_public_loan')) 'issuance controller enforces a safe response-field allowlist'
Assert-Contract (-not ($requestController -match '\b(?:begin_work|commit|rollback|haspermission)\b|PortalServiceAuthorization|portal_service_account_ids|INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)|\b(?:AddIssue|GetIssue)\b|reader[_-]?token|entitlement')) 'request controller contains no transaction, permission, portal SQL, native issue, or reader-access work'
Assert-Contract ($openapiText.Contains('"/assets/{asset}"')) 'OpenAPI asset route exists'
Assert-Contract ($source.Contains('/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-css')) 'CSS logical URL matches REST namespace'
Assert-Contract ($source.Contains('/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-js')) 'JavaScript logical URL matches REST namespace'
Assert-Contract (-not $source.Contains('/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation.css')) 'broken extension-bearing CSS URL is absent'
Assert-Contract (-not $source.Contains('/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation.js')) 'broken extension-bearing JavaScript URL is absent'
Assert-Contract (($manifest | Select-Object -Unique).Count -eq $manifest.Count) 'MANIFEST has no duplicate paths'

if ($Kpz) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $resolvedKpz = Resolve-Path $Kpz
    Assert-Contract (
        (Split-Path -Leaf $resolvedKpz) -match '^JunaidZaidiLibrary-DigitalCirculation-v0\.3\.1(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?\.kpz$'
    ) 'archive filename matches internal plugin version'
    Assert-Contract ((Get-Item $resolvedKpz).Length -ge 10000) 'archive is not suspiciously small'
    $archive = [IO.Compression.ZipFile]::OpenRead($resolvedKpz)
    try {
        $names = @($archive.Entries | ForEach-Object FullName | Sort-Object)
        $packagedMain = Read-ArchiveText $archive "$bundle.pm"
        $packagedOpenapiText = Read-ArchiveText $archive "$bundle/openapi.json"
        $packagedTool = Read-ArchiveText $archive "$bundle/tool.tt"
        $packagedStaffJs = Read-ArchiveText $archive "$bundle/static/js/jzl-digital-circulation.js"
        $packagedConfigure = Read-ArchiveText $archive "$bundle/configure.tt"
        $productionText = ($archive.Entries | Where-Object {
            $_.FullName -match '\.(?:pm|json|tt|js|css)$'
        } | ForEach-Object {
            Read-ArchiveText $archive $_.FullName
        }) -join "`n"
    }
    finally { $archive.Dispose() }
    $expected = @($manifest | Sort-Object)
    Assert-Contract ((Compare-Object $expected $names).Count -eq 0) 'archive tree exactly matches MANIFEST'
    $bad = @($names | Where-Object { $_ -match '(^|/)(\.git|t|diagnostics|node_modules|vendor|coverage|test-results|__pycache__)(/|$)|(^|/)\.env($|\.)|\.(kpz|dump|backup|key|pem|pdf|db|sqlite|sql|swp|pyc)$|~$|\.before-diagnostic$' })
    Assert-Contract ($bad.Count -eq 0) 'archive excludes secrets, dumps, caches, backups, and nested KPZ files'
    Assert-Contract (-not ($names | Where-Object { ($_ -ne 'MANIFEST' -and $_ -notmatch '^Koha/') -or $_ -match '\\' })) 'archive uses package-relative Unix paths with one root MANIFEST'
    Assert-Contract ($names -contains 'MANIFEST') 'archive contains root MANIFEST'
    Assert-Contract (($names | Where-Object { $_ -eq "$bundle.pm" }).Count -eq 1) 'archive has one plugin root'
    Assert-Contract ($names -contains "$bundle/tool.tt") 'archive contains tool.tt at bundle root'
    Assert-Contract ($names -contains "$bundle/configure.tt") 'archive contains configure.tt at bundle root'
    Assert-Contract (-not ($names | Where-Object { $_ -like 'Koha_Digital_Circulation_Plugin/*' })) 'archive has no extra repository directory'
    Assert-Contract ($packagedMain.Contains("our `$VERSION             = '0.4.0';")) 'packaged internal plugin version is 0.4.0'
    Assert-Contract ($packagedMain.Contains('sub _stamp_schema_state') -and $packagedMain.Contains('ON DUPLICATE KEY UPDATE') -and ($packagedMain -match 'plugin_version\s*=\s*VALUES\(plugin_version\)') -and -not $packagedMain.Contains('INSERT IGNORE INTO `$v`')) 'packaged upgrade path explicitly refreshes the plugin-version stamp'
    Assert-Contract ($packagedMain.Contains('Schema state must contain exactly one canonical row') -and $packagedMain.Contains('Schema version 1 was not recorded')) 'packaged upgrade path retains strict schema-state verification'
    Assert-Contract ($packagedMain.Contains("return 'jzl-digital-circulation';")) 'packaged API namespace is unchanged'
    $packagedOpenapi = $packagedOpenapiText | ConvertFrom-Json
    $operationIds = @()
    $postRoutes = @()
    foreach ($pathProperty in $packagedOpenapi.PSObject.Properties) {
        foreach ($methodProperty in $pathProperty.Value.PSObject.Properties) {
            if ($methodProperty.Name -match '^(?:get|post|put|patch|delete)$') {
                $operationIds += $methodProperty.Value.operationId
            }
            if ($methodProperty.Name -eq 'post') { $postRoutes += $pathProperty.Name }
        }
    }
    Assert-Contract ($operationIds.Count -eq ($operationIds | Select-Object -Unique).Count) 'packaged OpenAPI operation IDs are unique'
    Assert-Contract ($postRoutes.Count -eq 7 -and $postRoutes -contains '/requests' -and $postRoutes -contains '/requests/{request_id}/decision' -and $postRoutes -contains '/requests/{request_id}/issue' -and $postRoutes -contains '/loans/{loan_id}/return' -and $postRoutes -contains '/loans/{loan_id}/renew' -and $postRoutes -contains '/loans/{loan_id}/revoke' -and $postRoutes -contains '/maintenance/expire-loans') 'packaged OpenAPI has exactly seven required POST routes'
    Assert-Contract ($packagedOpenapi.'/loans/{loan_id}/return'.post.operationId -eq 'jzlReturnDigitalLoan') 'packaged return operation ID is correct'
    Assert-Contract ($packagedOpenapi.'/requests/{request_id}/issue'.post.operationId -eq 'jzlIssueDigitalLoan') 'packaged issuance operation ID is correct'
    $post = $packagedOpenapi.'/requests'.post
    Assert-Contract ($post.operationId -eq 'jzlCreateDigitalRequest') 'packaged request operation ID is correct'
    $body = $post.parameters | Where-Object { $_.in -eq 'body' -and $_.name -eq 'body' }
    Assert-Contract ($body.required -and $body.schema.additionalProperties -eq $false) 'packaged request body is required and closed'
    $headerNames = @($post.parameters | Where-Object { $_.in -eq 'header' -and $_.required } | ForEach-Object name)
    Assert-Contract ($headerNames -contains 'Idempotency-Key' -and $headerNames -contains 'X-Correlation-ID') 'packaged required UUID headers are documented'
    Assert-Contract ($post.responses.'200' -and $post.responses.'201' -and $post.responses.'400' -and $post.responses.'401' -and $post.responses.'403' -and $post.responses.'404' -and $post.responses.'409' -and $post.responses.'500' -and $post.responses.'503') 'packaged request responses are complete'
    $packagedStaffUi = $packagedTool + "`n" + $packagedStaffJs
    Assert-Contract ($packagedTool.Contains($phase2Boundary) -and $packagedTool.Contains('never create, renew, or return a native Koha checkout')) 'packaged staff tool states the authoritative/native circulation boundary'
    Assert-Contract ($packagedStaffJs.Contains("approve.textContent = 'Approve'") -and $packagedStaffJs.Contains("reject.textContent = 'Reject'") -and $packagedStaffJs.Contains("request.status === 'PENDING'")) 'packaged staff tool exposes Approve and Reject only for pending requests'
    Assert-Contract ($packagedStaffJs.Contains("issue.textContent = 'Issue Loan'") -and $packagedStaffJs.Contains('canIssueRequest(request)') -and $packagedStaffJs.Contains("'/issue'") -and $packagedStaffJs.Contains('submitIssuance')) 'packaged staff tool exposes Issue Loan for eligible approved requests'
    Assert-Contract ($packagedStaffJs.Contains("DECISION_PATH = '/requests/'") -and $packagedStaffJs.Contains("'/decision'") -and $packagedStaffJs.Contains("ISSUE_PATH = '/requests/'") -and $packagedStaffJs.Contains("method: 'POST'") -and $packagedStaffJs.Contains("credentials: 'same-origin'")) 'packaged staff decisions and issuance use only the same-origin verified REST endpoints'
    Assert-Contract ($packagedStaffJs.Contains("'X-Correlation-ID': correlationId") -and $packagedStaffJs.Contains('expected_row_version: version') -and $packagedStaffJs.Contains('window.crypto.randomUUID()') -and $packagedStaffJs.Contains('window.crypto.getRandomValues(bytes)')) 'packaged staff writes use a fresh secure correlation UUID and row version'
    Assert-Contract (-not $packagedStaffJs.Contains('innerHTML') -and -not $packagedStaffJs.Contains('Authorization') -and -not $packagedStaffUi.Contains('portal_service_account_ids') -and -not $packagedStaffJs.Contains('grantAccess') -and -not $packagedStaffJs.Contains('activateReader')) 'packaged staff UI contains no unsafe HTML, authorization header, portal allowlist, or reader access'
    foreach ($control in @('Create','Delete','Return','Renew','Edit')) {
        Assert-Contract (-not ($packagedTool -match ">\s*$control(?: Request)?\s*<") -and -not ($packagedStaffJs -match "\.textContent\s*=\s*['""]$control(?: Request)?['""]")) "packaged staff tool has no $control write control"
    }
    Assert-Contract ($names -contains "$bundle/Service/StaffLoanIssuanceApplication.pm" -and $names -contains "$bundle/Service/ConfiguredLoanPeriodPolicy.pm" -and $names -contains "$bundle/Service/LoanIssuanceService.pm") 'packaged archive includes Phase 2C issuance runtime modules'
    Assert-Contract ($names -contains "$bundle/Service/LoanReturnService.pm" -and $names -contains "$bundle/Service/PortalLoanReturnApplication.pm" -and $names -contains "$bundle/Controller/Loans.pm") 'packaged archive includes Phase 4B return runtime modules'
    Assert-Contract ($names -contains "$bundle/Service/SavedReportDefinitions.pm" -and $names -contains "$bundle/Service/SavedReportProvisioning.pm" -and $names -contains "$bundle/Repository/SavedReportRepository.pm") 'packaged archive includes Phase 6 Saved Reports runtime modules'
    $packagedReportDefinitions = Read-ArchiveText $archive "$bundle/Service/SavedReportDefinitions.pm"
    Assert-Contract (([regex]::Matches($packagedReportDefinitions, 'slug =>')).Count -eq 10 -and $packagedReportDefinitions.Contains('<<Item type|itemtypes>>')) 'packaged archive has ten Item Type-filtered managed reports'
    Assert-Contract ($packagedConfigure.Contains('name="csrf_token"')) 'packaged configuration includes CSRF token field'
    Assert-Contract (-not ($packagedConfigure -match 'name="[^"]*(?:client_secret|bearer|password|database|dsn)[^"]*"')) 'packaged configuration requests no credentials'
    Assert-Contract (-not ($productionText -match '(?<![A-Za-z0-9_])[A-Za-z]:\\[^\\\r\n]{2,}\\|/var/lib/koha/library|Authorization:\s*Bearer\s+[A-Za-z0-9._~+/-]{12,}|(?:client_secret|password)\s*(?:=>|=)\s*[''"][^''"]+[''"]')) 'packaged production files contain no paths or literal credentials'
    $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedKpz).Hash.ToLowerInvariant()
    Write-Output "SHA-256: $sha256"
}
$reportDefinitions = Get-Content -Raw -LiteralPath (Join-Path $root 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/SavedReportDefinitions.pm')
Assert-Contract (([regex]::Matches($reportDefinitions, 'slug =>')).Count -eq 10) 'Phase 6 defines exactly ten managed reports'
Assert-Contract ($reportDefinitions.Contains('<<Item type|itemtypes>>') -and $reportDefinitions.Contains('item-level_itypes') -and $reportDefinitions.Contains('SELECT DISTINCT item_map.biblionumber, item_map.item_type')) 'Phase 6 uses native item-type selection with de-duplicated dual-mode mapping'
Assert-Contract (-not ($reportDefinitions -match '(?i)(?:FROM|JOIN)\s+issues\b')) 'Phase 6 never treats native issues as digital lifecycle data'
Write-Output 'Source/package validation passed'
