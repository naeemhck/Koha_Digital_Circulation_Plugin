package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanExpiryApplication;

use Modern::Perl;

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LifecyclePolicy;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanLifecycleService;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;

sub new {
    my ( $class, %args ) = @_;
    my $plugin = $args{plugin};
    return bless {
        authorization => $args{authorization}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization->new(
                plugin => $plugin
            ),
        service => $args{service}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanLifecycleService->new(
                table_resolver => sub { $plugin->table(shift) },
                policy => Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LifecyclePolicy->new(
                    plugin => $plugin
                ),
            ),
    }, $class;
}

sub expire_due {
    my ( $self, %args ) = @_;
    my $auth = eval { $self->{authorization}->authorize_controller($args{controller}) };
    return { ok => 0, code => 'INTERNAL_ERROR' } unless ref($auth) eq 'HASH';
    return { ok => 0, code => $auth->{code} || 'SERVICE_ACCOUNT_NOT_AUTHORIZED' }
        unless $auth->{allowed};
    return $self->{service}->expire_due(
        actor_id       => $auth->{actor_id},
        correlation_id => $args{correlation_id},
    );
}

1;
