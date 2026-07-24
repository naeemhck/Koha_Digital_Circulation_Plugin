use Modern::Perl;
use Test::More;
use JSON qw(decode_json);

my $root = $ENV{JZL_PLUGIN_ROOT} // '.';
my $bundle = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation';
my $main = "$root/$bundle.pm";
ok -f $main, 'main module exists';
open my $main_fh, '<', $main or die $!;
my $source = do { local $/; <$main_fh> };
like $source, qr/package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation/, 'namespace';
like $source, qr/our \$VERSION\s*=\s*'0\.2\.0'/, 'Phase 2A plugin version';
like $source, qr/minimum_version\s*=>\s*'26\.05\.00\.000'/, 'minimum version';
like $source, qr/our \$SCHEMA_VERSION\s*=\s*1/, 'schema version remains 1';
is scalar( () = $source =~ /use base qw\(Koha::Plugins::Base\)/g ), 1, 'single base-class declaration';
unlike $source, qr/use parent/, 'no conflicting parent declaration';
ok -f "$root/$bundle/tool.tt", 'tool.tt is at bundle root';
ok -f "$root/$bundle/configure.tt", 'configure.tt is at bundle root';
ok !-f "$root/$bundle/templates/tool.tt", 'no duplicate template location';
ok !-f "$root/$bundle/templates/configure.tt", 'no obsolete configuration template location';
open my $manifest_fh, '<', "$root/MANIFEST" or die $!;
my @manifest = grep { length } map { chomp; $_ } <$manifest_fh>;
ok scalar grep( { $_ eq "$bundle/tool.tt" } @manifest ), 'bundle-root tool.tt is in MANIFEST';
ok scalar grep( { $_ eq "$bundle/configure.tt" } @manifest ), 'bundle-root configure.tt is in MANIFEST';
for my $runtime (
    "$bundle.pm",
    "$bundle/openapi.json",
    "$bundle/Service/EbookContentAdapter.pm",
    "$bundle/Service/EbookContentEligibility.pm",
    "$bundle/Service/PortalServiceAuthorization.pm",
    "$bundle/Service/PortalRequestApplication.pm",
    "$bundle/Repository/RequestRepository.pm",
    "$bundle/Repository/EventRepository.pm",
    "$bundle/Service/RequestDecisionService.pm",
    "$bundle/Service/RequestService.pm",
    "$bundle/Service/LoanIssuanceService.pm",
    "$bundle/Service/ConfiguredLoanPeriodPolicy.pm",
    "$bundle/Service/StaffDecisionAuthorization.pm",
    "$bundle/Service/StaffRequestDecisionApplication.pm",
    "$bundle/Service/StaffLoanIssuanceApplication.pm",
    "$bundle/Service/PortalLoanReadApplication.pm",
    "$bundle/Controller/Patrons.pm",
    "$bundle/Repository/LoanRepository.pm",
    "$bundle/static/css/jzl-digital-circulation.css",
    "$bundle/static/js/jzl-digital-circulation.js"
    ) {
    ok scalar grep( { $_ eq $runtime } @manifest ), "$runtime is in MANIFEST";
    ok -f "$root/$runtime", "$runtime exists";
}
open my $api_fh, '<', "$root/$bundle/openapi.json" or die $!;
my $api_text = do { local $/; <$api_fh> };
my $api = eval { decode_json($api_text) };
ok $api, 'OpenAPI JSON parses';
my @write_routes;
for my $path ( sort keys %{$api} ) {
    for my $method ( sort keys %{ $api->{$path} } ) {
        push @write_routes, "$method $path" if $method =~ /\A(?:post|put|patch|delete)\z/i;
    }
}
is_deeply(
    \@write_routes,
    [
        'post /requests',
        'post /requests/{request_id}/decision',
        'post /requests/{request_id}/issue',
    ],
    'exactly three POST write routes exist including staff issuance'
);
is $api->{'/requests/{request_id}/issue'}{post}{operationId},
    'jzlIssueDigitalLoan',
    'issuance operation ID is packaged in OpenAPI';
is $api->{'/patrons/{patron_id}/loans'}{get}{operationId},
    'jzlListPatronDigitalLoans',
    'portal loan-read operation ID is packaged in OpenAPI';
ok -f "$root/$bundle/Service/StaffLoanIssuanceApplication.pm",
    'StaffLoanIssuanceApplication remains packaged';
ok -f "$root/$bundle/Service/ConfiguredLoanPeriodPolicy.pm",
    'ConfiguredLoanPeriodPolicy remains packaged';
ok -f "$root/$bundle/Service/PortalLoanReadApplication.pm",
    'PortalLoanReadApplication is packaged';
