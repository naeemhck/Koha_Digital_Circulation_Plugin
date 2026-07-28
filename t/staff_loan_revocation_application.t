use Modern::Perl;
use Test::More;
use lib '.';

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanRevocationApplication;

{
    package Local::RevocationAuthorization;
    sub new { bless { result => $_[1], calls => [] }, $_[0] }
    sub authorize_controller {
        my ( $self, $controller ) = @_;
        push @{ $self->{calls} }, $controller;
        return { %{ $self->{result} } };
    }

    package Local::RevocationService;
    sub new { bless { result => $_[1], calls => [] }, $_[0] }
    sub revoke {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, \%args;
        return $self->{result};
    }
}

my $controller = bless {}, 'Local::StaffController';
my $success = { ok => 1, loan => { loan_id => 5 } };
my $authorization = Local::RevocationAuthorization->new({
    allowed  => 1,
    actor_id => 61,
    code     => undef,
});
my $service = Local::RevocationService->new($success);
my $application =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanRevocationApplication
    ->new(
        authorization => $authorization,
        service       => $service,
    );

my %canonical = (
    controller           => $controller,
    loan_id              => 5,
    expected_row_version => 1,
    correlation_id       => 'aa421a13-f74a-4388-a681-897ec46156f4',
    reason               => 'Controlled Phase 5 lifecycle verification',
);
my $result = $application->revoke(%canonical);

is_deeply $result, $success, 'valid canonical revocation reaches the lifecycle service';
is scalar @{ $authorization->{calls} }, 1, 'authorization runs exactly once';
is $authorization->{calls}[0], $controller,
    'controller context is the trusted authentication source';
is scalar @{ $service->{calls} }, 1, 'lifecycle service is called exactly once';
is_deeply(
    $service->{calls}[0],
    {
        ( map { $_ => $canonical{$_} }
            qw(loan_id expected_row_version correlation_id reason) ),
        actor_id => 61,
    },
    'canonical revocation preserves trusted fields and authenticated actor_id'
);
ok defined $service->{calls}[0]{actor_id},
    'regression: authenticated staff actor_id is not consumed by map precedence';
ok !exists $service->{calls}[0]{controller},
    'controller object is not passed into the lifecycle command';

my $denied_service = Local::RevocationService->new($success);
my $denied =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanRevocationApplication
    ->new(
        authorization => Local::RevocationAuthorization->new({
            allowed => 0,
            code    => 'STAFF_NOT_AUTHORIZED',
        }),
        service => $denied_service,
    )->revoke(%canonical);
is_deeply(
    $denied,
    { ok => 0, code => 'STAFF_NOT_AUTHORIZED' },
    'authorization failure remains safely classified'
);
is scalar @{ $denied_service->{calls} }, 0,
    'denied command never reaches lifecycle processing';

done_testing;
