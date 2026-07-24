use Modern::Perl;
use Test::More;
use JSON::PP;
use lib '.', 't/lib';

use RequestCreationFakes;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestService;

my $service_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestService';

sub command {
    return (
        actor_id          => 9001,
        patron_id         => 123,
        biblio_id         => 456,
        portal_request_id => '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
        idempotency_key   => 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
        correlation_id    => 'db421a13-f74a-4388-a681-897ec46156f4',
        source            => 'PORTAL',
    );
}

sub fixture_request {
    my (%overrides) = @_;
    return {
        request_id             => 81,
        portal_request_id      => '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
        portal_idempotency_key => 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
        source                 => 'PORTAL',
        patron_id              => 123,
        biblio_id              => 456,
        status                 => 'PENDING',
        requested_at           => '2026-07-23 12:00:00',
        created_at             => '2026-07-23 12:00:00',
        updated_at             => '2026-07-23 12:00:00',
        row_version            => 1,
        %overrides,
    };
}

sub service {
    my (%args) = @_;
    my $dbh = $args{dbh} || Local::RequestCreationDBH->new(
        requests => $args{requests} || [],
    );
    my $request_repository =
        $args{request_repository}
        || Local::RequestCreationRequestRepository->new;
    my $event_repository =
        $args{event_repository}
        || Local::RequestCreationEventRepository->new;
    return (
        $service_class->new(
            dbh                => $dbh,
            request_repository => $request_repository,
            event_repository   => $event_repository,
            clock              => sub { '2026-07-23 12:00:00' },
        ),
        $dbh,
        $request_repository,
        $event_repository,
    );
}

my ( $service, $dbh, $request_repository, $event_repository ) = service();
my $created = $service->create_portal_request( command() );
ok $created->{ok}, 'new portal request succeeds';
is $created->{outcome}, 'CREATED', 'new request has CREATED outcome';
ok !$created->{idempotent_replay}, 'new request is not a replay';
ok !$created->{duplicate_pending}, 'new request is not a duplicate pending';
is $created->{correlation_id}, 'db421a13-f74a-4388-a681-897ec46156f4',
    'creation returns supplied correlation ID';
is_deeply $dbh->{calls}, [qw(begin commit)], 'service owns one transaction';

my $request = $created->{request};
is $request->{status}, 'PENDING', 'request is PENDING';
is $request->{source}, 'PORTAL', 'request source is PORTAL';
is $request->{row_version}, 1, 'request starts at row version 1';
is $request->{portal_request_id}, '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
    'portal request ID is persisted';
is $request->{portal_idempotency_key}, 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
    'idempotency key is persisted';
is $request->{patron_id}, 123, 'subject patron is persisted';
is $request->{biblio_id}, 456, 'requested biblio is persisted';
ok !defined $request->{approved_at}, 'no approval field is written';
ok !defined $request->{rejected_at}, 'no rejection field is written';

is scalar @{ $dbh->{events} }, 1, 'exactly one event is inserted';
my $event = $dbh->{events}[0];
is_deeply(
    {
        map { $_ => $event->{$_} }
            qw(
                event_type aggregate_type aggregate_id request_id loan_id renewal_id
                patron_id biblio_id actor_patron_id source correlation_id
                delivery_status delivery_attempts
            )
    },
    {
        event_type        => 'REQUEST_CREATED',
        aggregate_type    => 'REQUEST',
        aggregate_id      => 1,
        request_id        => 1,
        loan_id           => undef,
        renewal_id        => undef,
        patron_id         => 123,
        biblio_id         => 456,
        actor_patron_id   => 9001,
        source            => 'PORTAL',
        correlation_id    => 'db421a13-f74a-4388-a681-897ec46156f4',
        delivery_status   => 'NOT_REQUIRED',
        delivery_attempts => 0,
    },
    'audit event distinguishes service actor and subject patron'
);
my $expected_payload = {
    actor_id          => 9001,
    biblio_id         => 456,
    new_status        => 'PENDING',
    portal_request_id => '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
    previous_status   => undef,
    request_id        => 1,
    source            => 'PORTAL',
    subject_patron_id => 123,
};
is_deeply decode_json( $event->{payload_json} ), $expected_payload,
    'audit payload contains only safe operational data';
