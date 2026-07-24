use Modern::Perl;
use Test::More;
use JSON qw(decode_json);
use lib '.';
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentAdapter;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility;

{
    package Local::ContentAdapter;
    sub new { bless { response => $_[1], error => $_[2], calls => [] }, $_[0] }
    sub lookup_biblio_content {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, { %args };
        die $self->{error} if defined $self->{error};
        return $self->{response};
    }
}

my $class = 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility';

sub metadata {
    my (%overrides) = @_;
    my $file_overrides = delete $overrides{file} || {};
    return {
        biblio_id => 456,
        title     => 'Synthetic protected eBook',
        file      => {
            upload_id        => 81,
            original_filename => 'synthetic.pdf',
            mime_type         => 'application/pdf',
            file_size_bytes   => 30_097,
            sha256            => 'a' x 64,
            category          => 'EBOOK_PDF',
            public            => 0,
            permanent         => 1,
            active            => 1,
            %{$file_overrides},
        },
        %overrides,
    };
}

sub service {
    my (%args) = @_;
    my $adapter = $args{adapter} || Local::ContentAdapter->new( $args{response}, $args{error} );
    my $biblio_exists = exists $args{biblio_exists} ? $args{biblio_exists} : 1;
    my @biblio_calls;
    my $lookup = $args{biblio_lookup} || sub {
        push @biblio_calls, $_[0];
        die $args{biblio_error} if $args{biblio_error};
        return $biblio_exists ? { biblionumber => $_[0] } : undef;
    };
    return (
        $class->new( biblio_lookup => $lookup, content_adapter => $adapter ),
        $adapter,
        \@biblio_calls,
    );
}

my ( $eligible_service, $eligible_adapter, $biblio_calls ) = service( response => metadata() );
my $eligible = $eligible_service->check_biblio_eligibility( biblio_id => 456 );
ok $eligible->{eligible}, 'valid protected metadata is eligible';
is $eligible->{biblio_id}, 456, 'eligible result uses Koha biblionumber';
is $eligible->{content_id}, 81, 'eligible result exposes verified upload identifier';
ok !defined $eligible->{code}, 'eligible result has no error code';
is_deeply(
    $eligible->{details},
    { mime_type => 'application/pdf', category => 'EBOOK_PDF', protected => 1 },
    'eligible result contains only safe required metadata'
);
is_deeply $biblio_calls, [456], 'Koha biblio lookup receives exact ID';
is_deeply $eligible_adapter->{calls}, [ { biblio_id => 456 } ], 'content adapter receives exact biblio ID';

for my $case (
    [ undef, 'missing biblio ID' ],
    [ '', 'blank biblio ID' ],
    [ 0, 'zero biblio ID' ],
    [ -1, 'negative biblio ID' ],
    [ '1.5', 'decimal biblio ID' ],
    [ '1e3', 'exponent biblio ID' ],
    [ '123abc', 'alphanumeric biblio ID' ],
    [ 'c43c218e-ff68-4b51-9f55-0f761ea99941', 'portal Ebook UUID' ],
    [ [], 'array biblio ID' ],
    [ {}, 'hash biblio ID' ],
) {
    my ( $invalid_service, $adapter, $calls ) = service( response => metadata() );
    my $result = $invalid_service->check_biblio_eligibility( biblio_id => $case->[0] );
    ok !$result->{eligible}, "$case->[1] is rejected";
    is $result->{code}, 'CONTENT_NOT_ELIGIBLE', "$case->[1] has stable code";
    is $result->{reason}, 'INVALID_BIBLIO_ID', "$case->[1] has stable reason";
    is scalar @{ $adapter->{calls} }, 0, "$case->[1] never reaches content lookup";
    is scalar @{$calls}, 0, "$case->[1] never reaches biblio lookup";
}

my ($missing_biblio_service) = service( response => metadata(), biblio_exists => 0 );
my $missing_biblio = $missing_biblio_service->check_biblio_eligibility( biblio_id => 456 );
ok !$missing_biblio->{eligible}, 'missing Koha biblio is ineligible';
is $missing_biblio->{code}, 'BIBLIO_NOT_FOUND', 'missing biblio has stable code';
is $missing_biblio->{reason}, 'BIBLIO_NOT_FOUND', 'missing biblio has stable reason';

my ($biblio_error_service) = service(
    response => metadata(),
    biblio_error => 'DBI:mysql:database=koha password=secret at C:\koha\Biblio.pm line 9',
);
my $biblio_error = $biblio_error_service->check_biblio_eligibility( biblio_id => 456 );
ok !$biblio_error->{eligible}, 'biblio dependency exception fails closed';
is $biblio_error->{reason}, 'CONTENT_LOOKUP_UNAVAILABLE', 'biblio exception has safe classification';

for my $case (
    [ undef, 'MISSING_PROTECTED_CONTENT', 'missing metadata' ],
    [ { found => 0 }, 'MISSING_PROTECTED_CONTENT', 'explicit missing content' ],
    [ [], 'INVALID_CONTENT_MAPPING', 'non-object dependency response' ],
    [ {}, 'MISSING_PROTECTED_CONTENT', 'missing file object' ],
    [ { file => [] }, 'INVALID_CONTENT_MAPPING', 'malformed file object' ],
) {
    my ($case_service) = service( response => $case->[0] );
    my $result = $case_service->check_biblio_eligibility( biblio_id => 456 );
    ok !$result->{eligible}, "$case->[2] fails closed";
    is $result->{code}, 'CONTENT_NOT_ELIGIBLE', "$case->[2] has stable code";
    is $result->{reason}, $case->[1], "$case->[2] has stable reason";
}

