use Modern::Perl;
use Test::More;
use JSON::PP;
use lib '.', 't/lib';

use RequestDecisionFakes;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestDecisionService;

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
        requests => $args{requests} || [ pending_request() ],
    );
    my $request_repository =
        $args{request_repository}
        || Local::RequestDecisionRequestRepository->new;
    my $event_repository =
        $args{event_repository}
        || Local::RequestDecisionEventRepository->new;
    return (
        $service_class->new(
            dbh                => $dbh,
            request_repository => $request_repository,
            event_repository   => $event_repository,
            state_machine      => $args{state_machine},
            clock              => $args{clock} || sub { '2026-07-23 17:00:00' },
            json_encoder       => $args{json_encoder},
            diagnostic         => $args{diagnostic},
        ),
        $dbh,
        $request_repository,
        $event_repository,
    );
}

my ( $approval_service, $approval_dbh, $approval_requests, $approval_events ) =
    service();
my $approved = $approval_service->decide_request( command() );
ok $approved->{ok}, 'pending request approval succeeds';
is $approved->{outcome}, 'APPROVED', 'approval outcome is stable';
is $approved->{previous_status}, 'PENDING', 'approval reports prior status';
is $approved->{new_status}, 'APPROVED', 'approval reports new status';
is $approved->{previous_row_version}, 1, 'approval reports prior row version';
is $approved->{row_version}, 2, 'approval increments row version once';
is $approved->{correlation_id}, 'db421a13-f74a-4388-a681-897ec46156f4',
    'approval returns supplied correlation ID';
is_deeply $approval_dbh->{calls}, [qw(begin commit)],
    'approval owns one transaction';

my $approved_row = $approval_dbh->{requests}[0];
is $approved_row->{status}, 'APPROVED', 'authoritative status is approved';
is $approved_row->{approved_by}, 53, 'approval actor is stored';
is $approved_row->{approved_at}, '2026-07-23 17:00:00',
    'approval timestamp is stored';
is $approved_row->{row_version}, 2, 'authoritative row version increments';
ok !defined $approved_row->{rejected_at}, 'approval does not set rejection timestamp';
ok !defined $approved_row->{rejection_reason}, 'approval does not set rejection reason';
ok !exists $approved->{request}{portal_idempotency_key},
    'safe result excludes portal idempotency key';
is $approved->{request}{status}, 'APPROVED',
    'safe result contains authoritative status';

is scalar @{ $approval_dbh->{events} }, 1,
    'approval inserts exactly one event';
my $approval_event = $approval_dbh->{events}[0];
is_deeply(
    {
        map { $_ => $approval_event->{$_} }
            qw(
                event_type aggregate_type aggregate_id request_id loan_id renewal_id
                patron_id biblio_id actor_patron_id source correlation_id
                delivery_status delivery_attempts
            )
    },
    {
        event_type        => 'REQUEST_APPROVED',
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
        delivery_status   => 'NOT_REQUIRED',
        delivery_attempts => 0,
    },
    'approval event distinguishes actor from subject patron'
);
my $approval_payload = decode_json( $approval_event->{payload_json} );
is_deeply(
    $approval_payload,
    {
        actor_id          => 53,
        biblio_id         => 1,
        new_status        => 'APPROVED',
        portal_request_id => '1f7fe335-81f7-4dcf-bacd-1eb9d80b0770',
        previous_status   => 'PENDING',
        request_id        => 2,
        source            => 'STAFF',
        subject_patron_id => 52,
    },
    'approval payload contains only safe decision data'
);
is scalar @{ $approval_dbh->{loans} }, 0, 'approval creates no loan';
is scalar @{ $approval_dbh->{renewals} }, 0, 'approval creates no renewal';

my %rejection_command = (
    command(),
    decision       => 'REJECT',
    reason         => 'Protected course access is not currently eligible.',
    correlation_id => '65aacbb7-c0ad-4c95-9a58-8ca9cd01196b',
);
my ( $rejection_service, $rejection_dbh ) = service();
my $rejected = $rejection_service->decide_request(%rejection_command);
ok $rejected->{ok}, 'pending request rejection succeeds';
is $rejected->{outcome}, 'REJECTED', 'rejection outcome is stable';
is $rejected->{row_version}, 2, 'rejection increments row version once';
my $rejected_row = $rejection_dbh->{requests}[0];
is $rejected_row->{status}, 'REJECTED', 'authoritative status is rejected';
is $rejected_row->{rejected_by}, 53, 'rejection actor is stored';
is $rejected_row->{rejected_at}, '2026-07-23 17:00:00',
    'rejection timestamp is stored';
