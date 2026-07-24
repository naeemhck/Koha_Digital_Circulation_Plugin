use Modern::Perl;
use Test::More;
use lib '.', 't/lib';

use RequestCreationFakes;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestService;

{
    package Local::SQLCaptureDBH;
    sub new { bless { calls => [], row => $_[1] }, $_[0] }
    sub selectrow_hashref {
        my ( $self, $sql, $attr, @bind ) = @_;
        push @{ $self->{calls} }, [ select => $sql, @bind ];
        return { %{ $self->{row} } };
    }
    sub do {
        my ( $self, $sql, $attr, @bind ) = @_;
        push @{ $self->{calls} }, [ do => $sql, @bind ];
        return 1;
    }
    sub last_insert_id { return 81 }
}

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

sub authoritative {
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
        row_version            => 1,
        %overrides,
    };
}

sub service {
    my (%args) = @_;
    my $dbh = $args{dbh} || Local::RequestCreationDBH->new;
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
            diagnostic         => $args{diagnostic},
        ),
        $dbh,
    );
}

my $event_error =
    Local::RequestCreationEventRepository->new(
    insert_error => 'DBI password=secret at C:\koha\EventRepository.pm line 9' );
my ( $event_failure_service, $event_failure_dbh ) =
    service( event_repository => $event_error );
my $event_failure =
    $event_failure_service->create_portal_request( command() );
ok !$event_failure->{ok}, 'event insertion failure fails request';
is $event_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'event failure has safe code';
is_deeply $event_failure_dbh->{calls}, [qw(begin rollback)],
    'event failure rolls back without commit';
is scalar @{ $event_failure_dbh->{requests} }, 0,
    'rolled-back request does not remain';
is scalar @{ $event_failure_dbh->{events} }, 0,
    'failed event does not remain';

my $request_error =
    Local::RequestCreationRequestRepository->new(
    insert_error => 'DBI:mysql:database=koha password=secret at /srv/Request.pm line 3' );
my ( $request_failure_service, $request_failure_dbh ) =
    service( request_repository => $request_error );
my $request_failure =
    $request_failure_service->create_portal_request( command() );
ok !$request_failure->{ok}, 'request insertion failure fails safely';
is $request_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'request failure has safe code';
is_deeply $request_failure_dbh->{calls}, [qw(begin rollback)],
    'request failure rolls back';

my $commit_dbh = Local::RequestCreationDBH->new(
    commit_error => 'DBI commit failed, bearer token and DSN at C:\private.pm line 4'
);
my ( $commit_service, $commit_failure_dbh ) = service( dbh => $commit_dbh );
my $commit_failure = $commit_service->create_portal_request( command() );
ok !$commit_failure->{ok}, 'commit failure fails safely';
is $commit_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'commit failure has safe code';
is_deeply $commit_failure_dbh->{calls}, [qw(begin commit rollback)],
    'rollback is attempted after commit failure';
is scalar @{ $commit_failure_dbh->{requests} }, 0,
    'commit failure restores request state';
is scalar @{ $commit_failure_dbh->{events} }, 0,
    'commit failure restores event state';

for my $failure_result ( $event_failure, $request_failure, $commit_failure ) {
    unlike join( ' ', grep { defined && !ref } values %{$failure_result} ),
        qr{DBI|SELECT|INSERT|password|Bearer|token|DSN|[A-Za-z]:[\\/]|/srv/}i,
        'transaction failure result does not expose internal details';
}

my ( $diagnostic_service, $diagnostic_dbh ) = service(
    event_repository =>
        Local::RequestCreationEventRepository->new( insert_error => 'EVENT_FAILED' ),
    diagnostic => sub { die 'diagnostic transport failed with secret' },
);
my $diagnostic_failure =
    $diagnostic_service->create_portal_request( command() );
is $diagnostic_failure->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'diagnostic failure cannot replace the safe transaction result';
is_deeply $diagnostic_dbh->{calls}, [qw(begin rollback)],
    'diagnostic failure occurs only after rollback attempt';

