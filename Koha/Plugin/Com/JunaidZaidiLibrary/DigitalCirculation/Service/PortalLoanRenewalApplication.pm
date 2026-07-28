package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanRenewalApplication;

use Modern::Perl;
use Scalar::Util qw(blessed);

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

sub renew {
    my ( $self, %args ) = @_;
    my $auth = eval { $self->{authorization}->authorize_controller($args{controller}) };
    return { ok => 0, code => 'INTERNAL_ERROR' } unless ref($auth) eq 'HASH';
    return { ok => 0, code => $auth->{code} || 'SERVICE_ACCOUNT_NOT_AUTHORIZED' }
        unless $auth->{allowed};
    return $self->{service}->renew(
        ( map { $_ => $args{$_} }
            qw(loan_id patron_id portal_request_id expected_row_version correlation_id) ),
        actor_id => $auth->{actor_id},
    );
}

1;
