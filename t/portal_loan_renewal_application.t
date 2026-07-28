use Modern::Perl;
use Test::More;
use lib '.';

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanRenewalApplication;

{
    package Local::RenewalAuthorization;
    sub new { bless { result => $_[1], calls => [] }, $_[0] }
    sub authorize_controller {
        my ( $self, $controller ) = @_;
        push @{ $self->{calls} }, $controller;
        return { %{ $self->{result} } };
    }

    package Local::RenewalService;
    sub new { bless { result => $_[1], calls => [] }, $_[0] }
    sub renew {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, \%args;
        return $self->{result};
    }
}

my $controller = bless {}, 'Local::Controller';
my $success = { ok => 1, loan => { loan_id => 11 } };
my $authorization = Local::RenewalAuthorization->new({
    allowed  => 1,
    actor_id => 53,
    code     => undef,
});
my $service = Local::RenewalService->new($success);
my $application =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanRenewalApplication
    ->new(
        authorization => $authorization,
        service       => $service,
    );

my %canonical = (
    controller           => $controller,
    loan_id              => 11,
    patron_id            => 57,
    portal_request_id    => '0d1d1563-3413-456a-a6ad-d76ac09b3166',
    expected_row_version => 1,
    correlation_id       => 'db421a13-f74a-4388-a681-897ec46156f4',
);
my $result = $application->renew(%canonical);

is_deeply $result, $success, 'valid canonical renewal reaches the lifecycle service';
is scalar @{ $authorization->{calls} }, 1, 'authorization runs exactly once';
is $authorization->{calls}[0], $controller,
    'controller context is the trusted authentication source';
is scalar @{ $service->{calls} }, 1, 'lifecycle service is called exactly once';
is_deeply(
    $service->{calls}[0],
    {
        ( map { $_ => $canonical{$_} }
            qw(loan_id patron_id portal_request_id expected_row_version correlation_id) ),
        actor_id => 53,
    },
    'canonical command preserves every trusted field and authenticated actor_id'
);
ok defined $service->{calls}[0]{actor_id},
    'regression: authenticated actor_id is not consumed by map precedence';
ok !exists $service->{calls}[0]{controller},
    'controller object is not passed into the lifecycle command';

my $denied_service = Local::RenewalService->new($success);
my $denied =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanRenewalApplication
    ->new(
        authorization => Local::RenewalAuthorization->new({
            allowed => 0,
            code    => 'SERVICE_ACCOUNT_NOT_AUTHORIZED',
        }),
        service => $denied_service,
    )->renew(%canonical);
is_deeply(
    $denied,
    { ok => 0, code => 'SERVICE_ACCOUNT_NOT_AUTHORIZED' },
    'authorization failure remains safely classified'
);
is scalar @{ $denied_service->{calls} }, 0,
    'denied command never reaches lifecycle processing';

done_testing;
