use Modern::Perl;
use Test::More;
use lib '.', 't/lib';

use RequestDecisionFakes;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestDecisionService;

{
    package Local::DecisionSQLCaptureDBH;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            calls      => [],
            rows       => $args{rows} || [],
            do_results => $args{do_results} || [],
        }, $class;
    }
    sub selectrow_hashref {
        my ( $self, $sql, $attr, @bind ) = @_;
        push @{ $self->{calls} }, [ select => $sql, @bind ];
        return shift @{ $self->{rows} };
    }
    sub do {
        my ( $self, $sql, $attr, @bind ) = @_;
        push @{ $self->{calls} }, [ do => $sql, @bind ];
        return @{ $self->{do_results} }
            ? shift @{ $self->{do_results} }
            : 1;
    }
}

my $service_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestDecisionService';

sub pending_request {
    my (%overrides) = @_;
    return {
        request_id             => 2,
        portal_request_id      => '1f7fe335-81f7-4dcf-bacd-1eb9d80b0770',
        portal_idempotency_key => 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
        source                 => 'PORTAL',
        patron_id              => 52,
        biblio_id              => 1,
        status                 => 'PENDING',
        requested_at           => '2026-07-23 16:54:49',
        approved_at            => undef,
        approved_by            => undef,
        rejected_at            => undef,
        rejected_by            => undef,
        rejection_reason       => undef,
        cancelled_at           => undef,
        created_at             => '2026-07-23 16:54:49',
        updated_at             => '2026-07-23 16:54:49',
        row_version            => 1,
        %overrides,
    };
}

sub command {
    return (
        actor_id            => 53,
        request_id          => 2,
        expected_row_version => 1,
        decision            => 'APPROVE',
        reason              => undef,
        correlation_id      => 'db421a13-f74a-4388-a681-897ec46156f4',
    );
}

sub service {
    my (%args) = @_;
    my $dbh = $args{dbh} || Local::RequestDecisionDBH->new(
        requests => [ pending_request() ],
    );
    return (
        $service_class->new(
            dbh                => $dbh,
            request_repository =>
                $args{request_repository}
                || Local::RequestDecisionRequestRepository->new,
            event_repository =>
                $args{event_repository}
                || Local::RequestDecisionEventRepository->new,
            state_machine => $args{state_machine},
            clock => exists $args{clock}
            ? $args{clock}
            : sub { '2026-07-23 17:00:00' },
            json_encoder => $args{json_encoder},
            diagnostic   => $args{diagnostic},
        ),
        $dbh,
    );
}

my $request_error =
    Local::RequestDecisionRequestRepository->new(
    update_error => 'DBI:mysql password=secret at C:\private\Request.pm line 7' );
my ( $request_failure_service, $request_failure_dbh ) =
    service( request_repository => $request_error );
my $request_failure =
    $request_failure_service->decide_request( command() );
is $request_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'request update failure returns safe availability code';
is_deeply $request_failure_dbh->{calls}, [qw(begin rollback)],
    'request update failure rolls back without commit';
is $request_failure_dbh->{requests}[0]{status}, 'PENDING',
    'request update failure leaves request pending';
is scalar @{ $request_failure_dbh->{events} }, 0,
    'request update failure creates no event';

my $event_error =
    Local::RequestDecisionEventRepository->new(
    insert_error => 'SQLSTATE token cookie at /srv/Event.pm line 4' );
my ( $event_failure_service, $event_failure_dbh ) =
    service( event_repository => $event_error );
my $event_failure = $event_failure_service->decide_request( command() );
is $event_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'event insertion failure returns safe availability code';
is_deeply $event_failure_dbh->{calls}, [qw(begin rollback)],
    'event insertion failure rolls back without commit';
is $event_failure_dbh->{requests}[0]{status}, 'PENDING',
    'event insertion failure rolls back request decision';
is $event_failure_dbh->{requests}[0]{row_version}, 1,
    'event failure rolls back row-version increment';
is scalar @{ $event_failure_dbh->{events} }, 0,
    'failed event does not remain';

my $json_failure = sub { die 'JSON encoder failed with DSN and token' };
my ( $json_failure_service, $json_failure_dbh ) =
    service( json_encoder => $json_failure );
my $json_result = $json_failure_service->decide_request( command() );
is $json_result->{code}, 'INTERNAL_ERROR',
    'JSON encoding failure returns safe internal code';
