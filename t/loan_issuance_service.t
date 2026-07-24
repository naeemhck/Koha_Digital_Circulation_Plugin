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
    my (%overrides) = @_;
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
        %overrides,
    };
}

sub due_policy {
    return sub {
        my (%ctx) = @_;
        return {
            ok     => 1,
            due_at => '2026-08-07 12:00:00',
        };
    };
}

sub service {
    my (%args) = @_;
    my $dbh = $args{dbh} || Local::LoanIssuanceDBH->new(
        requests => [ approved_request() ],
    );
    my $svc = $service_class->new(
        dbh                => $dbh,
        request_repository => $args{request_repository}
            || Local::LoanIssuanceRequestRepository->new,
        loan_repository => $args{loan_repository}
            || Local::LoanIssuanceLoanRepository->new,
        event_repository => $args{event_repository}
            || Local::LoanIssuanceEventRepository->new,
        eligibility => $args{eligibility}
            || Local::LoanIssuanceEligibility->new( biblio_id => 1 ),
        due_date_policy => exists $args{due_date_policy}
        ? $args{due_date_policy}
        : due_policy(),
        clock => exists $args{clock}
        ? $args{clock}
        : sub { '2026-07-24 12:00:00' },
        uuid_generator => $args{uuid_generator}
            || sub { 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0011' },
        json_encoder => $args{json_encoder},
        diagnostic   => $args{diagnostic},
    );
    return ( $svc, $dbh );
}

sub command {
    my (%overrides) = @_;
    return (
        request_id => 7,
        actor_id   => 51,
        %overrides,
    );
}

# --- Successful issuance ---
{
    my ( $svc, $dbh ) = service();
    my $before = { %{ $dbh->{requests}[0] } };
    my $result = $svc->issue_loan( command() );
    ok $result->{ok}, 'approved request issues a loan';
    is $result->{loan}{status}, 'ACTIVE', 'canonical ACTIVE status selected';
    is $result->{loan}{request_id}, 7, 'loan linked to request';
    is $result->{loan}{patron_id},  50, 'patron comes from request';
    is $result->{loan}{biblio_id},  1,  'biblio comes from request';
    is $result->{loan}{started_at}, '2026-07-24 12:00:00', 'issued/start timestamp from clock';
    is $result->{loan}{due_at},     '2026-08-07 12:00:00', 'due timestamp from policy';
    is $result->{loan}{approved_by}, 51, 'issuer actor recorded on loan';
    is $result->{loan}{row_version}, 1, 'new loan row_version is 1';
    is scalar @{ $dbh->{loans} },  1, 'exactly one loan inserted';
    is scalar @{ $dbh->{events} }, 1, 'exactly one audit event inserted';
    is $dbh->{events}[0]{event_type}, 'LOAN_CREATED', 'event type is LOAN_CREATED';
    is $dbh->{events}[0]{aggregate_type}, 'LOAN', 'event aggregate is LOAN';
    is $dbh->{events}[0]{loan_id},  $result->{loan}{loan_id}, 'event links loan';
    is $dbh->{events}[0]{request_id}, 7, 'event links request';
    is $dbh->{events}[0]{patron_id},  50, 'event patron from request';
    is $dbh->{events}[0]{biblio_id},  1,  'event biblio from request';
    is $dbh->{events}[0]{actor_patron_id}, 51, 'event actor is issuer';
    is $dbh->{events}[0]{occurred_at}, '2026-07-24 12:00:00', 'event uses issuance clock';
    is_deeply $dbh->{calls}, [qw(begin commit)], 'successful issuance commits once';
    is $dbh->{requests}[0]{status}, $before->{status}, 'request status unchanged';
    is $dbh->{requests}[0]{row_version}, $before->{row_version},
        'request row_version unchanged';
    is $dbh->{requests}[0]{approved_by}, $before->{approved_by},
        'request approval actor unchanged';
    is $dbh->{requests}[0]{approved_at}, $before->{approved_at},
        'request approval timestamp unchanged';
    is scalar @{ $dbh->{renewals} }, 0, 'no renewal created';
    unlike join( ' ', map { defined $_ ? $_ : '' } values %{ $result->{loan} } ),
        qr{AddIssue|reader|token|entitlement|/var/lib}i,
        'success result has no native issue or reader entitlement fields';
}

# --- Caller cannot override authoritative fields ---
{
    my ( $svc, $dbh ) = service();
    my $result = $svc->issue_loan(
        command(
            patron_id   => 999,
            biblio_id   => 888,
            status      => 'RETURNED',
            started_at  => '1999-01-01 00:00:00',
            due_at      => '1999-01-02 00:00:00',
            content_id  => 777,
            mapping     => { path => 'C:\\secret.pdf' },
        )
    );
    ok $result->{ok}, 'extra caller fields are ignored';
    is $result->{loan}{patron_id}, 50, 'caller patron override ignored';
    is $result->{loan}{biblio_id}, 1,  'caller biblio override ignored';
    is $result->{loan}{status}, 'ACTIVE', 'caller status override ignored';
    is $result->{loan}{started_at}, '2026-07-24 12:00:00',
        'caller timestamp override ignored';
    is $result->{loan}{due_at}, '2026-08-07 12:00:00',
        'caller due override ignored';
}

# --- Invalid request states ---
for my $case (
    {
        name   => 'PENDING',
        req    => approved_request( status => 'PENDING', approved_at => undef, approved_by => undef, row_version => 1 ),
        code   => 'REQUEST_NOT_APPROVED',
    },
    {
        name => 'REJECTED',
        req  => approved_request(
            status           => 'REJECTED',
            approved_at      => undef,
            approved_by      => undef,
            rejected_at      => '2026-07-24 15:12:00',
            rejected_by      => 51,
            rejection_reason => 'no',
        ),
        code => 'REQUEST_NOT_APPROVED',
    },
    {
        name => 'CANCELLED',
        req  => approved_request(
            status      => 'CANCELLED',
            approved_at => undef,
            approved_by => undef,
            cancelled_at => '2026-07-24 15:12:00',
        ),
        code => 'REQUEST_NOT_APPROVED',
    },
    {
        name => 'unknown status',
        req  => approved_request( status => 'WEIRD' ),
        code => 'REQUEST_NOT_APPROVED',
    },
    )
{
    my ( $svc, $dbh ) = service(
        dbh => Local::LoanIssuanceDBH->new( requests => [ $case->{req} ] )
    );
    my $result = $svc->issue_loan( command() );
    is $result->{ok}, 0, "$case->{name} fails closed";
    is $result->{code}, $case->{code}, "$case->{name} returns $case->{code}";
    is scalar @{ $dbh->{loans} },  0, "$case->{name} creates zero loans";
    is scalar @{ $dbh->{events} }, 0, "$case->{name} creates zero events";
}

{
    my ( $svc, $dbh ) = service(
        dbh => Local::LoanIssuanceDBH->new( requests => [] )
    );
    my $result = $svc->issue_loan( command() );
    is $result->{code}, 'REQUEST_NOT_FOUND', 'missing request fails closed';
    is scalar @{ $dbh->{loans} },  0, 'missing request creates zero loans';
    is scalar @{ $dbh->{events} }, 0, 'missing request creates zero events';
}

# --- Duplicate issuance ---
{
    my ( $svc, $dbh ) = service();
    my $first  = $svc->issue_loan( command() );
    my $second = $svc->issue_loan( command() );
    ok $first->{ok}, 'first issuance succeeds';
    is $second->{code}, 'LOAN_ALREADY_EXISTS',
        'duplicate sequential issuance returns LOAN_ALREADY_EXISTS';
    is scalar @{ $dbh->{loans} },  1, 'duplicate keeps one loan';
    is scalar @{ $dbh->{events} }, 1, 'duplicate keeps one event';
}

{
    my $existing = {
        loan_id       => 9,
        request_id    => 7,
        patron_id     => 50,
        biblio_id     => 1,
        status        => 'ACTIVE',
        started_at    => '2026-07-24 11:00:00',
        due_at        => '2026-08-01 11:00:00',
        returned_at   => undef,
        revoked_at    => undef,
        expired_at    => undef,
        approved_by   => 51,
        renewal_count => 0,
        created_at    => '2026-07-24 11:00:00',
        updated_at    => '2026-07-24 11:00:00',
        row_version   => 1,
    };
    my ( $svc, $dbh ) = service(
        dbh => Local::LoanIssuanceDBH->new(
            requests => [ approved_request() ],
            loans    => [$existing],
            events   => [
                {
                    event_type => 'LOAN_CREATED',
                    loan_id    => 9,
                    request_id => 7,
                }
            ],
        )
    );
    my $result = $svc->issue_loan( command() );
    is $result->{code}, 'LOAN_ALREADY_EXISTS',
        'existing loan for request is rejected';
    is scalar @{ $dbh->{loans} },  1, 'existing loan not duplicated';
    is scalar @{ $dbh->{events} }, 1, 'existing event not duplicated';
}

{
    my ( $svc, $dbh ) = service(
        loan_repository => Local::LoanIssuanceLoanRepository->new(
            insert_error => "Duplicate entry for key 'jzl_loan_request_uq'\n"
        )
    );
    my $result = $svc->issue_loan( command() );
    is $result->{code}, 'LOAN_ALREADY_EXISTS',
        'unique-index conflict maps to LOAN_ALREADY_EXISTS';
    is scalar @{ $dbh->{loans} }, 0,
        'losing concurrent insert commits no loan in this transaction';
    is scalar @{ $dbh->{events} }, 0,
        'losing concurrent insert commits no event';
}

# --- Protected-content failures ---
for my $case (
    {
        name   => 'dependency unavailable',
        result => {
            eligible  => 0,
            biblio_id => 1,
            code      => 'CONTENT_NOT_ELIGIBLE',
            reason    => 'CONTENT_LOOKUP_UNAVAILABLE',
        },
        code => 'PROTECTED_CONTENT_UNAVAILABLE',
    },
    {
        name   => 'missing protected content',
        result => {
            eligible  => 0,
            biblio_id => 1,
            code      => 'CONTENT_NOT_ELIGIBLE',
            reason    => 'MISSING_PROTECTED_CONTENT',
        },
        code => 'PROTECTED_CONTENT_UNAVAILABLE',
    },
    {
        name   => 'invalid mapping',
        result => {
            eligible  => 0,
            biblio_id => 1,
            code      => 'CONTENT_NOT_ELIGIBLE',
            reason    => 'INVALID_CONTENT_MAPPING',
        },
        code => 'INVALID_MAPPING',
    },
    {
        name   => 'ineligible content',
        result => {
            eligible  => 0,
            biblio_id => 1,
            code      => 'CONTENT_NOT_ELIGIBLE',
            reason    => 'CONTENT_DISABLED',
        },
        code => 'INVALID_MAPPING',
    },
    )
{
    my ( $svc, $dbh ) = service(
        eligibility => Local::LoanIssuanceEligibility->new(
            result => $case->{result}
        )
    );
    my $result = $svc->issue_loan( command() );
    is $result->{code}, $case->{code}, "$case->{name} maps to $case->{code}";
    is scalar @{ $dbh->{loans} },  0, "$case->{name} creates zero loans";
    is scalar @{ $dbh->{events} }, 0, "$case->{name} creates zero events";
}

{
    my ( $svc, $dbh ) = service(
        eligibility => Local::LoanIssuanceEligibility->new(
            error => 'adapter exploded with token cookie'
        )
    );
    my $result = $svc->issue_loan( command() );
    is $result->{code}, 'PROTECTED_CONTENT_UNAVAILABLE',
        'eligibility exception fails closed';
    is scalar @{ $dbh->{loans} }, 0, 'eligibility exception creates no loan';
}

# --- Policy failures ---
for my $case (
    {
        name   => 'missing duration',
        policy => sub { return { ok => 1 } },
    },
    {
        name   => 'zero duration',
        policy => sub { return { ok => 1, duration_seconds => 0 } },
    },
    {
        name   => 'negative duration',
        policy => sub { return { ok => 1, duration_seconds => -5 } },
    },
    {
        name   => 'malformed result',
        policy => sub { return 'not-a-hash' },
    },
    {
        name   => 'due equal issued',
        policy => sub {
            return { ok => 1, due_at => '2026-07-24 12:00:00' };
        },
    },
    {
        name   => 'due before issued',
        policy => sub {
            return { ok => 1, due_at => '2026-07-24 11:59:59' };
        },
    },
    {
        name   => 'explicit policy failure',
        policy => sub {
            return { ok => 0, code => 'INVALID_LOAN_PERIOD' };
        },
    },
    )
{
    my ( $svc, $dbh ) = service( due_date_policy => $case->{policy} );
    my $result = $svc->issue_loan( command() );
    is $result->{code}, 'INVALID_LOAN_PERIOD',
        "$case->{name} returns INVALID_LOAN_PERIOD";
    is scalar @{ $dbh->{loans} },  0, "$case->{name} creates zero loans";
    is scalar @{ $dbh->{events} }, 0, "$case->{name} creates zero events";
}

{
    my ( $svc, $dbh ) = service(
        due_date_policy => sub {
            return { ok => 1, duration_seconds => 3600 };
        }
    );
    my $result = $svc->issue_loan( command() );
    ok $result->{ok}, 'duration_seconds policy is accepted';
    is $result->{loan}{due_at}, '2026-07-24 13:00:00',
        'duration_seconds produces due_at after started_at';
}

# --- Actor validation ---
for my $actor (
    undef, 0, -1, '1.5', '1e3', '51x', [], {}
    )
{
    my ( $svc, $dbh ) = service();
    my %cmd = command();
    if ( defined $actor ) {
        $cmd{actor_id} = $actor;
    }
    else {
        delete $cmd{actor_id};
    }
    my $result = $svc->issue_loan(%cmd);
    is $result->{code}, 'INVALID_INPUT',
        'invalid actor rejected: ' . ( defined $actor ? ( ref($actor) || $actor ) : 'missing' );
    is scalar @{ $dbh->{loans} }, 0, 'invalid actor creates no loan';
}

# Default policy fails closed (no invented production duration)
{
    my $dbh = Local::LoanIssuanceDBH->new( requests => [ approved_request() ] );
    my $svc = $service_class->new(
        dbh                => $dbh,
        request_repository => Local::LoanIssuanceRequestRepository->new,
        loan_repository    => Local::LoanIssuanceLoanRepository->new,
        event_repository   => Local::LoanIssuanceEventRepository->new,
        eligibility        => Local::LoanIssuanceEligibility->new,
        clock              => sub { '2026-07-24 12:00:00' },
        uuid_generator     => sub { 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0011' },
    );
    my $result = $svc->issue_loan( command() );
    is $result->{code}, 'INVALID_LOAN_PERIOD',
        'missing injected due-date policy fails closed';
    is scalar @{ $dbh->{loans} }, 0, 'missing policy creates no loan';
}

done_testing;