for my $race (
    [
        'idempotency replay race',
        authoritative(),
        'IDEMPOTENT_REPLAY',
        1,
        0,
        undef,
    ],
    [
        'idempotency conflict race',
        authoritative( patron_id => 999 ),
        undef,
        undef,
        undef,
        'IDEMPOTENCY_CONFLICT',
    ],
    [
        'pending guard race',
        authoritative(
            portal_request_id      => '1dc488de-a531-4d1f-9bff-ca47eea69c84',
            portal_idempotency_key => 'f5d9c55f-0874-4ba9-9cbd-e45fa8541459',
        ),
        'DUPLICATE_PENDING',
        0,
        1,
        undef,
    ],
) {
    my ( $label, $authoritative, $outcome, $replay, $pending, $code ) = @{$race};
    my $repository =
        Local::RequestCreationRequestRepository->new( race => $authoritative );
    my ( $race_service, $race_dbh ) =
        service( request_repository => $repository );
    my $result = $race_service->create_portal_request( command() );
    if ($code) {
        ok !$result->{ok}, "$label returns failure";
        is $result->{code}, $code, "$label has stable conflict code";
    }
    else {
        ok $result->{ok}, "$label succeeds";
        is $result->{outcome}, $outcome, "$label is classified";
        is $result->{idempotent_replay}, $replay, "$label replay flag";
        is $result->{duplicate_pending}, $pending, "$label pending flag";
    }
    is scalar @{ $race_dbh->{events} }, 0, "$label inserts no event";
    ok scalar grep(
        {
            $_->[0] =~ /\Afind_/
                && ref( $_->[-1] ) eq 'HASH'
                && $_->[-1]{for_update}
        } @{ $repository->{calls} }
        ),
        "$label rereads with current-read locking";
    unlike join( ' ', grep { defined && !ref } values %{$result} ),
        qr{DBI|SELECT|INSERT|password|Bearer|token|DSN|[A-Za-z]:[\\/]|/srv/}i,
        "$label does not expose database details";
}

for my $file (
    qw(
      Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Repository/RequestRepository.pm
      Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Repository/EventRepository.pm
      Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/RequestService.pm
    )
) {
    open my $fh, '<', $file or die $!;
    my $source = do { local $/; <$fh> };
    unlike $source, qr/\b(?:issues|old_issues|reserves|items)\b/i,
        "$file does not reference native Koha circulation tables";
    unlike $source, qr/INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)/i,
        "$file does not write loans or renewals";
}

open my $request_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Repository/RequestRepository.pm'
    or die $!;
my $request_source = do { local $/; <$request_fh> };
like $request_source, qr/VALUES \(\?, \?, \?, \?, \?, \?, \?, \?\)/,
    'request insert uses placeholders';
like $request_source, qr/for_update.*?FOR UPDATE/s,
    'duplicate-race rereads support locking current reads';

open my $event_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Repository/EventRepository.pm'
    or die $!;
my $event_source = do { local $/; <$event_fh> };
like $event_source, qr/VALUES \(\?, \?, \?, \?, \?, \?, \?, \?, \?, \?, \?, \?, \?, \?, \?\)/,
    'event insert uses placeholders';

my $capture_dbh = Local::SQLCaptureDBH->new( authoritative() );
my $real_request_repository =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository->new;
$real_request_repository->find_by_idempotency_key(
    $capture_dbh,
    'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
    for_update => 1
);
like $capture_dbh->{calls}[0][1], qr/portal_idempotency_key = \? FOR UPDATE\z/,
    'real idempotency lookup uses a locking parameterized query';
is $capture_dbh->{calls}[0][2], 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
    'real idempotency lookup binds the key';

$real_request_repository->insert_pending_request(
    $capture_dbh,
    portal_request_id => '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
    idempotency_key   => 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
    source            => 'PORTAL',
    patron_id         => 123,
    biblio_id         => 456,
    status            => 'PENDING',
    requested_at      => '2026-07-23 12:00:00',
    row_version       => 1,
);
my ($request_insert) = grep { $_->[0] eq 'do' } @{ $capture_dbh->{calls} };
is_deeply(
    [ @{$request_insert}[ 2 .. 9 ] ],
    [
        '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
        'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
        'PORTAL', 123, 456, 'PENDING', '2026-07-23 12:00:00', 1,
    ],
    'real request repository binds the complete pending-request allowlist'
);

my $real_event_repository =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository->new;
$real_event_repository->insert_request_created_event(
    $capture_dbh,
    event_type        => 'REQUEST_CREATED',
    aggregate_type    => 'REQUEST',
    aggregate_id      => 81,
    request_id        => 81,
    loan_id           => undef,
    renewal_id        => undef,
    patron_id         => 123,
    biblio_id         => 456,
    actor_patron_id   => 9001,
    source            => 'PORTAL',
    correlation_id    => 'db421a13-f74a-4388-a681-897ec46156f4',
    occurred_at       => '2026-07-23 12:00:00',
    payload_json      => '{"request_id":81}',
    delivery_status   => 'NOT_REQUIRED',
    delivery_attempts => 0,
);
my $event_insert = $capture_dbh->{calls}[-1];
is_deeply(
    [ @{$event_insert}[ 2 .. 16 ] ],
    [
        'REQUEST_CREATED', 'REQUEST', 81, 81, undef, undef,
        123, 456, 9001, 'PORTAL',
        'db421a13-f74a-4388-a681-897ec46156f4',
        '2026-07-23 12:00:00', '{"request_id":81}',
        'NOT_REQUIRED', 0,
    ],
    'real event repository binds the complete request-created allowlist'
);

open my $api_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json'
    or die $!;
my $api_source = do { local $/; <$api_fh> };
like $api_source, qr/"post"\s*:/i, 'POST /requests is exposed by the HTTP adapter unit';

done_testing;