is_deeply $json_failure_dbh->{calls}, [qw(begin rollback)],
    'JSON encoding failure rolls back';
is $json_failure_dbh->{requests}[0]{status}, 'PENDING',
    'JSON encoding failure leaves request pending';
is scalar @{ $json_failure_dbh->{events} }, 0,
    'JSON encoding failure creates no event';

my ( $clock_failure_service, $clock_failure_dbh ) =
    service( clock => sub { die 'clock path C:\secret.pm' } );
my $clock_failure = $clock_failure_service->decide_request( command() );
is $clock_failure->{code}, 'INTERNAL_ERROR',
    'throwing clock returns safe internal code';
is_deeply $clock_failure_dbh->{calls}, [qw(begin rollback)],
    'throwing clock rolls back';
is $clock_failure_dbh->{requests}[0]{status}, 'PENDING',
    'throwing clock performs no update';

my ( $invalid_clock_service, $invalid_clock_dbh ) =
    service( clock => sub { return 'not-a-database-timestamp' } );
my $invalid_clock = $invalid_clock_service->decide_request( command() );
is $invalid_clock->{code}, 'INTERNAL_ERROR',
    'invalid clock value returns safe internal code';
is_deeply $invalid_clock_dbh->{calls}, [qw(begin rollback)],
    'invalid clock value rolls back';

my $commit_dbh = Local::RequestDecisionDBH->new(
    requests     => [ pending_request() ],
    commit_error => 'DBI commit failed Authorization: Bearer private',
);
my ( $commit_service, $commit_failure_dbh ) = service( dbh => $commit_dbh );
my $commit_failure = $commit_service->decide_request( command() );
is $commit_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'commit failure returns safe availability code';
is_deeply $commit_failure_dbh->{calls}, [qw(begin commit rollback)],
    'commit failure attempts rollback';
is $commit_failure_dbh->{requests}[0]{status}, 'PENDING',
    'commit failure restores request';
is scalar @{ $commit_failure_dbh->{events} }, 0,
    'commit failure restores event collection';

my $rollback_dbh = Local::RequestDecisionDBH->new(
    requests      => [ pending_request() ],
    rollback_error => 'rollback diagnostic failed',
);
my ( $rollback_service ) = service(
    dbh => $rollback_dbh,
    event_repository =>
        Local::RequestDecisionEventRepository->new(
            insert_error => 'event failed'
        ),
    diagnostic => sub { die 'diagnostic callback leaked secret' },
);
my $rollback_result = $rollback_service->decide_request( command() );
is $rollback_result->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'rollback and diagnostic failures cannot replace safe result';
is_deeply $rollback_dbh->{calls}, [qw(begin rollback)],
    'rollback is attempted once';

for my $failure_result (
    $request_failure, $event_failure, $json_result, $clock_failure,
    $invalid_clock, $commit_failure, $rollback_result
    )
{
    unlike join( ' ', grep { defined && !ref } values %{$failure_result} ),
        qr{DBI|SQLSTATE|SELECT|UPDATE|INSERT|password|Authorization|Bearer|token|cookie|DSN|[A-Za-z]:[\\/]|/srv/}i,
        'failure result exposes no database, credential, path, or stack detail';
}

my $real_request_repository =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository->new;
my $approval_capture = Local::DecisionSQLCaptureDBH->new(
    rows => [ pending_request() ],
);
$real_request_repository->get_for_decision( $approval_capture, 2 );
like $approval_capture->{calls}[0][1],
    qr/WHERE request_id = \? FOR UPDATE\z/,
    'decision load uses a bound locking current read';
is $approval_capture->{calls}[0][2], 2,
    'decision load binds request ID';

$real_request_repository->update_pending_decision(
    $approval_capture,
    request_id          => 2,
    expected_row_version => 1,
    decision            => 'APPROVE',
    status              => 'APPROVED',
    actor_id            => 53,
    decided_at          => '2026-07-23 17:00:00',
    reason              => undef,
);
my $approval_update = $approval_capture->{calls}[-1];
like $approval_update->[1],
    qr/UPDATE `plugin_jzl_ebook_requests`.*status = \?.*approved_at = \?.*approved_by = \?.*row_version = row_version \+ 1.*request_id = \?.*status = 'PENDING'.*row_version = \?/s,
    'approval update is guarded by ID, pending status, and row version';
