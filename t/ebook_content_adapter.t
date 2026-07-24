use Modern::Perl;
use Test::More;
use lib '.';

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentAdapter;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility;

{
    package Local::Biblio;
    sub new   { bless { title => $_[1] }, $_[0] }
    sub title { return $_[0]->{title} }

    package Local::Upload;
    sub new      { bless { id => $_[1], filename => $_[2] }, $_[0] }
    sub id       { return $_[0]->{id} }
    sub filename { return $_[0]->{filename} }

    package Local::EbookContent;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, calls => [] }, $class;
    }
    sub get_metadata {
        return {
            version => $_[0]->{version} // '0.1.2',
        };
    }
    sub validated_mapping {
        my ( $self, $biblio_id ) = @_;
        push @{ $self->{calls} }, $biblio_id;
        die $self->{error} if defined $self->{error};
        return $self->{response};
    }

    package Local::MissingMethod;
    sub new          { bless {}, $_[0] }
    sub get_metadata { return { version => '0.1.2' } }
}

my $adapter_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentAdapter';
my $eligibility_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility';

sub validated_result {
    my (%args) = @_;
    return {
        mapping => {
            biblionumber => $args{biblionumber} // 456,
            active       => 1,
            sha256_cache => 'b' x 64,
        },
        biblio => Local::Biblio->new('Canonical title'),
        upload => Local::Upload->new(81, 'protected.pdf'),
        size   => 30_097,
    };
}

sub adapter_for {
    my ($plugin) = @_;
    return $adapter_class->new( plugin_loader => sub { return $plugin } );
}

my $plugin = Local::EbookContent->new( response => validated_result() );
my $adapter = adapter_for($plugin);
my $normalized = $adapter->lookup_biblio_content( biblio_id => 456 );
is_deeply $plugin->{calls}, [456], 'exact numeric biblionumber is passed to EbookContent';
is_deeply(
    $normalized,
    {
        available => 1,
        found     => 1,
        biblio_id => 456,
        title     => 'Canonical title',
        file      => {
            upload_id         => 81,
            original_filename => 'protected.pdf',
            file_size_bytes   => 30_097,
            mime_type         => 'application/pdf',
            category          => 'EBOOK_PDF',
            public            => 0,
            permanent         => 1,
            active            => 1,
            sha256            => 'b' x 64,
        },
    },
    'validated_mapping result is normalized to the eligibility metadata contract'
);
is_deeply(
    $adapter->integration_status,
    {
        available => 1,
        class     => 'Koha::Plugin::Com::Ecombranding::EbookContent',
        version   => '0.1.2',
        method    => 'validated_mapping',
    },
    'adapter reports the verified dependency contract'
);

my $eligibility = $eligibility_class->new(
    biblio_lookup  => sub { return { biblionumber => $_[0] } },
    content_adapter => $adapter,
);
my $eligible = $eligibility->check_biblio_eligibility( biblio_id => 456 );
ok $eligible->{eligible}, 'eligibility accepts valid production-adapter normalization';
is $eligible->{content_id}, 81, 'eligibility preserves normalized upload identifier';

for my $case (
    [
        'plugin unavailable',
        $adapter_class->new( plugin_loader => sub { return } ),
        'PLUGIN_UNAVAILABLE',
        'CONTENT_LOOKUP_UNAVAILABLE',
    ],
    [
        'loader exception',
        $adapter_class->new( plugin_loader => sub { die 'C:\secret\plugin.pm password=bad' } ),
        'PLUGIN_UNAVAILABLE',
        'CONTENT_LOOKUP_UNAVAILABLE',
    ],
    [
        'method unavailable',
        adapter_for( Local::MissingMethod->new ),
        'METHOD_UNAVAILABLE',
        'CONTENT_LOOKUP_UNAVAILABLE',
    ],
    [
        'metadata not found',
        adapter_for( Local::EbookContent->new( error => 'MAPPING_NOT_FOUND at /private/plugin.pm line 7' ) ),
        'METADATA_NOT_FOUND',
        undef,
    ],
    [
        'dependency exception',
        adapter_for( Local::EbookContent->new( error => 'DBI password=bad Bearer token at /private/plugin.pm' ) ),
        'LOOKUP_EXCEPTION',
        'CONTENT_LOOKUP_UNAVAILABLE',
    ],
    [
        'malformed response',
        adapter_for( Local::EbookContent->new( response => [] ) ),
        'MALFORMED_METADATA',
        undef,
    ],
    [
        'biblio mismatch',
        adapter_for( Local::EbookContent->new( response => validated_result( biblionumber => 457 ) ) ),
        'BIBLIO_MISMATCH',
        undef,
    ],
) {
    my ( $label, $case_adapter, $failure, $reason ) = @{$case};
    my $result = $case_adapter->lookup_biblio_content( biblio_id => 456 );
    is $result->{failure}, $failure, "$label has a safe failure classification";
    is $result->{reason}, $reason, "$label has the expected availability outcome";
    my $serialized = join ' ', map { defined $_ && !ref($_) ? $_ : '' } values %{$result};
    unlike $serialized, qr{(?:[A-Za-z]:[\\/]|/private/|DBI|password|Bearer|token|secret)}i,
        "$label does not disclose dependency details";
}

for my $invalid_id ( undef, '', 0, -1, '1.5', '456x', [], {} ) {
    my $never_called = 0;
    my $invalid_adapter = $adapter_class->new(
        plugin_loader => sub {
            $never_called++;
            return $plugin;
        }
    );
    my $result = $invalid_adapter->lookup_biblio_content( biblio_id => $invalid_id );
    is $result->{failure}, 'MALFORMED_METADATA', 'invalid biblio ID fails safely';
    is $never_called, 0, 'invalid biblio ID never reaches plugin discovery';
}

my $inactive = adapter_for( Local::EbookContent->new( error => 'MAPPING_INACTIVE' ) )
    ->lookup_biblio_content( biblio_id => 456 );
ok $inactive->{disabled}, 'inactive dependency mapping is explicitly disabled';

my $stale = adapter_for( Local::EbookContent->new( error => 'UPLOAD_NOT_FOUND' ) )
    ->lookup_biblio_content( biblio_id => 456 );
ok $stale->{invalid}, 'stale dependency mapping is invalid';

open my $adapter_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/EbookContentAdapter.pm'
    or die $!;
my $source = do { local $/; <$adapter_fh> };
unlike $source, qr{https?://|OAuth|Authorization:\s*Bearer}i, 'adapter contains no HTTP or OAuth client';
unlike $source, qr{(?:/var/lib/koha|[A-Za-z]:[\\/]|KohaPluginWorkspace)}, 'adapter contains no deployed or Windows path';
unlike $source, qr{\bSELECT\b|\bFROM\b.*ebook}i, 'adapter contains no private-table query';
like $source, qr/Koha::Plugins->get_enabled_plugins/, 'adapter uses enabled Koha plugin discovery';

open my $api_fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json'
    or die $!;
my $api_source = do { local $/; <$api_fh> };
like $api_source, qr/"post"\s*:/i, 'POST /requests is exposed by the HTTP adapter unit';

done_testing;
