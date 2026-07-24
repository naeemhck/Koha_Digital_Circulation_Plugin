package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentAdapter;

use Modern::Perl;
use Scalar::Util qw(blessed);

use constant DEPENDENCY_CLASS   => 'Koha::Plugin::Com::Ecombranding::EbookContent';
use constant DEPENDENCY_VERSION => '0.1.2';

sub new {
    my ( $class, %args ) = @_;
    return bless {
        plugin_loader => $args{plugin_loader} || \&_load_installed_plugin,
    }, $class;
}

sub lookup_biblio_content {
    my ( $self, %args ) = @_;
    my $biblio_id = $args{biblio_id};
    return _invalid('MALFORMED_METADATA')
        unless _positive_decimal($biblio_id);
    $biblio_id = 0 + $biblio_id;

    my ( $plugin, $load_ok );
    $load_ok = eval {
        $plugin = $self->{plugin_loader}->();
        1;
    };
    return _unavailable('PLUGIN_UNAVAILABLE')
        unless $load_ok && blessed($plugin);
    return _unavailable('METHOD_UNAVAILABLE')
        unless $plugin->can('validated_mapping');

    my $metadata;
    my $metadata_ok = eval {
        $metadata = $plugin->get_metadata;
        1;
    };
    return _unavailable('PLUGIN_UNAVAILABLE')
        unless $metadata_ok
        && ref($metadata) eq 'HASH'
        && ( $metadata->{version} // '' ) eq DEPENDENCY_VERSION;

    my $validated;
    my $lookup_ok = eval {
        $validated = $plugin->validated_mapping($biblio_id);
        1;
    };
    unless ($lookup_ok) {
        my $category = _exception_category($@);
        return {
            available => 1,
            found     => 0,
            failure   => 'METADATA_NOT_FOUND',
        } if $category eq 'METADATA_NOT_FOUND';
        return {
            available => 1,
            found     => 1,
            disabled  => 1,
            failure   => 'CONTENT_DISABLED',
        } if $category eq 'CONTENT_DISABLED';
        return _invalid('MALFORMED_METADATA')
            if $category eq 'INVALID_MAPPING';
        return _unavailable('LOOKUP_EXCEPTION');
    }

    return _invalid('MALFORMED_METADATA')
        unless ref($validated) eq 'HASH'
        && ref( $validated->{mapping} ) eq 'HASH'
        && blessed( $validated->{biblio} )
        && blessed( $validated->{upload} );

    my ( $mapped_biblio_id, $title, $upload_id, $filename );
    my $normalized_ok = eval {
        $mapped_biblio_id = $validated->{mapping}->{biblionumber};
        $title             = $validated->{biblio}->title;
        $upload_id         = $validated->{upload}->id;
        $filename          = $validated->{upload}->filename;
        1;
    };
    return _invalid('MALFORMED_METADATA')
        unless $normalized_ok
        && _positive_decimal($mapped_biblio_id)
        && _positive_decimal($upload_id)
        && defined $title
        && !ref($title)
        && defined $filename
        && !ref($filename)
        && _positive_decimal( $validated->{size} );
    return _invalid('BIBLIO_MISMATCH')
        unless 0 + $mapped_biblio_id == $biblio_id;

    my $sha256 = $validated->{mapping}->{sha256_cache};
    $sha256 = "$sha256" if defined $sha256 && !ref($sha256);

    return {
        available => 1,
        found     => 1,
        biblio_id => 0 + $mapped_biblio_id,
        title     => "$title",
        file      => {
            upload_id         => 0 + $upload_id,
            original_filename => "$filename",
            file_size_bytes   => 0 + $validated->{size},
            mime_type         => 'application/pdf',
            category          => 'EBOOK_PDF',
            public            => 0,
            permanent         => 1,
            active            => 1,
            sha256            => $sha256,
        },
    };
}

sub integration_status {
    my ($self) = @_;
    my $plugin;
    my $loaded = eval {
        $plugin = $self->{plugin_loader}->();
        1;
    };
    return _unavailable('PLUGIN_UNAVAILABLE')
        unless $loaded && blessed($plugin);
    return _unavailable('METHOD_UNAVAILABLE')
        unless $plugin->can('validated_mapping');

    my $metadata;
    my $metadata_ok = eval {
        $metadata = $plugin->get_metadata;
        1;
    };
    return _unavailable('PLUGIN_UNAVAILABLE')
        unless $metadata_ok
        && ref($metadata) eq 'HASH'
        && ( $metadata->{version} // '' ) eq DEPENDENCY_VERSION;

    return {
        available => 1,
        class     => DEPENDENCY_CLASS,
        version   => DEPENDENCY_VERSION,
        method    => 'validated_mapping',
    };
}

sub _load_installed_plugin {
    require Koha::Plugins;
    my @plugins = Koha::Plugins->get_enabled_plugins;
    for my $plugin (@plugins) {
        return $plugin
            if blessed($plugin) && ref($plugin) eq DEPENDENCY_CLASS;
    }
    return;
}

sub _exception_category {
    my ($error) = @_;
    my $message = defined $error ? "$error" : '';
    return 'METADATA_NOT_FOUND'
        if $message =~ /\b(?:MAPPING_NOT_FOUND|BIBLIO_NOT_FOUND)\b/;
    return 'CONTENT_DISABLED'
        if $message =~ /\bMAPPING_INACTIVE\b/;
    return 'INVALID_MAPPING'
        if $message =~ /\b(?:UPLOAD_NOT_FOUND|UPLOAD_INVALID|UPLOAD_UNREADABLE|NOT_PDF|UNSAFE_PATH)\b/;
    return 'LOOKUP_EXCEPTION';
}

sub _positive_decimal {
    my ($value) = @_;
    return defined $value && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
}

sub _unavailable {
    my ($failure) = @_;
    return {
        available => 0,
        reason    => 'CONTENT_LOOKUP_UNAVAILABLE',
        failure   => $failure,
    };
}

sub _invalid {
    my ($failure) = @_;
    return {
        available => 1,
        found     => 1,
        invalid   => 1,
        failure   => $failure,
    };
}

1;
