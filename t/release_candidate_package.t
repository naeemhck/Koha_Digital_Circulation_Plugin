use Modern::Perl;
use Test::More;
use JSON qw(decode_json);
use Digest::SHA qw(sha256_hex);
use IO::Uncompress::Unzip qw($UnzipError);

my $kpz =
    $ENV{JZL_RC_KPZ}
    // 'dist/JunaidZaidiLibrary-DigitalCirculation-v0.2.0-rc1.kpz';
my $bundle = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation';

ok -f $kpz, 'Phase 2A release-candidate KPZ exists'
    or BAIL_OUT("Missing release candidate: $kpz");
like $kpz,
    qr{(?:^|[\\/])JunaidZaidiLibrary-DigitalCirculation-v0\.2\.0-rc1\.kpz\z},
    'release-candidate filename is exact';
ok -s $kpz >= 10_000, 'release candidate is not suspiciously small';

my %members;
my $zip = IO::Uncompress::Unzip->new($kpz)
    or BAIL_OUT("Unreadable release candidate: $UnzipError");
do {
    my $header = $zip->getHeaderInfo;
    my $name = $header->{Name};
    my $content = '';
    my $buffer;
    while ( ( my $read = $zip->read($buffer) ) > 0 ) {
        $content .= $buffer;
    }
    $members{$name} = $content;
} while $zip->nextStream;
$zip->close;

open my $manifest_fh, '<', 'MANIFEST' or die $!;
my @manifest = sort grep { length } map { chomp; $_ } <$manifest_fh>;
my @phase2b_runtime = (
    "$bundle/Service/RequestDecisionService.pm",
    "$bundle/Service/StaffDecisionAuthorization.pm",
    "$bundle/Service/StaffRequestDecisionApplication.pm",
    "$bundle/Service/LoanIssuanceService.pm",
);
my %phase2b_runtime = map { $_ => 1 } @phase2b_runtime;
my @phase2a_manifest = grep { !$phase2b_runtime{$_} } @manifest;
is_deeply [ sort keys %members ], \@phase2a_manifest,
    'frozen Phase 2A archive membership matches the pre-Phase-2B manifest';
for my $phase2b_member (@phase2b_runtime) {
    ok !exists $members{$phase2b_member},
        "frozen Phase 2A archive excludes $phase2b_member";
}

for my $required (
    "$bundle.pm",
    "$bundle/openapi.json",
    "$bundle/tool.tt",
    "$bundle/configure.tt",
    "$bundle/Controller/Requests.pm",
    "$bundle/Service/PortalServiceAuthorization.pm",
    "$bundle/Service/EbookContentAdapter.pm",
    "$bundle/Service/EbookContentEligibility.pm",
    "$bundle/Service/PortalRequestApplication.pm",
    "$bundle/Service/RequestService.pm",
    "$bundle/Repository/RequestRepository.pm",
    "$bundle/Repository/EventRepository.pm",
    "$bundle/static/css/jzl-digital-circulation.css",
    "$bundle/static/js/jzl-digital-circulation.js",
) {
    ok exists $members{$required}, "required runtime member: $required";
}

ok !exists $members{"$bundle/templates/tool.tt"},
    'obsolete tool template path is absent';
ok !exists $members{"$bundle/templates/configure.tt"},
    'obsolete configuration template path is absent';
my @forbidden_members = grep {
    m{(?:^|/)(?:\.git|t|diagnostics|__pycache__)(?:/|$)}i
        || /\.(?:kpz|pyc|db|sqlite|sql|swp)\z/i
        || /(?:^|\/)\.env(?:\.|$)/i
        || /~\z/
} keys %members;
is_deeply \@forbidden_members, [],
    'tests, diagnostics, caches, secrets, dumps, and nested KPZ files are absent';
ok !grep( { !m{\AKoha/} || /\\/ } keys %members ),
    'all archive members use package-relative Unix paths';

like $members{"$bundle.pm"}, qr/our \$VERSION\s*=\s*'0\.2\.0'/,
    'packaged internal plugin version is 0.2.0';
like $members{"$bundle.pm"}, qr/our \$SCHEMA_VERSION\s*=\s*1/,
    'packaged schema version remains 1';
