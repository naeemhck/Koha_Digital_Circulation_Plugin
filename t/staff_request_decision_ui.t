use Modern::Perl;
use Test::More;

my $bundle =
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation';

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

my $tool = slurp("$bundle/tool.tt");
my $js   = slurp("$bundle/static/js/jzl-digital-circulation.js");
my $css  = slurp("$bundle/static/css/jzl-digital-circulation.css");

like $tool,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-js},
    'template references the extensionless JavaScript logical asset URL';
like $tool,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-css},
    'template references the extensionless CSS logical asset URL';
unlike $tool,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation\.js},
    'template does not reference the broken extension-bearing JavaScript URL';
unlike $tool,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation\.css},
    'template does not reference the broken extension-bearing CSS URL';
unlike $tool, qr{(?i)\b(?:https?://|\\\\|[A-Za-z]:\\|/var/|/home/)},
    'template has no hardcoded host, IP, UNC, or filesystem path';

like $js, qr/request\.status === 'PENDING'/,
    'pending requests receive active decision controls';
like $js, qr/No decision actions/,
    'nonpending and unknown states receive no active decision controls';
like $js, qr/canIssueRequest\(request\)/,
    'approved requests without a loan may receive Issue Loan';
for my $status (qw(APPROVED REJECTED CANCELLED)) {
    like $js, qr/\Q$status\E/,
        "$status is represented without an editable status control";
}
unlike $tool . $js, qr/<select\b[^>]*status|contenteditable|statusInput/,
    'the UI has no arbitrary status editor';

like $js, qr/window\.confirm\(/, 'approval has a confirmation step';
like $js, qr/Approve this digital request\?/,
    'approval confirmation identifies the decision';
like $js, qr/does not create a loan or grant digital access/,
    'approval confirmation states the no-loan boundary';
like $js, qr/submitDecision\(row, 'APPROVE', null\)/,
    'approval sends a null reason';

like $tool, qr/<dialog\b[^>]*aria-labelledby="jzl-reject-title"/,
    'rejection uses a labelled dialog';
like $tool, qr/aria-describedby="jzl-reject-description"/,
    'rejection dialog has a description';
like $tool, qr/<label for="jzl-reject-reason">/,
    'rejection textarea has an explicit label';
like $tool, qr/maxlength="4096"/, 'rejection textarea enforces 4096 characters';
like $js, qr/reason\.trim\(\)\.length > 0/,
    'blank rejection reasons are rejected';
like $js, qr/reason\.length <= MAX_REASON_LENGTH/,
    'overlength rejection reasons are rejected without truncation';
like $js, qr/submitDecision\(context\.row, 'REJECT', reason\)/,
    'the exact entered rejection reason is submitted';
unlike $js, qr/(?:slice|substring|substr)\([^)]*MAX_REASON_LENGTH/,
    'rejection reason is never silently truncated';
like $js, qr/window\.prompt\(/,
    'rejection has a native browser fallback when dialog is unavailable';

like $js,
    qr{API_BASE \+\s*DECISION_PATH \+\s*encodeURIComponent\(String\(id\)\) \+\s*'/decision'},
    'request-specific decision endpoint is constructed safely';
like $js, qr/method: 'POST'/, 'decision request uses POST';
like $js, qr/credentials: 'same-origin'/,
    'decision request uses same-origin session credentials';
like $js, qr/'Content-Type': 'application\/json'/,
    'decision request declares JSON';
like $js, qr/'X-Correlation-ID': correlationId/,
    'decision request sends the correlation header';
like $js, qr/body: JSON\.stringify\(command\)/,
    'decision command is JSON encoded';

my ($command) = $js =~ /var command = \{(.*?)\n        \};/s;
ok defined $command, 'decision command literal was located';
like $command, qr/expected_row_version: version/,
    'decision command contains current row version';
like $command, qr/decision: decision/,
    'decision command contains decision';
like $command, qr/reason:/, 'decision command contains reason';
unlike $command,
    qr/actor|patron|biblio|status|timestamp|event|source|loan|renewal/,
    'decision command excludes actor, subject, state, event, and circulation fields';

like $js, qr/window\.crypto\.randomUUID\(\)/,
    'native secure UUID generation is preferred';
like $js, qr/window\.crypto\.getRandomValues\(bytes\)/,
    'secure standards-based UUID fallback is present';
like $js, qr/bytes\[6\].*\| 64/,
    'UUID fallback sets the version nibble';
like $js, qr/bytes\[8\].*\| 128/,
    'UUID fallback sets the RFC variant';
unlike $js, qr/Math\.random|localStorage|sessionStorage/,
    'correlation IDs are neither weakly generated nor stored';

like $js, qr/inFlight\[id\] = true/,
    'selected request is marked in progress before submission';
like $js, qr/approve\.disabled = busy/,
    'Approve is disabled while the row is in progress';
like $js, qr/reject\.disabled = busy/,
    'Reject is disabled while the row is in progress';
like $js, qr/if \(rejectSubmitting \|\| !rejectContext\)/,
    'duplicate rejection form submission is blocked';
like $js, qr/if \(rejectSubmitting\) \{\s*event\.preventDefault\(\)/s,
    'Escape cannot close a submitting rejection dialog';
like $js, qr/Decision in progress…/,
    'in-progress state is communicated in text';

like $js, qr/validDecisionSuccess\(/,
    'success response is validated before updating the row';
like $js, qr/copyPublicDecisionRequest\(/,
    'only public decision fields replace row state';
like $js, qr/backgroundRefreshRequest\(id\)/,
    'success starts an authoritative background refresh';
like $js, qr/Request approved successfully\./,
    'approval success wording is accurate';
like $js, qr/Request rejected successfully\./,
    'rejection success wording is accurate';
unlike $js, qr/Loan created|Access granted|Book issued|Reader activated/,
    'success language never claims loan or access issuance';

for my $code (
    qw(
        INVALID_INPUT INVALID_DECISION INVALID_REASON
        AUTHENTICATION_REQUIRED STAFF_NOT_AUTHORIZED REQUEST_NOT_FOUND
        VERSION_CONFLICT REQUEST_ALREADY_DECIDED INVALID_STATE
        DIGITAL_CIRCULATION_UNAVAILABLE INTERNAL_ERROR
    )
) {
    like $js, qr/\b\Q$code\E\b/, "safe UI mapping exists for $code";
}
like $js, qr/return load\(\)/,
    'conflicts and uncertain outcomes refresh authoritative state';
my ($failure_handler) = $js =~ /(function finishFailure\(.*?)(?=\n    function submitDecision)/s;
ok defined $failure_handler, 'failure handler is present';
unlike $failure_handler // '', qr/submitDecision/,
    'failure handling does not automatically retry a decision';
like $js, qr/throw new Error\('MALFORMED_RESPONSE'\)/,
    'malformed JSON responses fail closed';
like $js, qr/catch\(function \(\) \{\s*delete inFlight\[id\]/s,
    'network failures clear local in-flight state before refresh';
unlike $js,
    qr/(?:textContent|innerHTML)\s*=\s*(?:error\.message|bodyText|responseText)|console\./,
    'raw errors, response bodies, and console output are not rendered';

unlike $js, qr/\binnerHTML\b/, 'all dynamic content avoids innerHTML';
like $js, qr/cell\.textContent = text\(value\)/,
    'dynamic cell content uses textContent';
like $js, qr/rejectLabel\.textContent/,
    'dialog request identification uses textContent';
like $js, qr/rejectError\.textContent/,
    'dialog error content uses textContent';
like $css, qr/white-space:\s*pre-wrap/,
    'rejection reason whitespace is rendered safely';

like $tool, qr/<button type="button"[^>]*id="jzl-reject-cancel">Cancel<\/button>/,
    'dialog has a real Cancel button';
like $tool, qr/<button type="submit"[^>]*id="jzl-reject-submit">Reject Request<\/button>/,
    'dialog has a real submit button';
like $js, qr/approve\.type = 'button'/,
    'Approve is a real non-submit button';
like $js, qr/reject\.type = 'button'/,
    'Reject is a real non-submit button';
like $js, qr/rejectReason\.focus\(\)/,
    'focus moves to the rejection reason';
like $js, qr/rejectContext\.trigger\.focus\(\)/,
    'focus returns to the trigger after cancellation';
like $tool, qr/role="alert" aria-live="assertive"/,
    'validation failures have an assertive live region';
like $tool, qr/role="status" aria-live="polite"/,
    'decision feedback has a polite live region';
like $css, qr/\.jzl-status-badge/,
    'status badges use scoped plugin styling';

unlike $js, qr/\bonclick\s*=|\beval\s*\(|new Function|setTimeout\s*\(\s*['"]/,
    'JavaScript uses listeners and no executable strings';
unlike $tool, qr/\bon(?:click|submit|change|keydown)\s*=/,
    'template contains no inline event handlers';
unlike $tool . $js, qr{<script[^>]+https?://|https?://},
    'UI loads no external script or endpoint';
unlike $js, qr/\bAuthorization\b|\bBearer\b|\bcookie\b/i,
    'UI neither constructs nor exposes authentication material';
unlike $js, qr/portal_service_account_ids|PortalServiceAuthorization/,
    'UI does not use the portal allowlist';
unlike $js, qr/\b(?:SELECT|INSERT|UPDATE|DELETE)\b|plugin_jzl_ebook_/,
    'UI has no direct database access';
unlike $js, qr{/loans(?:/|['"])|/renewals(?:/|['"])},
    'UI invokes no loan or renewal write endpoint';

done_testing;
