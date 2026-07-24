param([string]$Kpz)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bundle = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation'
$main = Join-Path $root 'Koha\Plugin\Com\JunaidZaidiLibrary\DigitalCirculation.pm'
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$phase2Boundary = 'Phase 2B ' + [char]0x2014 + ' request decisions'

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

Assert-Contract ($source.Contains("our `$VERSION             = '0.2.0';")) 'plugin version is 0.2.0'
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
Assert-Contract ($source.Contains('INSERT IGNORE INTO `$v`')) 'schema version insertion is retry-safe'
Assert-Contract (([regex]::Matches($source, 'CREATE TABLE IF NOT EXISTS')).Count -eq 5) 'partial migration retry preserves existing tables'
Assert-Contract ($source.Contains('$self->_verify_schema($dbh);')) 'install verifies schema before success'
Assert-Contract ($source.Contains('Schema version 1 was not recorded')) 'install verifies schema version 1'
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
foreach ($runtime in @("$bundle.pm", "$bundle/openapi.json", "$bundle/Controller/Requests.pm", "$bundle/Service/EbookContentAdapter.pm", "$bundle/Service/EbookContentEligibility.pm", "$bundle/Service/PortalServiceAuthorization.pm", "$bundle/Service/PortalRequestApplication.pm", "$bundle/Repository/RequestRepository.pm", "$bundle/Repository/EventRepository.pm", "$bundle/Repository/LoanRepository.pm", "$bundle/Service/RequestDecisionService.pm", "$bundle/Service/RequestService.pm", "$bundle/Service/LoanIssuanceService.pm", "$bundle/Service/StaffDecisionAuthorization.pm", "$bundle/Service/StaffRequestDecisionApplication.pm", "$bundle/static/css/jzl-digital-circulation.css", "$bundle/static/js/jzl-digital-circulation.js")) {
    Assert-Contract (($manifest -contains $runtime) -and (Test-Path (Join-Path $root $runtime))) "runtime file packaged: $runtime"
}
$tool = Read-Utf8TextFile (Join-Path $root $toolPath)
$staffJs = Read-Utf8TextFile (Join-Path $root "$bundle/static/js/jzl-digital-circulation.js")
$staffUi = $tool + "`n" + $staffJs
Assert-Contract ($tool.Contains($phase2Boundary) -and $tool.Contains('does not create a loan or grant digital access')) 'staff tool states the Phase 2B decision-only boundary'
Assert-Contract ($staffJs.Contains("approve.textContent = 'Approve'") -and $staffJs.Contains("reject.textContent = 'Reject'") -and $staffJs.Contains("request.status === 'PENDING'")) 'staff tool exposes Approve and Reject only for pending requests'
Assert-Contract ($staffJs.Contains("DECISION_PATH = '/requests/'") -and $staffJs.Contains("'/decision'") -and $staffJs.Contains("method: 'POST'") -and $staffJs.Contains("credentials: 'same-origin'")) 'staff decisions use only the same-origin verified REST endpoint'
Assert-Contract ($staffJs.Contains("'X-Correlation-ID': correlationId") -and $staffJs.Contains('expected_row_version: version') -and $staffJs.Contains('window.crypto.randomUUID()') -and $staffJs.Contains('window.crypto.getRandomValues(bytes)')) 'staff decisions use a fresh secure correlation UUID and row version'
Assert-Contract (-not $staffJs.Contains('innerHTML') -and -not $staffJs.Contains('Authorization') -and -not $staffUi.Contains('portal_service_account_ids')) 'staff UI contains no unsafe HTML, authorization header, or portal allowlist'
foreach ($control in @('Create','Delete','Return','Renew','Revoke','Edit','Issue')) {
    Assert-Contract (-not ($tool -match ">\s*$control(?: Request)?\s*<") -and -not ($staffJs -match "\.textContent\s*=\s*['""]$control(?: Request)?['""]")) "staff tool has no $control write control"
}
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
$staffAuthorization = Read-Utf8TextFile (Join-Path $root "$bundle/Service/StaffDecisionAuthorization.pm")
$staffDecisionApplication = Read-Utf8TextFile (Join-Path $root "$bundle/Service/StaffRequestDecisionApplication.pm")
Assert-Contract ($staffAuthorization.Contains("stash('koha.user')") -and $staffAuthorization.Contains('C4::Auth::haspermission') -and $staffAuthorization.Contains('circulate_remaining_permissions')) 'staff decision authorization uses trusted Koha actor and established permission'
Assert-Contract ($staffAuthorization.Contains('PortalServiceAuthorization->new') -and $staffAuthorization.Contains('load_config') -and $staffAuthorization.Contains('_parse_allowlist') -and -not $staffAuthorization.Contains('PortalServiceAuthorization->authorize_controller')) 'staff decisions reuse canonical portal identity parsing without portal authorization'
Assert-Contract ($staffAuthorization.IndexOf('my $is_service_account') -lt $staffAuthorization.IndexOf('my $permission') -and $staffAuthorization.Contains('STAFF_NOT_AUTHORIZED')) 'configured portal service accounts are denied before staff permission lookup'
$staffDecideRequest = [regex]::Match($staffDecisionApplication, 'sub decide_request \{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline).Value
Assert-Contract ($staffDecideRequest.Length -gt 0) 'staff decision application exposes internal decide_request'
Assert-Contract ($staffDecideRequest.IndexOf('_authorize') -lt $staffDecideRequest.IndexOf('_validate_command') -and $staffDecideRequest.IndexOf('_validate_command') -lt $staffDecideRequest.IndexOf('decision_service') -and $staffDecideRequest.IndexOf('decision_service') -lt $staffDecideRequest.IndexOf('_normalize_result')) 'staff decision application preserves authorization-first orchestration order'
Assert-Contract ($staffDecisionApplication.Contains('StaffDecisionAuthorization') -and $staffDecisionApplication.Contains('RequestDecisionService')) 'staff decision application composes authorization and persistence boundaries'
Assert-Contract ($staffDecisionApplication.Contains("StaffDecisionAuthorization->new(`n                plugin => `$args{plugin}")) 'staff decision application supplies plugin configuration to authorization'
Assert-Contract (-not $staffDecisionApplication.Contains('PortalServiceAuthorization')) 'staff decision application has no portal authorization dependency'
Assert-Contract (-not ($staffDecisionApplication -match '\b(?:SELECT|INSERT|UPDATE|DELETE)\b|\b(?:begin_work|commit|rollback)\b|\bstatus\s*=>\s*\d{3}\b|\brender\s*\(|plugin_jzl_ebook_(?:loans|renewals)|\b(?:issues|old_issues|reserves|items)\b')) 'staff decision application contains no SQL, transaction, HTTP, loan, or renewal work'
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
Assert-Contract ($writeRoutes.Count -eq 2 -and $writeRoutes -contains 'post /requests' -and $writeRoutes -contains 'post /requests/{request_id}/decision') 'source OpenAPI has only request creation and staff decision POST routes'
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
Assert-Contract (-not ($requestController -match '\b(?:begin_work|commit|rollback|haspermission)\b|PortalServiceAuthorization|portal_service_account_ids|INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)')) 'request controller contains no transaction, permission, portal, loan, or renewal work'
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
        (Split-Path -Leaf $resolvedKpz) -match '^JunaidZaidiLibrary-DigitalCirculation-v0\.2\.0(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?\.kpz$'
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
    $bad = @($names | Where-Object { $_ -match '(^|/)(\.git|t|diagnostics|node_modules|vendor|coverage|test-results|__pycache__)(/|$)|(^|/)\.env($|\.)|\.(kpz|db|sqlite|sql|swp|pyc)$|~$|\.before-diagnostic$' })
    Assert-Contract ($bad.Count -eq 0) 'archive excludes secrets, dumps, caches, backups, and nested KPZ files'
    Assert-Contract (-not ($names | Where-Object { $_ -notmatch '^Koha/' -or $_ -match '\\' })) 'archive uses package-relative Unix paths'
    Assert-Contract (($names | Where-Object { $_ -eq "$bundle.pm" }).Count -eq 1) 'archive has one plugin root'
    Assert-Contract ($names -contains "$bundle/tool.tt") 'archive contains tool.tt at bundle root'
    Assert-Contract ($names -contains "$bundle/configure.tt") 'archive contains configure.tt at bundle root'
    Assert-Contract (-not ($names | Where-Object { $_ -like 'Koha_Digital_Circulation_Plugin/*' })) 'archive has no extra repository directory'
    Assert-Contract ($packagedMain.Contains("our `$VERSION             = '0.2.0';")) 'packaged internal plugin version is 0.2.0'
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
    Assert-Contract ($postRoutes.Count -eq 2 -and $postRoutes -contains '/requests' -and $postRoutes -contains '/requests/{request_id}/decision') 'packaged OpenAPI has exactly the request creation and staff decision POST routes'
    $post = $packagedOpenapi.'/requests'.post
    Assert-Contract ($post.operationId -eq 'jzlCreateDigitalRequest') 'packaged request operation ID is correct'
    $body = $post.parameters | Where-Object { $_.in -eq 'body' -and $_.name -eq 'body' }
    Assert-Contract ($body.required -and $body.schema.additionalProperties -eq $false) 'packaged request body is required and closed'
    $headerNames = @($post.parameters | Where-Object { $_.in -eq 'header' -and $_.required } | ForEach-Object name)
    Assert-Contract ($headerNames -contains 'Idempotency-Key' -and $headerNames -contains 'X-Correlation-ID') 'packaged required UUID headers are documented'
    Assert-Contract ($post.responses.'200' -and $post.responses.'201' -and $post.responses.'400' -and $post.responses.'401' -and $post.responses.'403' -and $post.responses.'404' -and $post.responses.'409' -and $post.responses.'500' -and $post.responses.'503') 'packaged request responses are complete'
    $packagedStaffUi = $packagedTool + "`n" + $packagedStaffJs
    Assert-Contract ($packagedTool.Contains($phase2Boundary) -and $packagedTool.Contains('does not create a loan or grant digital access')) 'packaged staff tool states the Phase 2B decision-only boundary'
    Assert-Contract ($packagedStaffJs.Contains("approve.textContent = 'Approve'") -and $packagedStaffJs.Contains("reject.textContent = 'Reject'") -and $packagedStaffJs.Contains("request.status === 'PENDING'")) 'packaged staff tool exposes Approve and Reject only for pending requests'
    Assert-Contract ($packagedStaffJs.Contains("DECISION_PATH = '/requests/'") -and $packagedStaffJs.Contains("'/decision'") -and $packagedStaffJs.Contains("method: 'POST'") -and $packagedStaffJs.Contains("credentials: 'same-origin'")) 'packaged staff decisions use only the same-origin verified REST endpoint'
    Assert-Contract ($packagedStaffJs.Contains("'X-Correlation-ID': correlationId") -and $packagedStaffJs.Contains('expected_row_version: version') -and $packagedStaffJs.Contains('window.crypto.randomUUID()') -and $packagedStaffJs.Contains('window.crypto.getRandomValues(bytes)')) 'packaged staff decisions use a fresh secure correlation UUID and row version'
    Assert-Contract (-not $packagedStaffJs.Contains('innerHTML') -and -not $packagedStaffJs.Contains('Authorization') -and -not $packagedStaffUi.Contains('portal_service_account_ids')) 'packaged staff UI contains no unsafe HTML, authorization header, or portal allowlist'
    foreach ($control in @('Create','Delete','Return','Renew','Revoke','Edit','Issue')) {
        Assert-Contract (-not ($packagedTool -match ">\s*$control(?: Request)?\s*<") -and -not ($packagedStaffJs -match "\.textContent\s*=\s*['""]$control(?: Request)?['""]")) "packaged staff tool has no $control write control"
    }
    Assert-Contract ($packagedConfigure.Contains('name="csrf_token"')) 'packaged configuration includes CSRF token field'
    Assert-Contract (-not ($packagedConfigure -match 'name="[^"]*(?:client_secret|bearer|password|database|dsn)[^"]*"')) 'packaged configuration requests no credentials'
    Assert-Contract (-not ($productionText -match '(?<![A-Za-z0-9_])[A-Za-z]:\\[^\\\r\n]{2,}\\|/var/lib/koha/library|Authorization:\s*Bearer\s+[A-Za-z0-9._~+/-]{12,}|(?:client_secret|password)\s*(?:=>|=)\s*[''"][^''"]+[''"]')) 'packaged production files contain no paths or literal credentials'
    $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedKpz).Hash.ToLowerInvariant()
    Write-Output "SHA-256: $sha256"
}
Write-Output 'Source/package validation passed'