is_deeply(
    [ @{$approval_update}[ 2 .. 6 ] ],
    [ 'APPROVED', '2026-07-23 17:00:00', 53, 2, 1 ],
    'approval update binds only the decision allowlist'
);

my $rejection_capture = Local::DecisionSQLCaptureDBH->new;
$real_request_repository->update_pending_decision(
    $rejection_capture,
    request_id          => 2,
    expected_row_version => 1,
    decision            => 'REJECT',
    status              => 'REJECTED',
    actor_id            => 53,
    decided_at          => '2026-07-23 17:00:00',
    reason              => 'Not eligible.',
);
my $rejection_update = $rejection_capture->{calls}[0];
like $rejection_update->[1],
    qr/UPDATE `plugin_jzl_ebook_requests`.*rejected_at = \?.*rejected_by = \?.*rejection_reason = \?.*row_version = row_version \+ 1/s,
    'rejection update uses existing rejection fields';
is_deeply(
    [ @{$rejection_update}[ 2 .. 7 ] ],
    [ 'REJECTED', '2026-07-23 17:00:00', 53, 'Not eligible.', 2, 1 ],
    'rejection update binds only the decision allowlist'
);

my $real_event_repository =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository->new;
my %event_args = (
    aggregate_type    => 'REQUEST',
    aggregate_id      => 2,
    request_id        => 2,
    loan_id           => undef,
    renewal_id        => undef,
    patron_id         => 52,
    biblio_id         => 1,
    actor_patron_id   => 53,
    source            => 'STAFF',
    correlation_id    => 'db421a13-f74a-4388-a681-897ec46156f4',
    occurred_at       => '2026-07-23 17:00:00',
    payload_json      => '{"request_id":2}',
    delivery_status   => 'NOT_REQUIRED',
    delivery_attempts => 0,
);
my $event_capture = Local::DecisionSQLCaptureDBH->new;
$real_event_repository->insert_request_approved_event(
    $event_capture,
    %event_args
);
is $event_capture->{calls}[0][2], 'REQUEST_APPROVED',
    'approval event type is repository-owned';
is_deeply(
    [ @{ $event_capture->{calls}[0] }[ 2 .. 16 ] ],
    [
        'REQUEST_APPROVED', 'REQUEST', 2, 2, undef, undef,
        52, 1, 53, 'STAFF',
        'db421a13-f74a-4388-a681-897ec46156f4',
        '2026-07-23 17:00:00', '{"request_id":2}',
        'NOT_REQUIRED', 0,
    ],
    'approval event binds the complete safe event contract'
);

my $rejection_event_capture = Local::DecisionSQLCaptureDBH->new;
$real_event_repository->insert_request_rejected_event(
    $rejection_event_capture,
    %event_args
);
is $rejection_event_capture->{calls}[0][2], 'REQUEST_REJECTED',
    'rejection event type is repository-owned';

for my $file (
    qw(
      Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Repository/RequestRepository.pm
      Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Repository/EventRepository.pm
      Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/RequestDecisionService.pm
    )
    )
{
    open my $fh, '<', $file or die $!;
    my $source = do { local $/; <$fh> };
    unlike $source, qr/\b(?:issues|old_issues|reserves|items)\b/i,
        "$file does not reference native Koha circulation tables";
    unlike $source,
        qr/INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)/i,
        "$file does not insert a loan or renewal";
}

open my $openapi_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json'
    or die $!;
my $openapi = do { local $/; <$openapi_fh> };
my @posts = $openapi =~ /"post"\s*:/ig;
is scalar @posts, 2, 'OpenAPI POST count is exactly two after HTTP exposure';

open my $tool_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/tool.tt'
    or die $!;
my $tool = do { local $/; <$tool_fh> };
open my $staff_js_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/static/js/jzl-digital-circulation.js'
    or die $!;
my $staff_js = do { local $/; <$staff_js_fh> };
like $tool, qr/Phase 2B .* request decisions/,
    'staff tool identifies the Phase 2B decision-only scope';
like $staff_js, qr/request\.status === 'PENDING'/,
    'staff decision controls are pending-only';
unlike $tool . $staff_js,
    qr/>\s*(?:Renew|Return|Revoke|Delete|Modify|Edit|Create|Issue)\s*</,
    'staff tool has no unrelated write controls';

done_testing;
