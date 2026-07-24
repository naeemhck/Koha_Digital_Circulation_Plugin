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
my $base = slurp("$bundle/Repository/Base.pm");

like $tool, qr/Phase 2C — request decisions and loan issuance/,
    'staff tool identifies Phase 2C decision and issuance scope';
like $tool, qr/Approval alone does not create a loan/,
    'staff tool preserves approval-versus-issuance separation';
like $tool, qr/does not grant protected-PDF reader access/,
    'staff tool states issuance does not grant reader access';
like $tool, qr/native Koha checkout/,
    'staff tool states issuance is not a native Koha checkout';

like $js, qr/request\.status === 'PENDING'/,
    'Approve and Reject remain pending-only';
like $js, qr/approve\.textContent = 'Approve'/,
    'pending requests still receive Approve';
like $js, qr/reject\.textContent = 'Reject'/,
    'pending requests still receive Reject';
like $js, qr/canIssueRequest\(request\)/,
    'Issue Loan visibility uses an explicit eligibility helper';
like $js, qr/request\.status === 'APPROVED'/,
    'Issue Loan requires APPROVED status';
like $js, qr/loanPresence\(request\) === 'absent'/,
    'Issue Loan requires authoritative absence of a loan';
like $js, qr/issue\.textContent = 'Issue Loan'/,
    'eligible APPROVED requests receive a real Issue Loan button';
like $js, qr/Active digital loan/,
    'existing loans are labelled as active digital loans';
like $js, qr/No issuance actions/,
    'APPROVED requests with a loan suppress Issue Loan';
like $js, qr/Issuance unavailable/,
    'malformed loan summaries fail closed without Issue Loan';
like $js, qr/No decision actions/,
    'non-pending and non-issuable states receive no decision controls';
