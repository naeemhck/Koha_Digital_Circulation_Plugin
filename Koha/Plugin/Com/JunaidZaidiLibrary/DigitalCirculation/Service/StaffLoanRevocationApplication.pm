package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanRevocationApplication;

use Modern::Perl;

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LifecyclePolicy;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanLifecycleService;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization;

sub new {
    my ( $class, %args ) = @_;
    my $plugin = $args{plugin};
    return bless {
        authorization => $args{authorization}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization->new(
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

sub revoke {
    my ( $self, %args ) = @_;
    my $auth = eval { $self->{authorization}->authorize_controller($args{controller}) };
    return { ok => 0, code => 'INTERNAL_ERROR' } unless ref($auth) eq 'HASH';
    return { ok => 0, code => $auth->{code} || 'STAFF_NOT_AUTHORIZED' }
        unless $auth->{allowed};
    return $self->{service}->revoke(
        map { $_ => $args{$_} }
            qw(loan_id expected_row_version correlation_id reason),
        actor_id => $auth->{actor_id},
    );
}

1;
