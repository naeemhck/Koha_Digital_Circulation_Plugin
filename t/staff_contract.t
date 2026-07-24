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
my $main = slurp("$bundle.pm");
my $api  = slurp("$bundle/openapi.json");

for (
    'Pending Requests',
    'Approved Requests',
    'Rejected Requests',
    'Cancelled Requests',
    'Active Digital Loans',
    'Renewal Requests',
    'Returned Loans',
    'Expired Loans',
    'Revoked Loans',
    'Audit Events',
    'Phase 2C — request decisions and loan issuance'
) {
    like $tool, qr/\Q$_\E/, $_;
}

like $tool, qr/Approval alone does not create a loan/,
    'staff page states approval alone creates no loan';
like $tool, qr/does not grant protected-PDF reader access/,
    'staff page states issuance does not grant reader access';
like $tool, qr/<dialog\b[^>]*id="jzl-reject-dialog"/,
    'staff page has a rejection dialog';
like $tool, qr/<textarea\b[^>]*maxlength="4096"[^>]*required/,
    'rejection reason is required and length bounded';
like $tool, qr/id="jzl-status"[^>]*aria-live="polite"/,
    'staff page has a polite live status region';
like $tool, qr/id="jzl-reject-error"[^>]*role="alert"/,
    'rejection validation has an alert region';

like $js, qr/approve\.textContent = 'Approve'/,
    'pending request JavaScript creates an Approve control';
like $js, qr/reject\.textContent = 'Reject'/,
    'pending request JavaScript creates a Reject control';
like $js, qr/request\.status === 'PENDING'/,
    'decision controls are pending-only';
like $js,
    qr{DECISION_PATH \+\s*encodeURIComponent\(String\(id\)\) \+\s*'/decision'},
    'staff decisions use only the verified decision endpoint';
like $js, qr/credentials: 'same-origin'/,
    'staff REST requests use same-origin credentials';
like $js, qr/'X-Correlation-ID': correlationId/,
    'staff decisions send a correlation UUID header';
like $js, qr/expected_row_version: version/,
    'staff decisions use the displayed authoritative row version';
like $js, qr/decision: decision/,
    'staff decisions send only the selected decision';

unlike $js, qr/\bAuthorization\b|\bBearer\b|\bclient_secret\b|\baccess_token\b/,
    'staff UI contains no credentials or authorization header';
unlike $js, qr/\bportal_service_account_ids\b|\bSERVICE_ACCOUNT_NOT_AUTHORIZED\b/,
    'staff UI does not use portal allowlisting';
unlike $js, qr/\binnerHTML\b|\beval\s*\(|setTimeout\s*\(\s*['"]/,
    'staff UI avoids unsafe HTML and executable strings';
unlike $js, qr{https?://|192\.168\.|/var/lib/koha|[A-Za-z]:\\},
    'staff UI has no remote host or filesystem path';
unlike $tool . $js,
    qr/>\s*(?:Renew|Return|Revoke|Delete|Modify|Edit|Create)\s*</,
    'no unrelated staff write control exists';
like $js, qr/issue\.textContent = 'Issue Loan'/,
    'staff UI exposes Issue Loan for eligible approved requests';
my @write_methods = $js =~ /method:\s*'([^']+)'/g;
is_deeply \@write_methods, [ 'POST', 'POST' ],
    'staff UI write requests are exactly decision and issuance POSTs';
unlike $js,
    qr/\b(?:createRenewal|grantAccess|grantEntitlement|activateReader)\b/i,
    'staff UI creates no renewal, entitlement, or reader state';
like $js, qr/submitIssuance\(/,
    'staff issuance goes through the dedicated issuance submit helper';

like $main,
    qr/haspermission\(\s*\$userenv->\{id\},\s*\{\s*circulate\s*=>\s*'circulate_remaining_permissions'/s,
    'staff tool authorization remains the established circulation permission';
like $api,
    qr{"circulate"\s*:\s*"circulate_remaining_permissions"},
    'REST authorization remains the established circulation permission';

done_testing;