is $rejected_row->{rejection_reason},
    'Protected course access is not currently eligible.',
    'safe rejection reason is stored without truncation';
ok !defined $rejected_row->{approved_at}, 'rejection does not set approval timestamp';
is scalar @{ $rejection_dbh->{events} }, 1,
    'rejection inserts exactly one event';
is $rejection_dbh->{events}[0]{event_type}, 'REQUEST_REJECTED',
    'rejection uses request-rejected event type';
is decode_json( $rejection_dbh->{events}[0]{payload_json} )->{rejection_reason},
    'Protected course access is not currently eligible.',
    'rejection event contains the safe reason';
is scalar @{ $rejection_dbh->{loans} }, 0, 'rejection creates no loan';

my %approval_with_reason = (
    command(),
    reason         => 'Approved for the current teaching period.',
    correlation_id => 'dfec8864-577f-405c-9d59-0ab6f9723f96',
);
my ( $approval_reason_service, $approval_reason_dbh ) = service();
my $approval_reason =
    $approval_reason_service->decide_request(%approval_with_reason);
ok $approval_reason->{ok}, 'approval accepts an optional safe reason';
ok !defined $approval_reason_dbh->{requests}[0]{rejection_reason},
    'approval reason is not written into the rejection-only request column';
is decode_json( $approval_reason_dbh->{events}[0]{payload_json} )->{decision_reason},
    'Approved for the current teaching period.',
    'approval reason is preserved only in the audit payload';

for my $case (
    [ actor_id => undef, 'INVALID_INPUT' ],
    [ actor_id => '', 'INVALID_INPUT' ],
    [ actor_id => 0, 'INVALID_INPUT' ],
    [ actor_id => -1, 'INVALID_INPUT' ],
    [ actor_id => '5.3', 'INVALID_INPUT' ],
    [ actor_id => '1e3', 'INVALID_INPUT' ],
    [ actor_id => '53x', 'INVALID_INPUT' ],
    [ actor_id => [], 'INVALID_INPUT' ],
    [ request_id => undef, 'INVALID_INPUT' ],
    [ request_id => {}, 'INVALID_INPUT' ],
    [ expected_row_version => '1.0', 'INVALID_INPUT' ],
    [ expected_row_version => '1e0', 'INVALID_INPUT' ],
    [ expected_row_version => 0, 'INVALID_INPUT' ],
    [ decision => undef, 'INVALID_DECISION' ],
    [ decision => 'APPROVED', 'INVALID_DECISION' ],
    [ decision => 'approve', 'INVALID_DECISION' ],
    [ decision => [], 'INVALID_DECISION' ],
    [ correlation_id => 'not-a-uuid', 'INVALID_INPUT' ],
    [ correlation_id => {}, 'INVALID_INPUT' ],
) {
    my ( $field, $value, $code ) = @{$case};
    my %invalid = ( command(), $field => $value );
    my ( $invalid_service, $invalid_dbh ) = service();
    my $result = $invalid_service->decide_request(%invalid);
    ok !$result->{ok}, "$field malformed input is rejected";
    is $result->{code}, $code, "$field malformed input has stable code";
    is scalar @{ $invalid_dbh->{calls} }, 0,
        "$field malformed input starts no transaction";
}

for my $case (
    [ undef, 'missing rejection reason' ],
    [ '', 'empty rejection reason' ],
    [ '   ', 'blank rejection reason' ],
    [ [], 'array rejection reason' ],
    [ {}, 'hash rejection reason' ],
    [ "line one\nline two", 'control-character rejection reason' ],
    [ '<script>alert(1)</script>', 'HTML rejection reason' ],
    [ 'javascript:alert(1)', 'executable rejection reason' ],
    [ 'x' x 4097, 'oversized rejection reason' ],
) {
    my ( $reason, $label ) = @{$case};
    my %invalid = (
        command(),
        decision => 'REJECT',
        reason   => $reason,
    );
    my ( $invalid_service, $invalid_dbh ) = service();
    my $result = $invalid_service->decide_request(%invalid);
    ok !$result->{ok}, "$label is rejected";
    is $result->{code}, 'INVALID_REASON', "$label has stable code";
    is scalar @{ $invalid_dbh->{calls} }, 0,
        "$label starts no transaction";
}

