use Modern::Perl;
use Test::More;
use lib '.', 't/lib';

BEGIN {
    package C4::Context;
    sub dbh { die 'unexpected C4::Context->dbh in loan return unit test' }
    $INC{'C4/Context.pm'} = __FILE__;
}

use LoanReturnFakes;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanReturnService;

my $service_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanReturnService';

sub approved_request {
    my (%overrides) = @_;
    return {
        request_id             => 91,
        portal_request_id      => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0091',
        portal_idempotency_key => 'ffffffff-1111-4222-8333-444444440091',
        source                 => 'PORTAL',
        patron_id              => 157,
        biblio_id              => 13,
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
        %overrides,
    };
}

sub active_loan {
    my (%overrides) = @_;
    return {
        loan_id       => 31,
        request_id    => 91,
        patron_id     => 157,
        biblio_id     => 13,
        status        => 'ACTIVE',
        started_at    => '2026-07-24 16:00:00',
        due_at        => '2026-08-07 16:00:00',
        returned_at   => undef,
        revoked_at    => undef,
        expired_at    => undef,
        approved_by   => 51,
        renewal_count => 0,
        created_at    => '2026-07-24 16:00:00',
        updated_at    => '2026-07-24 16:00:00',
        row_version   => 1,
        %overrides,
    };
}

