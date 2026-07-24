use Modern::Perl;
use Test::More;
use lib '.', 't/lib';

BEGIN {
    package C4::Context;
    sub dbh { die 'unexpected C4::Context->dbh in loan period policy unit test' }
    $INC{'C4/Context.pm'} = __FILE__;
}

use LoanIssuanceFakes;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::ConfiguredLoanPeriodPolicy;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService;

{
    package Local::DurationPlugin;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            data  => { %{ $args{data} || {} } },
            reads => [],
            error => $args{error},
        }, $class;
    }
    sub retrieve_data {
        my ( $self, $key ) = @_;
        push @{ $self->{reads} }, $key;
        die $self->{error} if $self->{error};
        return $self->{data}{$key};
    }
    sub store_data {
        my ( $self, $payload ) = @_;
        die $self->{error} if $self->{error};
        while ( my ( $key, $value ) = each %{$payload} ) {
            $self->{data}{$key} = $value;
        }
        return 1;
    }
}

my $class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::ConfiguredLoanPeriodPolicy';
my $service_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService';

is $class->config_key, 'default_loan_duration_days',
    'stable configuration key selected';
is $class->min_days, 1,  'minimum duration is 1 day';
is $class->max_days, 365, 'maximum duration is 365 days';

sub policy {
    my (%args) = @_;
    return $class->new(%args);
}

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

# --- Valid calendar-day calculations ---
for my $case (
    [ 1,   '2026-07-25 10:00:00', '2026-07-26 10:00:00' ],
    [ 14,  '2026-07-25 10:00:00', '2026-08-08 10:00:00' ],
    [ 30,  '2026-07-25 10:00:00', '2026-08-24 10:00:00' ],
    [ 365, '2026-07-25 10:00:00', '2027-07-25 10:00:00' ],
    [ 1,   '2026-01-31 23:59:59', '2026-02-01 23:59:59' ],
    [ 1,   '2026-12-31 00:00:00', '2027-01-01 00:00:00' ],
    [ 1,   '2024-02-28 12:00:00', '2024-02-29 12:00:00' ],
    [ 1,   '2024-02-29 12:00:00', '2024-03-01 12:00:00' ],
    [ 1,   '2026-03-08 01:30:00', '2026-03-09 01:30:00' ],
    )
{
    my ( $days, $started, $expected ) = @{$case};
    my $result = policy(
        config_reader => sub {$days},
    )->resolve_due_at( started_at => $started );
    ok $result->{ok}, "duration $days from $started succeeds";
    is $result->{due_at}, $expected,
        "duration $days from $started yields $expected";
}

# --- Invalid values fail closed ---
for my $invalid (
    undef, '', '   ', '0', '-1', '1.5', '1e2', '+14', '14 days',
    '14x', '366', '999999999', [], {}, \*STDOUT,
    bless( \do { my $o = 1 }, 'Local::Boolean' ),
    )
{
    my $result = policy(
        config_reader => sub {$invalid},
    )->resolve_due_at( started_at => '2026-07-25 10:00:00' );
    ok !$result->{ok}, 'invalid duration fails closed';
    is $result->{code}, 'INVALID_LOAN_PERIOD',
        'invalid duration maps to INVALID_LOAN_PERIOD';
}

# --- Configuration failures ---
my $reader_throw = policy(
    config_reader => sub { die 'plugin path C:\\secret SQLSTATE' },
)->resolve_due_at( started_at => '2026-07-25 10:00:00' );
is $reader_throw->{code}, 'INVALID_LOAN_PERIOD',
    'configuration reader exception fails closed';

my $structured = policy(
    plugin => Local::DurationPlugin->new(
        data => { default_loan_duration_days => [14] },
    ),
)->resolve_due_at( started_at => '2026-07-25 10:00:00' );
is $structured->{code}, 'INVALID_LOAN_PERIOD',
    'structured stored duration fails closed';

my $unavailable = policy(
    plugin => Local::DurationPlugin->new(
        error => 'retrieve failed DSN=secret',
    ),
)->resolve_due_at( started_at => '2026-07-25 10:00:00' );
is $unavailable->{code}, 'INVALID_LOAN_PERIOD',
    'unavailable plugin data fails closed';