my ( $blank_approval_service, $blank_approval_dbh ) = service();
my $blank_approval = $blank_approval_service->decide_request(
    command(),
    reason => '   ',
);
ok $blank_approval->{ok}, 'blank approval reason normalizes to null';
ok !exists decode_json(
    $blank_approval_dbh->{events}[0]{payload_json}
)->{decision_reason}, 'normalized blank approval reason is omitted from payload';

for my $case (
    [ [], 'REQUEST_NOT_FOUND', 'missing request' ],
    [
        [ pending_request(
                status      => 'APPROVED',
                approved_at => '2026-07-23 17:00:00',
                approved_by => 53,
                row_version => 2,
            ) ],
        'REQUEST_ALREADY_DECIDED',
        'already approved request'
    ],
    [
        [ pending_request(
                status           => 'REJECTED',
                rejected_at      => '2026-07-23 17:00:00',
                rejected_by      => 53,
                rejection_reason => 'Not eligible.',
                row_version      => 2,
            ) ],
        'REQUEST_ALREADY_DECIDED',
        'already rejected request'
    ],
    [
        [ pending_request(
                status       => 'CANCELLED',
                cancelled_at => '2026-07-23 17:00:00',
                row_version  => 2,
            ) ],
        'INVALID_STATE',
        'cancelled request'
    ],
    [ [ pending_request( status => 'EXPIRED' ) ], 'INVALID_STATE', 'expired request' ],
    [ [ pending_request( status => 'UNKNOWN' ) ], 'INVALID_STATE', 'unknown request state' ],
) {
    my ( $requests, $code, $label ) = @{$case};
    my ( $state_service, $state_dbh ) = service( requests => $requests );
    my $result = $state_service->decide_request( command() );
    ok !$result->{ok}, "$label is rejected";
    is $result->{code}, $code, "$label has stable code";
    is scalar @{ $state_dbh->{events} }, 0, "$label creates no event";
    is_deeply $state_dbh->{calls}, [qw(begin rollback)],
        "$label rolls back its decision transaction";
}

my ( $stale_service, $stale_dbh ) =
    service( requests => [ pending_request( row_version => 2 ) ] );
my $stale = $stale_service->decide_request( command() );
ok !$stale->{ok}, 'stale expected row version is rejected';
is $stale->{code}, 'VERSION_CONFLICT', 'stale version has stable code';
is scalar @{ $stale_dbh->{events} }, 0, 'stale version creates no event';

my $winner = pending_request(
    status      => 'APPROVED',
    approved_at => '2026-07-23 17:00:00',
    approved_by => 77,
    row_version => 2,
);
my $race_repository =
    Local::RequestDecisionRequestRepository->new( race_row => $winner );
my ( $race_service, $race_dbh ) =
    service( request_repository => $race_repository );
my $race = $race_service->decide_request( command() );
ok !$race->{ok}, 'concurrent decision winner is not overwritten';
is $race->{code}, 'REQUEST_ALREADY_DECIDED',
    'concurrent winner is classified as already decided';
is scalar @{ $race_dbh->{events} }, 0,
    'losing concurrent decision creates no event';
is scalar grep( { $_->[0] eq 'update_pending_decision' }
        @{ $race_repository->{calls} } ),
    1, 'guarded update is attempted only once';

my $version_winner = pending_request( row_version => 2 );
my $version_repository =
    Local::RequestDecisionRequestRepository->new( race_row => $version_winner );
my ( $version_service, $version_dbh ) =
    service( request_repository => $version_repository );
my $version_race = $version_service->decide_request( command() );
is $version_race->{code}, 'VERSION_CONFLICT',
    'concurrent pending row-version winner is classified safely';
is scalar @{ $version_dbh->{events} }, 0,
    'version conflict creates no event';

my $zero_repository =
    Local::RequestDecisionRequestRepository->new( update_result => 0 );
my ( $zero_service, $zero_dbh ) =
    service( request_repository => $zero_repository );
my $zero = $zero_service->decide_request( command() );
is $zero->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'unexplained zero-row guarded update fails closed';
is scalar @{ $zero_dbh->{events} }, 0,
    'unexplained zero-row update creates no event';

my ( $machine_service, $machine_dbh ) =
    service( state_machine => sub { return 0 } );
my $machine_result = $machine_service->decide_request( command() );
is $machine_result->{code}, 'INVALID_STATE',
    'injected state machine remains authoritative';
is scalar @{ $machine_dbh->{events} }, 0,
    'state-machine rejection creates no event';

done_testing;
