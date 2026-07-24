package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;

use constant PERMISSION_MODULE    => 'circulate';
use constant PERMISSION_SUBPERM   => 'circulate_remaining_permissions';

sub new {
    my ( $class, %args ) = @_;
    my $plugin = $args{plugin};
    return bless {
        permission_checker      => $args{permission_checker} || \&_koha_permission,
        service_account_checker =>
            $args{service_account_checker}
            || sub {
                my ($actor_id) = @_;
                return _configured_portal_service_account(
                    $plugin,
                    $actor_id
                );
            },
    }, $class;
}

sub permission {
    return {
        PERMISSION_MODULE() => PERMISSION_SUBPERM(),
    };
}

sub authorize_controller {
    my ( $self, $controller ) = @_;
    return _denied('AUTHENTICATION_REQUIRED')
        unless blessed($controller) && $controller->can('stash');

    my $actor;
    my $authenticated = eval {
        $actor = $controller->stash('koha.user');
        1;
    };
    return _denied('AUTHENTICATION_REQUIRED')
        unless $authenticated && defined $actor;
    # Koha::Patron column accessors are AUTOLOAD-based; UNIVERSAL::can()
    # returns false for them. Resolve identity by calling borrowernumber.
    return _denied('STAFF_NOT_AUTHORIZED') unless blessed($actor);

    my $actor_id;
    my $identified = eval {
        $actor_id = $actor->borrowernumber;
        1;
    };
    return _denied('STAFF_NOT_AUTHORIZED')
        unless $identified && _positive_decimal($actor_id);

    my $is_service_account;
    my $classified = eval {
        $is_service_account =
            $self->{service_account_checker}->( 0 + $actor_id );
        1;
    };
    return _denied('STAFF_NOT_AUTHORIZED')
        unless $classified
        && defined $is_service_account
        && !ref($is_service_account)
        && $is_service_account =~ /\A[01]\z/;
    return _denied('STAFF_NOT_AUTHORIZED') if $is_service_account;

    my $permission;
    my $checked = eval {
        $permission = $self->{permission_checker}->(
            $actor,
            __PACKAGE__->permission
        );
        1;
    };
    return _denied('STAFF_NOT_AUTHORIZED')
        unless $checked && $permission;

    return {
        allowed  => 1,
        actor_id => 0 + $actor_id,
        code     => undef,
    };
}

sub _configured_portal_service_account {
    my ( $plugin, $actor_id ) = @_;
    return unless blessed($plugin) && $plugin->can('retrieve_data');

    my $authorization =
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization->new(
            plugin => $plugin
        );
    my $configuration;
    my $loaded = eval {
        $configuration = $authorization->load_config;
        1;
    };
    return unless $loaded
        && ref($configuration) eq 'HASH'
        && $configuration->{loaded};
    return 0 if $configuration->{disabled};

    my $parsed =
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization->_parse_allowlist(
            $configuration->{value}
        );
    return unless ref($parsed) eq 'HASH' && $parsed->{valid};
    return exists $parsed->{ids}{ 0 + $actor_id } ? 1 : 0;
}

sub _koha_permission {
    my ( $actor, $permission ) = @_;
    return unless blessed($actor);

    # userid is also a Koha::Object AUTOLOAD accessor; do not use can().
    my $userid = eval { $actor->userid };
    return unless defined $userid
        && !ref($userid)
        && length($userid)
        && length($userid) <= 128
        && $userid !~ /[\x00-\x1f\x7f]/;

    require C4::Auth;
    return C4::Auth::haspermission( $userid, $permission );
}

sub _positive_decimal {
    my ($value) = @_;
    return defined $value && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
}

sub _denied {
    my ($code) = @_;
    return {
        allowed  => 0,
        actor_id => undef,
        code     => $code,
    };
}

1;