is $event->{payload_json}, JSON::PP->new->canonical(1)->utf8(1)->encode($expected_payload),
    'audit payload uses canonical JSON encoding';

my ( $replay_service, $replay_dbh ) =
    service( requests => [ fixture_request() ] );
my $replay = $replay_service->create_portal_request( command() );
ok $replay->{ok}, 'exact replay succeeds';
is $replay->{outcome}, 'IDEMPOTENT_REPLAY', 'exact replay is classified';
ok $replay->{idempotent_replay}, 'replay flag is set';
ok !$replay->{duplicate_pending}, 'duplicate-pending flag is clear for replay';
is $replay->{request}{request_id}, 81, 'replay returns authoritative request';
is scalar @{ $replay_dbh->{requests} }, 1, 'replay inserts no request';
is scalar @{ $replay_dbh->{events} }, 0, 'replay inserts no event';

my @different_key = command();
$different_key[9] = 'f5d9c55f-0874-4ba9-9cbd-e45fa8541459';
my ( $pending_service, $pending_dbh ) =
    service( requests => [ fixture_request() ] );
my $pending = $pending_service->create_portal_request(@different_key);
ok $pending->{ok}, 'existing pending request succeeds';
is $pending->{outcome}, 'DUPLICATE_PENDING', 'existing pending is classified';
ok !$pending->{idempotent_replay}, 'pending duplicate is not a replay';
ok $pending->{duplicate_pending}, 'pending duplicate flag is set';
is $pending->{request}{request_id}, 81, 'pending duplicate returns authoritative request';
is scalar @{ $pending_dbh->{events} }, 0, 'pending duplicate inserts no event';

for my $change (
    [ patron_id => 124 ],
    [ biblio_id => 457 ],
    [ portal_request_id => '1dc488de-a531-4d1f-9bff-ca47eea69c84' ],
) {
    my %changed = ( command(), @{$change} );
    my ($conflict_service) = service( requests => [ fixture_request() ] );
    my $conflict = $conflict_service->create_portal_request(%changed);
    ok !$conflict->{ok}, "changed $change->[0] conflicts";
    is $conflict->{code}, 'IDEMPOTENCY_CONFLICT',
        "changed $change->[0] has stable conflict code";
}

for my $case (
    [ actor_id => undef, 'INVALID_INPUT' ],
    [ actor_id => 0, 'INVALID_INPUT' ],
    [ patron_id => -1, 'INVALID_INPUT' ],
    [ biblio_id => '4.5', 'INVALID_INPUT' ],
    [ biblio_id => '1e3', 'INVALID_INPUT' ],
    [ actor_id => '90x', 'INVALID_INPUT' ],
    [ actor_id => [], 'INVALID_INPUT' ],
    [ portal_request_id => 'not-a-uuid', 'INVALID_INPUT' ],
    [ idempotency_key => 'not-a-uuid', 'INVALID_IDEMPOTENCY_KEY' ],
    [ correlation_id => {}, 'INVALID_INPUT' ],
    [ source => 'STAFF', 'INVALID_INPUT' ],
) {
    my ( $field, $value, $code ) = @{$case};
    my %invalid = ( command(), $field => $value );
    my ( $invalid_service, $invalid_dbh ) = service();
    my $result = $invalid_service->create_portal_request(%invalid);
    ok !$result->{ok}, "$field malformed input is rejected";
    is $result->{code}, $code, "$field malformed input has stable code";
    is scalar @{ $invalid_dbh->{calls} }, 0, "$field malformed input starts no transaction";
}

open my $source_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/RequestService.pm'
    or die $!;
my $source = do { local $/; <$source_fh> };
unlike $source, qr/Koha::Patrons|Koha::Biblios|EbookContentEligibility|PortalServiceAuthorization/,
    'persistence service does not repeat orchestration-layer validation';

done_testing;