ok -f "$root/$bundle/Controller/Patrons.pm",
    'Patrons controller is packaged';
ok -f "$root/$bundle/Controller/Requests.pm",
    'Requests controller remains packaged';
open my $controller_fh, '<', "$root/$bundle/Controller/Requests.pm" or die $!;
my $controller_source = do { local $/; <$controller_fh> };
like $controller_source, qr/sub issue\b/,
    'controller issue action is packaged';
open my $patrons_fh, '<', "$root/$bundle/Controller/Patrons.pm" or die $!;
my $patrons_source = do { local $/; <$patrons_fh> };
like $patrons_source, qr/sub list_loans\b/,
    'patrons controller exposes list_loans';
like $patrons_source, qr/PortalLoanReadApplication/,
    'patrons controller uses PortalLoanReadApplication';
unlike $patrons_source, qr/StaffDecisionAuthorization/,
    'patrons controller does not use staff authorization';
ok !exists $api->{'/issue'},
    'OpenAPI has no top-level /issue route';
ok !exists $api->{'/access'} && !exists $api->{'/reader'},
    'OpenAPI has no access or reader routes';
ok !exists $api->{'/my-loans'} && !exists $api->{'/loans/sync'},
    'OpenAPI has no portal sync convenience routes';
my @forbidden_writes;
for my $path ( sort keys %{$api} ) {
    next unless $path =~ m{\A/(?:loans|renewals|access|reader|return|revoke)(?:/|\z)};
    for my $method ( sort keys %{ $api->{$path} } ) {
        push @forbidden_writes, "$method $path"
            if $method =~ /\A(?:post|put|patch|delete)\z/i;
    }
}
is_deeply \@forbidden_writes, [],
    'OpenAPI has no loan, renewal, access, reader, return, or revoke write routes';
ok exists $api->{'/assets/{asset}'}, 'asset route exists';
like $source,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-css},
    'CSS logical URL matches route namespace';
like $source,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-js},
    'JavaScript logical URL matches route namespace';
unlike $source,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation\.css},
    'broken extension-bearing CSS URL is not referenced';
unlike $source,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation\.js},
    'broken extension-bearing JavaScript URL is not referenced';
open my $tool_fh, '<', "$root/$bundle/tool.tt" or die $!;
my $tool = do { local $/; <$tool_fh> };
open my $js_fh, '<', "$root/$bundle/static/js/jzl-digital-circulation.js" or die $!;
my $staff_js = do { local $/; <$js_fh> };
like $tool,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-js},
    'packaged staff template references extensionless JavaScript asset';
like $tool,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-css},
    'packaged staff template references extensionless CSS asset';
unlike $tool,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation\.js},
    'packaged staff template omits broken JavaScript asset URL';
unlike $tool,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation\.css},
    'packaged staff template omits broken CSS asset URL';
like $tool, qr/Phase 2C — request decisions and loan issuance/,
    'packaged staff template describes Phase 2C decisions and issuance';
like $tool, qr/Approval alone does not create a loan/,
    'packaged staff template states approval alone creates no loan';
like $staff_js, qr/approve\.textContent = 'Approve'/,
    'packaged staff JavaScript provides Approve';
like $staff_js, qr/reject\.textContent = 'Reject'/,
    'packaged staff JavaScript provides Reject';
like $staff_js, qr/issue\.textContent = 'Issue Loan'/,
    'packaged staff JavaScript provides Issue Loan';
like $staff_js, qr/request\.status === 'PENDING'/,
    'packaged staff decision controls are pending-only';
like $staff_js, qr/canIssueRequest\(request\)/,
    'packaged staff issuance controls are eligibility-gated';
like $staff_js, qr/method: 'POST'/,
    'packaged staff writes use POST';
like $staff_js, qr/credentials: 'same-origin'/,
    'packaged staff writes use same-origin credentials';
like $staff_js, qr/'X-Correlation-ID': correlationId/,
    'packaged staff writes send correlation ID';
like $staff_js, qr/expected_row_version: version/,
    'packaged staff decision uses row version';
like $staff_js, qr{encodeURIComponent\(String\(id\)\) \+\s*'/issue'},
    'packaged staff issuance uses the verified issue endpoint';
unlike $tool . $staff_js,
    qr/>\s*(?:Create|Delete|Return|Renew|Revoke|Edit)\s*</,
    'packaged staff UI has no unrelated write control';
unlike $staff_js, qr/\bAuthorization\b|\bBearer\b|\binnerHTML\b/,
    'packaged staff UI has no authorization header or unsafe HTML';
done_testing;