like $members{"$bundle.pm"},
    qr/minimum_version\s*=>\s*'26\.05\.00\.000'/,
    'packaged minimum Koha version remains 26.05.00.000';
like $members{"$bundle/Service/EbookContentAdapter.pm"},
    qr/DEPENDENCY_VERSION\s*=>\s*'0\.1\.2'/,
    'packaged EbookContent dependency remains pinned to 0.1.2';

my $api = eval { decode_json( $members{"$bundle/openapi.json"} ) };
ok $api, 'packaged OpenAPI JSON parses';
my @operation_ids;
my @posts;
for my $path ( sort keys %{$api} ) {
    for my $method ( sort keys %{ $api->{$path} } ) {
        next unless $method =~ /\A(?:get|post|put|patch|delete)\z/i;
        push @operation_ids, $api->{$path}{$method}{operationId};
        push @posts, $path if lc($method) eq 'post';
    }
}
is scalar @operation_ids, scalar keys %{ { map { $_ => 1 } @operation_ids } },
    'packaged operation IDs are unique';
is_deeply \@posts, ['/requests'], 'packaged OpenAPI has exactly POST /requests';
my $post = $api->{'/requests'}{post};
is $post->{operationId}, 'jzlCreateDigitalRequest',
    'packaged request operation ID is correct';
my ($body) = grep {
    ( $_->{in} // '' ) eq 'body' && ( $_->{name} // '' ) eq 'body'
} @{ $post->{parameters} // [] };
ok $body->{required}, 'packaged request body is required';
ok !$body->{schema}{additionalProperties},
    'packaged request body rejects additional properties';
my %headers = map {
    ( $_->{name} // '' ) => $_
} grep {
    ( $_->{in} // '' ) eq 'header'
} @{ $post->{parameters} // [] };
ok $headers{'Idempotency-Key'}{required},
    'packaged Idempotency-Key is required';
ok $headers{'X-Correlation-ID'}{required},
    'packaged X-Correlation-ID is required';
for my $status (qw(200 201 400 401 403 404 409 500 503)) {
    ok exists $post->{responses}{$status},
        "packaged request response $status is documented";
}

for my $control (qw(Approve Reject Create Delete Return Renew Revoke Edit)) {
    unlike $members{"$bundle/tool.tt"}, qr/>\s*\Q$control\E\s*</,
        "packaged operational tool has no $control control";
}
like $members{"$bundle/configure.tt"}, qr/name="csrf_token"/,
    'packaged configuration contains the CSRF token';
my @configuration_inputs =
    $members{"$bundle/configure.tt"} =~ /<input\b[^>]*\bname="([^"]+)"/gi;
is_deeply [ sort @configuration_inputs ],
    [ sort qw(class csrf_token method op portal_service_account_ids) ],
    'packaged configuration accepts only framework controls and the allowlist';
unlike $members{"$bundle/configure.tt"},
    qr/name="[^"]*(?:client_secret|bearer|password|database|dsn)[^"]*"/i,
    'packaged configuration requests no credentials';

my $production = join "\n", map {
    $members{$_}
} grep {
    /\.(?:pm|json|tt|js|css)\z/i
} sort keys %members;
unlike $production,
    qr{(?<![A-Za-z0-9_])[A-Za-z]:\\[^\\\r\n]{2,}\\|/var/lib/koha/library|Authorization:\s*Bearer\s+[A-Za-z0-9._~+/-]{12,}}i,
    'packaged production contains no absolute Windows path, instance path, or usable bearer sample';
unlike $production,
    qr/(?:client_secret|password)\s*(?:=>|=)\s*['"][^'"]+['"]/i,
    'packaged production contains no literal OAuth or database credential';

open my $kpz_fh, '<:raw', $kpz or die $!;
my $bytes = do { local $/; <$kpz_fh> };
my $sha256 = sha256_hex($bytes);
like $sha256, qr/\A[0-9a-f]{64}\z/, 'release-candidate SHA-256 is produced';
diag "RC_SHA256=$sha256";
diag 'RC_MEMBERS=' . scalar keys %members;
diag 'RC_BYTES=' . length($bytes);

done_testing;
