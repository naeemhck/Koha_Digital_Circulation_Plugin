package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentAdapter;

use constant REQUIRED_CATEGORY => 'EBOOK_PDF';
use constant REQUIRED_MIME     => 'application/pdf';

sub new {
    my ( $class, %args ) = @_;
    return bless {
        biblio_lookup => $args{biblio_lookup} || \&_default_biblio_lookup,
        content_adapter =>
            $args{content_adapter}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentAdapter->new,
    }, $class;
}

sub check_biblio_eligibility {
    my ( $self, %args ) = @_;
    my $biblio_id = $args{biblio_id};
    return _denied( undef, 'CONTENT_NOT_ELIGIBLE', 'INVALID_BIBLIO_ID' )
        unless _positive_decimal($biblio_id);
    $biblio_id = 0 + $biblio_id;

    my $biblio;
    my $biblio_read = eval {
        $biblio = $self->{biblio_lookup}->($biblio_id);
        1;
    };
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'CONTENT_LOOKUP_UNAVAILABLE' )
        unless $biblio_read;
    return _denied( $biblio_id, 'BIBLIO_NOT_FOUND', 'BIBLIO_NOT_FOUND' )
        unless $biblio;

    my $adapter = $self->{content_adapter};
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'CONTENT_LOOKUP_UNAVAILABLE' )
        unless blessed($adapter) && $adapter->can('lookup_biblio_content');

    my $metadata;
    my $content_read = eval {
        $metadata = $adapter->lookup_biblio_content( biblio_id => $biblio_id );
        1;
    };
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'CONTENT_LOOKUP_UNAVAILABLE' )
        unless $content_read;
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'MISSING_PROTECTED_CONTENT' )
        unless defined $metadata;
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'INVALID_CONTENT_MAPPING' )
        unless ref($metadata) eq 'HASH';
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'CONTENT_LOOKUP_UNAVAILABLE' )
        if exists $metadata->{available} && !$metadata->{available}
        && ( $metadata->{reason} // '' ) eq 'CONTENT_LOOKUP_UNAVAILABLE';
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'MISSING_PROTECTED_CONTENT' )
        if exists $metadata->{found} && !$metadata->{found};
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'INVALID_CONTENT_MAPPING' )
        if $metadata->{invalid};
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'CONTENT_DISABLED' )
        if $metadata->{disabled};

    my $file = $metadata->{file};
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'MISSING_PROTECTED_CONTENT' )
        unless defined $file;
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'INVALID_CONTENT_MAPPING' )
        unless ref($file) eq 'HASH';
    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'CONTENT_DISABLED' )
        if exists $file->{active} && !$file->{active};

    return _denied( $biblio_id, 'CONTENT_NOT_ELIGIBLE', 'INVALID_CONTENT_MAPPING' )
        unless _positive_decimal( $metadata->{biblio_id} )
        && 0 + $metadata->{biblio_id} == $biblio_id
        && defined $metadata->{title}
        && !ref $metadata->{title}
        && $metadata->{title} =~ /\S/
        && _positive_decimal( $file->{upload_id} )
        && defined $file->{original_filename}
        && !ref $file->{original_filename}
        && $file->{original_filename} =~ /\S/
        && ( $file->{mime_type} // '' ) eq REQUIRED_MIME
        && _positive_decimal( $file->{file_size_bytes} )
        && ( $file->{category} // '' ) eq REQUIRED_CATEGORY
        && defined $file->{public}
        && !$file->{public}
        && defined $file->{permanent}
        && $file->{permanent}
        && defined $file->{active}
        && $file->{active}
        && (
            !defined $file->{sha256}
            || ( !ref $file->{sha256} && $file->{sha256} =~ /\A[0-9a-f]{64}\z/i )
        );

    return {
        eligible   => 1,
        biblio_id  => $biblio_id,
        content_id => 0 + $file->{upload_id},
        code       => undef,
        details    => {
            mime_type => REQUIRED_MIME,
            category  => REQUIRED_CATEGORY,
            protected => 1,
        },
    };
}

sub _default_biblio_lookup {
    my ($biblio_id) = @_;
    require Koha::Biblios;
    return Koha::Biblios->find($biblio_id);
}

sub _positive_decimal {
    my ($value) = @_;
    return defined $value && !ref $value && $value =~ /\A[1-9][0-9]*\z/;
}

sub _denied {
    my ( $biblio_id, $code, $reason ) = @_;
    return {
        eligible  => 0,
        biblio_id => $biblio_id,
        code      => $code,
        reason    => $reason,
    };
}

1;