my ($actions_fn) = $js =~ /function appendRequestActions\((.*?)function /s;
ok defined $actions_fn, 'request actions renderer is extractable';
ok index( $actions_fn, "status === 'PENDING'" ) >= 0
    && index( $actions_fn, "textContent = 'Approve'" ) >
    index( $actions_fn, "status === 'PENDING'" ),
    'Approve controls remain inside the PENDING branch';

like $js, qr/window\.confirm\(/, 'issuance has a confirmation step';
like $js, qr/Issue an ACTIVE digital loan for this approved request\?/,
    'issuance confirmation identifies the action';
like $js, qr/ACTIVE plugin-owned digital loan/,
    'confirmation states an ACTIVE plugin-owned loan is created';
like $js, qr/due date is calculated from configured policy/,
    'confirmation states server-authoritative duration policy';
like $js, qr/Approval alone did not create the loan/,
    'confirmation separates approval from issuance';
like $js, qr/does not grant protected-PDF reader access/,
    'confirmation states no reader access is granted';
like $js, qr/second loan cannot be created/,
    'confirmation states one loan per request';
my ($confirm_issue) = $js =~ /function confirmIssuance\((.*?)function /s;
ok defined $confirm_issue, 'issuance confirmation helper is extractable';
unlike $confirm_issue, qr/prompt\(|<input|textarea/i,
    'issuance confirmation does not collect free-form authority input';

like $js,
    qr{API_BASE \+\s*ISSUE_PATH \+\s*encodeURIComponent\(String\(id\)\) \+\s*'/issue'},
    'issuance uses the verified request issue endpoint';
like $js, qr/method: 'POST'/, 'issuance uses POST';
like $js, qr/credentials: 'same-origin'/,
    'issuance uses same-origin credentials';
like $js, qr/'X-Correlation-ID': correlationId/,
    'issuance sends a fresh correlation UUID';
unlike $js, qr/\bAuthorization\b|\bBearer\b/,
    'issuance does not construct an Authorization header';

like $js, qr/inFlight\[id\] = true/,
    'issuance uses per-row in-memory locking';
like $js, qr/Issuance in progress/,
    'pending issuance is announced to the user';
like $js, qr/issue\.disabled = busy/,
    'Issue Loan uses semantic disabled state while pending';
unlike $js, qr/loan_status\s*=\s*'ACTIVE'[\s\S]{0,120}fetch\(issueEndpoint/,
    'no optimistic ACTIVE loan state is applied before the HTTP response';

like $js, qr/result\.response\.status !== 201/,
    'success requires HTTP 201';
like $js, qr/validIssuanceSuccess\(result\.body, row\)/,
    'success payload is validated before UI mutation';
like $js, qr/body\.status === 'ACTIVE'/,
    'success requires ACTIVE status';
like $js, qr/requestId\(body\) === requestId\(row\)/,
    'success requires matching request ID';
like $js, qr/Digital loan issued successfully\./,
    'success announcement is fixed and polite';
unlike $js,
    qr/(?:protected access granted|PDF unlocked|reader enabled|native Koha checkout created)/i,
    'success message does not claim reader access or native checkout';
like $js, qr/backgroundRefreshRequest\(id\)/,
    'successful issuance triggers authoritative refresh';
like $js, qr/applyIssuanceLoanSummary/,
    'successful issuance updates the safe loan summary';

for my $code (
    qw(
      INVALID_INPUT
      AUTHENTICATION_REQUIRED
      STAFF_NOT_AUTHORIZED
      REQUEST_NOT_FOUND
      REQUEST_NOT_APPROVED
      LOAN_ALREADY_EXISTS
      INVALID_MAPPING
      PROTECTED_CONTENT_UNAVAILABLE
      INVALID_LOAN_PERIOD
      DIGITAL_CIRCULATION_UNAVAILABLE
      INTERNAL_ERROR
    )
  )
{
    like $js, qr/\Q$code\E/, "issuance UI maps $code";
}
like $js, qr/The issuance request was invalid/,
    '400 uses the fixed issuance invalid-input message';
like $js, qr/You are not authorized to issue digital loans/,
    '403 uses the fixed issuance authorization message';
unlike $js, qr/portal.service|portal_service_account/i,
    'issuance errors never mention portal-service classification';
like $js, qr/refreshForIssueCode/,
    'conflict and stale issuance outcomes refresh authoritative state';
like $js, qr/LOAN_ALREADY_EXISTS/,
    'existing-loan conflicts are classified';
my ($finish_issue) = $js =~ /function finishIssuanceFailure\((.*?)function /s;
ok defined $finish_issue, 'issuance failure handler is extractable';
unlike $finish_issue, qr/submitIssuance\(/,
    'issuance failures do not automatically retry';

like $js, qr/issue\.type = 'button'/, 'Issue Loan is a real button';
like $js, qr/Issue digital loan for approved request/,
    'Issue Loan has a request-specific accessible label';
like $js, qr/trigger\.focus\(\)/,
    'cancelled confirmation returns focus to the trigger';
like $js, qr/aria-live/,
    'live-region based announcements remain available';
like $css, qr/\.jzl-issue-actions/,
    'issuance actions have scoped styling';
like $css, qr/\.jzl-loan-summary/,
    'loan summary has scoped styling';
like $css, qr/\.jzl-status-active/,
    'ACTIVE loan status is not communicated only by color';

unlike $js, qr/\binnerHTML\b/, 'issuance UI does not use innerHTML';
unlike $js, qr/localStorage|sessionStorage|document\.cookie/,
    'correlation IDs are not stored in browser storage';
unlike $js, qr{https?://|192\.168\.|[A-Za-z]:\\|/var/lib/koha},
    'issuance UI has no hardcoded host, IP, or filesystem path';
unlike $tool . $js, qr/<script\b[^>]+src=["']https?:/i,
    'UI loads no external script';
unlike $tool . $js,
    qr/>\s*(?:Renew|Return|Revoke|Delete|Modify|Edit|Create)\s*</,
    'no return, renew, revoke, or unrelated write controls exist';
unlike $js,
    qr/(?:grantAccess|openReader|activateReader|reader[_-]?token|content_path)/i,
    'issuance UI adds no reader or protected-content access behavior';
like $js, qr/does not grant protected-PDF reader access/,
    'issuance UI explicitly denies reader-access claims';
my ($submit_issue) = $js =~ /function submitIssuance\((.*?)function /s;
ok defined $submit_issue, 'issuance submit handler is extractable';
unlike $submit_issue, qr/duration_days|default_loan_duration_days|due_at\s*:/,
    'UI does not calculate or submit due dates or durations';
unlike $submit_issue, qr/body:\s*/,
    'issuance submit prefers no request body';
unlike $submit_issue,
    qr/(?:actor_id|patron_id|biblio_id|duration|token|entitlement)\s*:/,
    'issuance request sends no caller authority fields';

like $base,
    qr/LEFT JOIN plugin_jzl_ebook_loans l ON l\.request_id=r\.request_id/,
    'request listing left-joins loans once';
like $base, qr/l\.loan_id AS loan_id/,
    'loan summary exposes loan_id';
like $base, qr/l\.status AS loan_status/,
    'loan summary exposes loan_status';
like $base, qr/l\.started_at AS loan_started_at/,
    'loan summary exposes loan_started_at';
like $base, qr/l\.due_at AS loan_due_at/,
    'loan summary exposes loan_due_at';
like $base, qr/l\.row_version AS loan_row_version/,
    'loan summary exposes loan_row_version';
unlike $base, qr/content_path|entitlement|reader_token|payload_json/,
    'loan summary join exposes no protected-content or entitlement fields';

done_testing;