# --- Clock separation ---
my $adder_calls = 0;
my $clock_calls = 0;
my $no_clock = policy(
    config_reader => sub {14},
    date_adder    => sub {
        my ( $started_at, $days ) = @_;
        $adder_calls++;
        is $started_at, '2026-07-25 10:00:00',
            'policy uses supplied started_at';
        is $days, 14, 'policy uses configured days';
        return '2026-08-08 10:00:00';
    },
)->resolve_due_at( started_at => '2026-07-25 10:00:00' );
ok $no_clock->{ok}, 'policy succeeds without a clock dependency';
is $adder_calls, 1, 'date adder invoked once';
is $clock_calls, 0, 'policy does not call a clock';

# --- Diagnostics ---
my @diagnostics;
my $diag_result = policy(
    config_reader => sub {undef},
    diagnostic    => sub {
        push @diagnostics, $_[0];
        die 'diagnostic sink failed';
    },
)->resolve_due_at( started_at => '2026-07-25 10:00:00' );
is $diag_result->{code}, 'INVALID_LOAN_PERIOD',
    'diagnostic exception does not replace the safe policy result';
ok scalar( grep { $_ eq 'loan_duration_missing' } @diagnostics ),
    'missing duration emits loan_duration_missing';
unlike join( ' ', @diagnostics ), qr{secret|DSN|SQLSTATE|HASH|ARRAY}i,
    'diagnostics receive only normalized categories';

my @invalid_diagnostics;
policy(
    config_reader => sub {'14 days'},
    diagnostic    => sub { push @invalid_diagnostics, $_[0] },
)->resolve_due_at( started_at => '2026-07-25 10:00:00' );
ok scalar( grep { $_ eq 'loan_duration_invalid' } @invalid_diagnostics ),
    'malformed duration emits loan_duration_invalid';

my @range_diagnostics;
policy(
    config_reader => sub {366},
    diagnostic    => sub { push @range_diagnostics, $_[0] },
)->resolve_due_at( started_at => '2026-07-25 10:00:00' );
ok scalar( grep { $_ eq 'loan_duration_out_of_range' } @range_diagnostics ),
    'out-of-range duration emits loan_duration_out_of_range';

# --- store/load helpers ---
my $plugin = Local::DurationPlugin->new;
my $storage = policy( plugin => $plugin );
my $saved = $storage->store_config('14');
ok $saved->{stored}, 'valid duration stores';
is $plugin->{data}{default_loan_duration_days}, '14',
    'canonical integer string is persisted';
my $loaded = $storage->load_config;
ok $loaded->{loaded}, 'valid duration loads';
is $loaded->{value}, '14', 'loaded value is canonical';

my $cleared = $storage->store_config('   ');
ok $cleared->{stored} && $cleared->{disabled},
    'blank duration clears configuration';
is $plugin->{data}{default_loan_duration_days}, '',
    'blank duration stores empty string';

my $rejected = $storage->store_config('366');
ok !$rejected->{stored}, 'out-of-range duration is not stored';
is $rejected->{code}, 'INVALID_LOAN_DURATION',
    'out-of-range store rejection uses stable code';
is $plugin->{data}{default_loan_duration_days}, '',
    'rejected store preserves previous cleared value';

# --- LoanIssuanceService integration ---
{
    my $dbh = Local::LoanIssuanceDBH->new(
        requests => [ approved_request() ],
    );
    my $svc = $service_class->new(
        dbh                => $dbh,
        request_repository => Local::LoanIssuanceRequestRepository->new,
        loan_repository    => Local::LoanIssuanceLoanRepository->new,
        event_repository   => Local::LoanIssuanceEventRepository->new,
        eligibility => Local::LoanIssuanceEligibility->new( biblio_id => 1 ),
        due_date_policy => policy(
            config_reader => sub {14},
        ),
        clock          => sub {'2026-07-25 10:00:00'},
        uuid_generator => sub {'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0011'},
    );
    my $result = $svc->issue_loan( request_id => 7, actor_id => 51 );
    ok $result->{ok}, 'configured 14-day policy allows issuance';
    is $result->{loan}{started_at}, '2026-07-25 10:00:00',
        'issuance started_at comes from service clock';
    is $result->{loan}{due_at}, '2026-08-08 10:00:00',
        'issuance due_at is 14 calendar days later';
    ok $result->{loan}{due_at} gt $result->{loan}{started_at},
        'due_at is later than started_at';
}