for my $case (
    [ { upload_id => undef }, 'missing content identifier' ],
    [ { upload_id => '81abc' }, 'malformed content identifier' ],
    [ { mime_type => 'text/plain' }, 'wrong MIME type' ],
    [ { file_size_bytes => 0 }, 'empty content' ],
    [ { category => 'OTHER' }, 'wrong upload category' ],
    [ { public => 1 }, 'public content' ],
    [ { permanent => 0 }, 'temporary content' ],
    [ { sha256 => 'not-a-checksum' }, 'invalid checksum' ],
) {
    my ($case_service) = service( response => metadata( file => $case->[0] ) );
    my $result = $case_service->check_biblio_eligibility( biblio_id => 456 );
    ok !$result->{eligible}, "$case->[1] is ineligible";
    is $result->{reason}, 'INVALID_CONTENT_MAPPING', "$case->[1] is an invalid mapping";
}

for my $invalid_top (
    metadata( biblio_id => 457 ),
    metadata( title => '' ),
) {
    my ($case_service) = service( response => $invalid_top );
    my $result = $case_service->check_biblio_eligibility( biblio_id => 456 );
    ok !$result->{eligible}, 'top-level metadata mismatch fails closed';
    is $result->{reason}, 'INVALID_CONTENT_MAPPING', 'top-level mismatch is an invalid mapping';
}

my ($disabled_service) = service( response => metadata( file => { active => 0 } ) );
my $disabled = $disabled_service->check_biblio_eligibility( biblio_id => 456 );
ok !$disabled->{eligible}, 'disabled content is ineligible';
is $disabled->{reason}, 'CONTENT_DISABLED', 'disabled content has stable reason';

my ($unavailable_service) = service(
    response => { available => 0, reason => 'CONTENT_LOOKUP_UNAVAILABLE' }
);
my $unavailable = $unavailable_service->check_biblio_eligibility( biblio_id => 456 );
ok !$unavailable->{eligible}, 'unavailable dependency fails closed';
is $unavailable->{reason}, 'CONTENT_LOOKUP_UNAVAILABLE', 'dependency unavailability has stable reason';

my ($throwing_service) = service(
    error => 'SELECT secret FROM plugin_data; Bearer token at /srv/koha/plugin.pm line 42',
);
my $throwing = $throwing_service->check_biblio_eligibility( biblio_id => 456 );
ok !$throwing->{eligible}, 'dependency exception fails closed';
is $throwing->{code}, 'CONTENT_NOT_ELIGIBLE', 'dependency exception has stable code';
is $throwing->{reason}, 'CONTENT_LOOKUP_UNAVAILABLE', 'dependency exception has safe reason';

for my $result ( $eligible, $missing_biblio, $biblio_error, $disabled, $unavailable, $throwing ) {
    my $serialized = join ' ', map { defined $_ ? $_ : '' } values %{$result};
    unlike $serialized, qr{(?:[A-Za-z]:[\\/]|/srv/|SELECT|DBI:|password|Bearer|token|secret)}i,
        'result does not expose paths, SQL, secrets, DSNs, or tokens';
    ok !exists $result->{original_filename}, 'result does not expose filename';
    ok !exists $result->{sha256}, 'result does not expose checksum';
}

my $unavailable_loader_calls = 0;
my $unavailable_adapter =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentAdapter->new(
    plugin_loader => sub {
        $unavailable_loader_calls++;
        return;
    },
    );
my ($isolated_unavailable_service) = service( adapter => $unavailable_adapter );
my $isolated_unavailable =
    $isolated_unavailable_service->check_biblio_eligibility( biblio_id => 456 );
ok !$isolated_unavailable->{eligible}, 'injected unavailable dependency fails closed';
is $isolated_unavailable->{code}, 'CONTENT_NOT_ELIGIBLE',
    'injected dependency unavailability has stable code';
is $isolated_unavailable->{reason}, 'CONTENT_LOOKUP_UNAVAILABLE',
    'injected dependency unavailability has stable reason';
is_deeply(
    $unavailable_adapter->integration_status,
    {
        available => 0,
        reason    => 'CONTENT_LOOKUP_UNAVAILABLE',
        failure   => 'PLUGIN_UNAVAILABLE',
    },
    'injected adapter reports unavailable discovery safely'
);
is $unavailable_loader_calls, 2,
    'injected loader handles eligibility and status checks without live discovery';

open my $authorization_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/PortalServiceAuthorization.pm'
    or die $!;
my $authorization_source = do { local $/; <$authorization_fh> };
like $authorization_source, qr/portal_service_account_ids/, 'portal service authorization foundation remains present';
like $authorization_source, qr/stash\('koha\.user'\)/, 'portal service actor source remains unchanged';

open my $main_fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation.pm' or die $!;
my $main = do { local $/; <$main_fh> };
like(
    $main,
    qr/sub _staff_allowed \{.*?C4::Context->userenv.*?haspermission\(.*?circulate_remaining_permissions.*?\}/s,
    'existing staff GET/tool authorization remains unchanged'
);

open my $api_fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json' or die $!;
my $api = decode_json( do { local $/; <$api_fh> } );
ok exists $api->{'/requests'}{post}, 'Phase 2A POST route is exposed';

done_testing;
