package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;

use Modern::Perl;
use Scalar::Util qw(blessed);

use constant CONFIG_KEY => 'portal_service_account_ids';
use constant MAX_ALLOWLIST_LENGTH => 4096;

sub new {
    my ( $class, %args ) = @_;
    return bless { plugin => $args{plugin} }, $class;
}

sub config_key {
    return CONFIG_KEY;
}

sub _parse_allowlist {
    my ( $class, $raw ) = @_;
    return { valid => 0, ids => {}, count => 0 } unless defined $raw && !ref $raw;
    return { valid => 0, ids => {}, count => 0 }
        if length($raw) > MAX_ALLOWLIST_LENGTH;

    my %ids;
    for my $entry ( split /,/, $raw, -1 ) {
        $entry =~ s/\A\s+|\s+\z//g;
        next unless length $entry;
        return { valid => 0, ids => {}, count => 0 }
            unless $entry =~ /\A[1-9][0-9]*\z/;
        $ids{$entry} = 1;
    }

    return { valid => 0, ids => {}, count => 0 } unless keys %ids;
    return {
        valid     => 1,
        ids       => \%ids,
        count     => scalar keys %ids,
        canonical => join(
            ',',
            sort {
                length($a) <=> length($b)
                    || $a cmp $b
            } keys %ids
        ),
    };
}

sub _load_allowlist {
    my ($self) = @_;
    my $plugin = $self->{plugin};
    return { valid => 0, ids => {}, count => 0 } unless blessed($plugin) && $plugin->can('retrieve_data');

    my $raw;
    my $read = eval {
        $raw = $plugin->retrieve_data(CONFIG_KEY);
        1;
    };
    return { valid => 0, ids => {}, count => 0 } unless $read;
    return __PACKAGE__->_parse_allowlist($raw);
}

sub store_config {
    my ( $self, $raw ) = @_;
    return {
        stored   => 0,
        disabled => 0,
        code     => 'INVALID_SERVICE_ACCOUNT_ALLOWLIST',
    } unless defined $raw && !ref $raw && length($raw) <= MAX_ALLOWLIST_LENGTH;

    my $trimmed = $raw;
    $trimmed =~ s/\A\s+|\s+\z//g;
    if ( !length $trimmed ) {
        return $self->_store_canonical( '', 0, 1 );
    }

    my $parsed = __PACKAGE__->_parse_allowlist($raw);
    return {
        stored   => 0,
        disabled => 0,
        code     => 'INVALID_SERVICE_ACCOUNT_ALLOWLIST',
    }
        unless $parsed->{valid};

    return $self->_store_canonical(
        $parsed->{canonical},
        $parsed->{count},
        0
    );
}

sub load_config {
    my ($self) = @_;
    my $plugin = $self->{plugin};
    return {
        loaded => 0,
        code   => 'SERVICE_ACCOUNT_CONFIGURATION_UNAVAILABLE',
    } unless blessed($plugin) && $plugin->can('retrieve_data');

    my $raw;
    my $loaded = eval {
        $raw = $plugin->retrieve_data(CONFIG_KEY);
        1;
    };
    return {
        loaded => 0,
        code   => 'SERVICE_ACCOUNT_CONFIGURATION_UNAVAILABLE',
    } unless $loaded;

    return {
        loaded   => 1,
        value    => '',
        disabled => 1,
        count    => 0,
        code     => undef,
    } unless defined $raw;
    return {
        loaded => 0,
        code   => 'SERVICE_ACCOUNT_CONFIGURATION_UNAVAILABLE',
    } if ref $raw || length($raw) > MAX_ALLOWLIST_LENGTH;
    return {
        loaded   => 1,
        value    => '',
        disabled => 1,
        count    => 0,
        code     => undef,
    } unless $raw =~ /\S/;

    my $parsed = __PACKAGE__->_parse_allowlist($raw);
    return {
        loaded => 0,
        code   => 'SERVICE_ACCOUNT_CONFIGURATION_UNAVAILABLE',
    } unless $parsed->{valid};

    return {
        loaded   => 1,
        value    => $parsed->{canonical},
        disabled => 0,
        count    => $parsed->{count},
        code     => undef,
    };
}

sub _store_canonical {
    my ( $self, $canonical, $count, $disabled ) = @_;
    my $plugin = $self->{plugin};
    return {
        stored   => 0,
        disabled => 0,
        code     => 'SERVICE_ACCOUNT_CONFIGURATION_UNAVAILABLE',
    } unless blessed($plugin) && $plugin->can('store_data');

    my $stored = eval {
        $plugin->store_data( { CONFIG_KEY() => $canonical } );
        1;
    };
    return {
        stored   => 0,
        disabled => 0,
        code     => 'SERVICE_ACCOUNT_CONFIGURATION_UNAVAILABLE',
    } unless $stored;

    return {
        stored   => 1,
        disabled => $disabled ? 1 : 0,
        count    => $count,
        code     => undef,
    };
}

sub authorize_controller {
    my ( $self, $controller ) = @_;
    return _denied( 'AUTHENTICATION_REQUIRED', undef, 'AUTHENTICATED_ACTOR_MISSING' )
        unless blessed($controller) && $controller->can('stash');

    my $actor;
    my $read = eval {
        $actor = $controller->stash('koha.user');
        1;
    };
    return _denied( 'AUTHENTICATION_REQUIRED', undef, 'AUTHENTICATED_ACTOR_MISSING' )
        unless $read && defined $actor;

    return _denied( 'SERVICE_ACCOUNT_NOT_AUTHORIZED', undef, 'ACTOR_ID_MISSING' )
        unless blessed($actor) && $actor->can('borrowernumber');

    my $actor_id;
    my $identified = eval {
        $actor_id = $actor->borrowernumber;
        1;
    };
    return _denied( 'SERVICE_ACCOUNT_NOT_AUTHORIZED', undef, 'ACTOR_ID_MISSING' )
        unless $identified && defined $actor_id && !ref $actor_id
        && $actor_id =~ /\A[1-9][0-9]*\z/;

    my $allowlist = $self->_load_allowlist;
    return _denied( 'SERVICE_ACCOUNT_NOT_AUTHORIZED', 0 + $actor_id, 'CONFIGURATION_DENIES_ALL' )
        unless $allowlist->{valid};
    return _denied( 'SERVICE_ACCOUNT_NOT_AUTHORIZED', 0 + $actor_id, 'ACTOR_NOT_ALLOWLISTED' )
        unless exists $allowlist->{ids}{$actor_id};

    return {
        allowed  => 1,
        actor_id => 0 + $actor_id,
        code     => undef,
    };
}

sub _denied {
    my ( $code, $actor_id, $reason ) = @_;
    return {
        allowed  => 0,
        actor_id => $actor_id,
        code     => $code,
        reason   => $reason,
    };
}

1;