for my $missing_case ( undef, '', '0', '366', '14 days' ) {
    my $dbh = Local::LoanIssuanceDBH->new(
        requests => [ approved_request() ],
    );
    my $svc = $service_class->new(
        dbh                => $dbh,
        request_repository => Local::LoanIssuanceRequestRepository->new,
        loan_repository    => Local::LoanIssuanceLoanRepository->new,
        event_repository   => Local::LoanIssuanceEventRepository->new,
        eligibility => Local::LoanIssuanceEligibility->new( biblio_id => 1 ),
        due_date_policy => policy(
            config_reader => sub {$missing_case},
        ),
        clock => sub {'2026-07-25 10:00:00'},
    );
    my $result = $svc->issue_loan( request_id => 7, actor_id => 51 );
    is $result->{code}, 'INVALID_LOAN_PERIOD',
        'missing/invalid policy produces INVALID_LOAN_PERIOD';
    is scalar @{ $dbh->{loans} },  0, 'policy failure creates zero loans';
    is scalar @{ $dbh->{events} }, 0, 'policy failure creates zero events';
}

{
    my $pending = approved_request();
    $pending->{status} = 'PENDING';
    my $dbh = Local::LoanIssuanceDBH->new( requests => [$pending] );
    my $svc = $service_class->new(
        dbh                => $dbh,
        request_repository => Local::LoanIssuanceRequestRepository->new,
        loan_repository    => Local::LoanIssuanceLoanRepository->new,
        event_repository   => Local::LoanIssuanceEventRepository->new,
        eligibility => Local::LoanIssuanceEligibility->new( biblio_id => 1 ),
        due_date_policy => policy( config_reader => sub {14} ),
        clock           => sub {'2026-07-25 10:00:00'},
    );
    my $result = $svc->issue_loan( request_id => 7, actor_id => 51 );
    is $result->{code}, 'REQUEST_NOT_APPROVED',
        'valid policy still requires APPROVED request';
}

{
    my $dbh = Local::LoanIssuanceDBH->new(
        requests => [ approved_request() ],
    );
    my $svc = $service_class->new(
        dbh                => $dbh,
        request_repository => Local::LoanIssuanceRequestRepository->new,
        loan_repository    => Local::LoanIssuanceLoanRepository->new,
        event_repository   => Local::LoanIssuanceEventRepository->new,
        eligibility => Local::LoanIssuanceEligibility->new(
            result => {
                eligible  => 0,
                biblio_id => 1,
                code      => 'CONTENT_NOT_ELIGIBLE',
                reason    => 'CONTENT_LOOKUP_UNAVAILABLE',
            }
        ),
        due_date_policy => policy( config_reader => sub {14} ),
        clock           => sub {'2026-07-25 10:00:00'},
    );
    my $result = $svc->issue_loan( request_id => 7, actor_id => 51 );
    is $result->{code}, 'PROTECTED_CONTENT_UNAVAILABLE',
        'valid policy still requires protected-content eligibility';
}

open my $source_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/ConfiguredLoanPeriodPolicy.pm'
    or die $!;
my $source = do { local $/; <$source_fh> };
close $source_fh;
unlike $source, qr/\b(?:AddIssue|GetIssue|issues|old_issues)\b/,
    'policy creates no native Koha issue';
unlike $source, qr/reader[_-]?token|entitlement|byte-range/i,
    'policy contains no reader/access behavior';
unlike $source, qr/\bstatus\s*=>\s*\d{3}\b|\brender\s*\(/,
    'policy contains no HTTP mapping';

done_testing;