sub service {
    my (%args) = @_;
    my $dbh = $args{dbh} || Local::LoanReturnDBH->new(
        requests => [ approved_request() ],
        loans    => [ active_loan() ],
    );
    my $svc = $service_class->new(
        dbh             => $dbh,
        loan_repository => $args{loan_repository}
            || Local::LoanReturnLoanRepository->new,
        event_repository => $args{event_repository}
            || Local::LoanReturnEventRepository->new,
        clock => exists $args{clock}
        ? $args{clock}
        : sub { '2026-07-26 12:00:00' },
        uuid_generator => $args{uuid_generator}
            || sub { 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0099' },
        json_encoder => $args{json_encoder},
        diagnostic   => $args{diagnostic},
    );
    return ( $svc, $dbh );
}

sub command {
    my (%overrides) = @_;
    return (
        loan_id              => 31,
        patron_id            => 157,
        portal_request_id    => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0091',
        expected_row_version => 1,
        actor_id             => 53,
        correlation_id       => 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff0091',
        %overrides,
    );
}

# --- Successful ACTIVE return ---
{
    my ( $svc, $dbh ) = service();
    my $before_started = $dbh->{loans}[0]{started_at};
    my $before_due     = $dbh->{loans}[0]{due_at};
    my $native_before  = scalar @{ $dbh->{native_issues} };
    my $result         = $svc->return_loan( command() );
    ok $result->{ok}, 'ACTIVE loan returns successfully';
    is $result->{loan}{status}, 'RETURNED', 'status becomes RETURNED';
    is $result->{loan}{returned_at}, '2026-07-26 12:00:00', 'returned_at populated';
    is $result->{loan}{row_version}, 2, 'row_version increments once';
    is $result->{loan}{started_at}, $before_started, 'started_at unchanged';
    is $result->{loan}{due_at}, $before_due, 'due_at unchanged';
    is $result->{loan}{renewal_count}, 0, 'renewal_count unchanged';
    ok !defined $result->{loan}{revoked_at}, 'revoked_at remains null';
    ok !defined $result->{loan}{expired_at}, 'expired_at remains null';
    is $result->{idempotent_replay}, 0, 'first return is not idempotent replay';
    is scalar @{ $dbh->{events} }, 1, 'one return event created';
    is $dbh->{events}[0]{event_type}, 'LOAN_RETURNED', 'event type LOAN_RETURNED';
    is $dbh->{events}[0]{actor_patron_id}, 53, 'event actor is service account';
    is $dbh->{events}[0]{patron_id}, 157, 'event patron is subject patron';
    is $dbh->{events}[0]{source}, 'PORTAL', 'event source is PORTAL';
    is scalar @{ $dbh->{native_issues} }, $native_before,
        'native Koha issues untouched';
    is_deeply $dbh->{calls}, [qw(begin commit)], 'successful return commits once';
}

# --- Idempotent repeated return ---
{
    my ( $svc, $dbh ) = service(
        dbh => Local::LoanReturnDBH->new(
            requests => [ approved_request() ],
            loans    => [
                active_loan(
                    status      => 'RETURNED',
                    returned_at => '2026-07-26 11:00:00',
                    row_version => 2,
                    updated_at  => '2026-07-26 11:00:00',
                )
            ],
            events => [
                {
                    event_type => 'LOAN_RETURNED',
                    loan_id    => 31,
                }
            ],
        )
    );
    my $before_returned = $dbh->{loans}[0]{returned_at};
    my $before_version  = $dbh->{loans}[0]{row_version};
    my $before_events   = scalar @{ $dbh->{events} };
    my $result          = $svc->return_loan( command( expected_row_version => 1 ) );
    ok $result->{ok}, 'already RETURNED returns success';
    is $result->{idempotent_replay}, 1, 'repeated return is idempotent';
    is $result->{loan}{returned_at}, $before_returned, 'returned_at unchanged';
    is $result->{loan}{row_version}, $before_version, 'row_version unchanged';
    is scalar @{ $dbh->{events} }, $before_events, 'no second event';
}

# --- Wrong patron ---
{
    my ( $svc, $dbh ) = service();
    my $result = $svc->return_loan( command( patron_id => 999 ) );
    ok !$result->{ok}, 'wrong patron fails';
    is $result->{code}, 'LOAN_CORRELATION_MISMATCH', 'wrong patron code';
    is $dbh->{loans}[0]{status}, 'ACTIVE', 'loan remains ACTIVE';
    is scalar @{ $dbh->{events} }, 0, 'no event on correlation failure';
}

# --- Wrong portal_request_id ---
{
    my ( $svc, $dbh ) = service();
    my $result = $svc->return_loan(
        command( portal_request_id => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0000' )
    );
    ok !$result->{ok}, 'wrong portal_request_id fails';
    is $result->{code}, 'LOAN_CORRELATION_MISMATCH', 'portal_request_id mismatch code';
    is $dbh->{loans}[0]{status}, 'ACTIVE', 'loan remains ACTIVE';
}

# --- Wrong plugin request correlation ---
{
    my ( $svc, $dbh ) = service(
        dbh => Local::LoanReturnDBH->new(
            requests => [
                approved_request(
                    request_id => 91,
                    patron_id  => 158,
                    biblio_id  => 13,
                )
            ],
            loans => [ active_loan() ],
        )
    );
    my $result = $svc->return_loan( command() );
    ok !$result->{ok}, 'request patron mismatch fails closed';
    is $result->{code}, 'LOAN_CORRELATION_MISMATCH',
        'plugin request correlation mismatch code';
    is $dbh->{loans}[0]{status}, 'ACTIVE', 'no write on request mismatch';
}

# --- Stale ACTIVE row_version ---
{
    my ( $svc, $dbh ) = service();
    my $result = $svc->return_loan( command( expected_row_version => 9 ) );
    ok !$result->{ok}, 'stale ACTIVE row_version fails';
    is $result->{code}, 'VERSION_CONFLICT', 'stale version conflict code';
    is $dbh->{loans}[0]{status}, 'ACTIVE', 'no partial write on version conflict';
    is $dbh->{loans}[0]{row_version}, 1, 'row_version unchanged on conflict';
    is scalar @{ $dbh->{events} }, 0, 'no event on version conflict';
}

# --- REVOKED ---
{
    my ( $svc, $dbh ) = service(
        dbh => Local::LoanReturnDBH->new(
            requests => [ approved_request() ],
            loans    => [
                active_loan(
                    status     => 'REVOKED',
                    revoked_at => '2026-07-25 10:00:00',
                )
            ],
        )
    );
    my $result = $svc->return_loan( command() );
    ok !$result->{ok}, 'REVOKED loan fails';
    is $result->{code}, 'LOAN_NOT_RETURNABLE', 'REVOKED conflict code';
    is $dbh->{loans}[0]{status}, 'REVOKED', 'REVOKED not rewritten to RETURNED';
}

# --- EXPIRED ---
{
    my ( $svc, $dbh ) = service(
        dbh => Local::LoanReturnDBH->new(
            requests => [ approved_request() ],
            loans    => [
                active_loan(
                    status     => 'EXPIRED',
                    expired_at => '2026-07-25 10:00:00',
                )
            ],
        )
    );
    my $result = $svc->return_loan( command() );
    ok !$result->{ok}, 'EXPIRED loan fails';
    is $result->{code}, 'LOAN_NOT_RETURNABLE', 'EXPIRED conflict code';
    is $dbh->{loans}[0]{status}, 'EXPIRED', 'EXPIRED not rewritten to RETURNED';
}

# --- Nonexistent loan ---
{
    my ( $svc, $dbh ) = service();
    my $result = $svc->return_loan( command( loan_id => 404 ) );
    ok !$result->{ok}, 'nonexistent loan fails';
    is $result->{code}, 'LOAN_NOT_FOUND', 'not-found contract';
}

# --- Concurrent race: second writer sees already RETURNED ---
{
    my $repo = Local::LoanReturnLoanRepository->new(
        race_return => {
            returned_at => '2026-07-26 11:55:00',
            row_version => 2,
        }
    );
    my ( $svc, $dbh ) = service( loan_repository => $repo );
    my $result = $svc->return_loan( command() );
    ok $result->{ok}, 'concurrent loser receives idempotent success';
    is $result->{idempotent_replay}, 1, 'race resolves as idempotent replay';
    is $result->{loan}{status}, 'RETURNED', 'canonical RETURNED after race';
    is scalar @{ $dbh->{events} }, 0, 'loser does not create a second event';
}

# --- Transaction rollback leaves loan and event consistent ---
{
    my ( $svc, $dbh ) = service(
        event_repository => Local::LoanReturnEventRepository->new(
            insert_error => "EVENT_INSERT_FAILED\n",
        )
    );
    my $result = $svc->return_loan( command() );
    ok !$result->{ok}, 'event insert failure fails the transaction';
    is $result->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
        'transaction failure maps to unavailable';
    is $dbh->{loans}[0]{status}, 'ACTIVE', 'loan rolled back to ACTIVE';
    is $dbh->{loans}[0]{row_version}, 1, 'row_version rolled back';
    is scalar @{ $dbh->{events} }, 0, 'event rolled back';
    ok( ( grep { $_ eq 'rollback' } @{ $dbh->{calls} } ), 'rollback invoked' );
}

done_testing;
