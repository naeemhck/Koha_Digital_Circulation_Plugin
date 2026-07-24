use Modern::Perl;
use Test::More;
use lib '.', 't/lib';

BEGIN {
    package C4::Context;
    sub dbh { die 'unexpected C4::Context->dbh in loan issuance unit test' }
    $INC{'C4/Context.pm'} = __FILE__;
}

use LoanIssuanceFakes;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService;

my $service_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService';

sub approved_request {
    return {
        request_id             => 7,
        portal_request_id      => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
        portal_idempotency_key => 'ffffffff-1111-4222-8333-444444444444',
        source                 => 'PORTAL',
        patron_id              => 50,
        biblio_id              => 1,
        status                 => 'APPROVED',
        requested_at           => '2026-07-24 15:00:00',
        approved_at            => '2026-07-24 15:10:00',
        approved_by            => 51,
        rejected_at            => undef,
        rejected_by            => undef,
        rejection_reason       => undef,
        cancelled_at           => undef,
        created_at             => '2026-07-24 15:00:00',
        updated_at             => '2026-07-24 15:10:00',
        row_version            => 2,
    };
}

sub service {
    my (%args) = @_;
    my $dbh = $args{dbh} || Local::LoanIssuanceDBH->new(
        requests => [ approved_request() ],
    );
    return (
        $service_class->new(
            dbh                => $dbh,
            request_repository => $args{request_repository}
                || Local::LoanIssuanceRequestRepository->new,
            loan_repository => $args{loan_repository}
                || Local::LoanIssuanceLoanRepository->new,
            event_repository => $args{event_repository}
                || Local::LoanIssuanceEventRepository->new,
            eligibility => $args{eligibility}
                || Local::LoanIssuanceEligibility->new,
            due_date_policy => $args{due_date_policy} || sub {
                return { ok => 1, due_at => '2026-08-07 12:00:00' };
            },
            clock => exists $args{clock}
            ? $args{clock}
            : sub { '2026-07-24 12:00:00' },
            uuid_generator => sub { 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0011' },
            json_encoder   => $args{json_encoder},
            diagnostic     => $args{diagnostic},
        ),
        $dbh,
    );
}

sub command {
    return ( request_id => 7, actor_id => 51 );
}

my $loan_error = Local::LoanIssuanceLoanRepository->new(
    insert_error => 'DBI:mysql password=secret at C:\\private\\Loan.pm line 7'
);
my ( $loan_failure_service, $loan_failure_dbh ) =
    service( loan_repository => $loan_error );
my $loan_failure = $loan_failure_service->issue_loan( command() );
is $loan_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'loan insert failure returns safe availability code';
is_deeply $loan_failure_dbh->{calls}, [qw(begin rollback)],
    'loan insert failure rolls back without commit';
is scalar @{ $loan_failure_dbh->{loans} }, 0,
    'loan insert failure leaves zero loans';
is scalar @{ $loan_failure_dbh->{events} }, 0,
    'loan insert failure creates no event';

my $event_error = Local::LoanIssuanceEventRepository->new(
    insert_error => 'SQLSTATE token cookie at /srv/Event.pm line 4'
);
my ( $event_failure_service, $event_failure_dbh ) =
    service( event_repository => $event_error );
my $event_failure = $event_failure_service->issue_loan( command() );
is $event_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'event insertion failure returns safe availability code';
is_deeply $event_failure_dbh->{calls}, [qw(begin rollback)],
    'event insertion failure rolls back without commit';
is scalar @{ $event_failure_dbh->{loans} }, 0,
    'event failure rolls back the loan insert';
is scalar @{ $event_failure_dbh->{events} }, 0,
    'failed event does not remain';

my ( $json_service, $json_dbh ) = service(
    json_encoder => sub { die 'JSON encoder failed with DSN and token' }
);
my $json_result = $json_service->issue_loan( command() );
is $json_result->{code}, 'INTERNAL_ERROR',
    'JSON encoding failure returns safe internal code';
is_deeply $json_dbh->{calls}, [qw(begin rollback)],
    'JSON encoding failure rolls back';
is scalar @{ $json_dbh->{loans} }, 0, 'JSON failure leaves zero loans';

my ( $clock_service, $clock_dbh ) =
    service( clock => sub { die 'clock path C:\\secret.pm' } );
my $clock_failure = $clock_service->issue_loan( command() );
is $clock_failure->{code}, 'INTERNAL_ERROR',
    'throwing clock returns safe internal code';
is_deeply $clock_dbh->{calls}, [qw(begin rollback)],
    'throwing clock rolls back';

my ( $invalid_clock_service, $invalid_clock_dbh ) =
    service( clock => sub { return 'not-a-database-timestamp' } );
my $invalid_clock = $invalid_clock_service->issue_loan( command() );
is $invalid_clock->{code}, 'INTERNAL_ERROR',
    'invalid clock value returns safe internal code';
is_deeply $invalid_clock_dbh->{calls}, [qw(begin rollback)],
    'invalid clock value rolls back';

my $commit_dbh = Local::LoanIssuanceDBH->new(
    requests     => [ approved_request() ],
    commit_error => 'DBI commit failed Authorization: Bearer private',
);
my ( $commit_service, $commit_failure_dbh ) = service( dbh => $commit_dbh );
my $commit_failure = $commit_service->issue_loan( command() );
is $commit_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'commit failure returns safe availability code';
is_deeply $commit_failure_dbh->{calls}, [qw(begin commit rollback)],
    'commit failure attempts rollback';
is scalar @{ $commit_failure_dbh->{loans} }, 0,
    'commit failure restores loan collection';
is scalar @{ $commit_failure_dbh->{events} }, 0,
    'commit failure restores event collection';

my $diag_calls = [];
my $rollback_dbh = Local::LoanIssuanceDBH->new(
    requests       => [ approved_request() ],
    rollback_error => 'rollback diagnostic failed',
);
my ($rollback_service) = service(
    dbh => $rollback_dbh,
    event_repository => Local::LoanIssuanceEventRepository->new(
        insert_error => 'event failed'
    ),
    diagnostic => sub {
        push @$diag_calls, $_[0];
        die 'diagnostic callback leaked secret';
    },
);
my $rollback_result = $rollback_service->issue_loan( command() );
is $rollback_result->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'rollback and diagnostic failures cannot replace safe result';
is_deeply $rollback_dbh->{calls}, [qw(begin rollback)],
    'rollback is attempted once';
ok grep( { $_ eq 'transaction_failed' } @$diag_calls ),
    'normalized transaction_failed diagnostic is attempted';

for my $failure_result (
    $loan_failure, $event_failure, $json_result, $clock_failure,
    $invalid_clock, $commit_failure, $rollback_result
    )
{
    unlike join( ' ', grep { defined && !ref } values %{$failure_result} ),
        qr{DBI|SQLSTATE|SELECT|UPDATE|INSERT|password|Authorization|Bearer|token|cookie|DSN|[A-Za-z]:[\\/]|/srv/}i,
        'failure result stays free of secrets and internals';
}

done_testing;
