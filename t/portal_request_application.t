use Modern::Perl;
use Test::More;
use lib '.';

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalRequestApplication;

{
    package Local::ApplicationAuthorization;
    sub new { bless { response => $_[1], error => $_[2], log => $_[3] }, $_[0] }
    sub authorize_controller {
        my ( $self, $controller ) = @_;
        push @{ $self->{log} }, [ authorization => $controller ];
        die $self->{error} if defined $self->{error};
        return $self->{response};
    }

    package Local::ApplicationEligibility;
    sub new { bless { response => $_[1], error => $_[2], log => $_[3] }, $_[0] }
    sub check_biblio_eligibility {
        my ( $self, %args ) = @_;
        push @{ $self->{log} }, [ eligibility => { %args } ];
        die $self->{error} if defined $self->{error};
        return $self->{response};
    }

    package Local::ApplicationPersistence;
    sub new { bless { response => $_[1], error => $_[2], log => $_[3] }, $_[0] }
    sub create_portal_request {
        my ( $self, %args ) = @_;
        push @{ $self->{log} }, [ persistence => { %args } ];
        die $self->{error} if defined $self->{error};
        return $self->{response};
    }

    package Local::ApplicationController;
    sub new { bless {}, $_[0] }
}

my $class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalRequestApplication';
my $controller = Local::ApplicationController->new;

sub command {
    return (
        controller        => $controller,
        patron_id         => 123,
        biblio_id         => 456,
        portal_request_id => '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
        idempotency_key   => 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
        correlation_id    => 'db421a13-f74a-4388-a681-897ec46156f4',
    );
}

sub request {
    return {
        request_id        => 81,
        portal_request_id => '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
        patron_id         => 123,
        biblio_id         => 456,
        status            => 'PENDING',
        requested_at      => '2026-07-23 12:00:00',
        row_version       => 1,
    };
}

sub persistence_result {
    my ($outcome) = @_;
    my %flags = (
        CREATED           => [ 0, 0 ],
        IDEMPOTENT_REPLAY => [ 1, 0 ],
        DUPLICATE_PENDING => [ 0, 1 ],
    );
    return {
        ok                => 1,
        outcome           => $outcome,
        request           => request(),
        idempotent_replay => $flags{$outcome}[0],
        duplicate_pending => $flags{$outcome}[1],
        correlation_id    => 'db421a13-f74a-4388-a681-897ec46156f4',
    };
}

sub application {
    my (%args) = @_;
    my $log = $args{log} || [];
    my $authorization =
        $args{authorization}
        || Local::ApplicationAuthorization->new(
        { allowed => 1, actor_id => 9001 },
        undef,
        $log
        );
    my $patron_validator = $args{patron_validator} || sub {
        my ($patron_id) = @_;
        push @{$log}, [ patron => $patron_id ];
        return { found => 1, patron_id => $patron_id };
    };
    my $eligibility =
        $args{eligibility}
        || Local::ApplicationEligibility->new(
        { eligible => 1, biblio_id => 456 },
        undef,
        $log
        );
    my $persistence =
        $args{persistence}
        || Local::ApplicationPersistence->new(
        persistence_result('CREATED'),
        undef,
        $log
        );
    return (
        $class->new(
            authorization   => $authorization,
            patron_validator => $patron_validator,
            eligibility     => $eligibility,
            request_service => $persistence,
            diagnostic      => $args{diagnostic},
        ),
        $log,
    );
}

my ( $application, $log ) = application();
my $created = $application->create_request(
    command(),
    actor_id       => 777,
    source         => 'STAFF',
    request_body   => { actor_id => 888, source => 'BROWSER' },
);
ok $created->{ok}, 'valid orchestration succeeds';
is $created->{outcome}, 'CREATED', 'created outcome is preserved';
is_deeply $created->{request}, request(), 'authoritative request is preserved';
ok !$created->{idempotent_replay}, 'created result is not a replay';
ok !$created->{duplicate_pending}, 'created result is not a duplicate pending';
is $created->{correlation_id}, 'db421a13-f74a-4388-a681-897ec46156f4',
    'created result preserves correlation ID';
is_deeply(
    [ map { $_->[0] } @{$log} ],
    [qw(authorization patron eligibility persistence)],
    'authorization, patron, eligibility, and persistence run in required order'
);
is $log->[0][1], $controller, 'trusted controller is passed only to authorization';
is $log->[1][1], 123, 'subject patron ID is validated';
is_deeply $log->[2][1], { biblio_id => 456 }, 'eligibility receives only biblio ID';
is_deeply(
    $log->[3][1],
    {
        actor_id          => 9001,
        patron_id         => 123,
        biblio_id         => 456,
        portal_request_id => '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd',
        idempotency_key   => 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90',
        correlation_id    => 'db421a13-f74a-4388-a681-897ec46156f4',
        source            => 'PORTAL',
    },
    'persistence receives authorized actor, distinct subject, exact identifiers, and forced source'
);
ok !exists $log->[3][1]{content_id}, 'protected-content metadata is not passed to persistence';
isnt $log->[3][1]{actor_id}, $log->[3][1]{patron_id},
    'service actor and subject patron remain distinct';

for my $case (
    [
        'unauthenticated',
        { allowed => 0, code => 'AUTHENTICATION_REQUIRED' },
        undef,
        'AUTHENTICATION_REQUIRED',
    ],
    [
        'unlisted actor',
        { allowed => 0, code => 'SERVICE_ACCOUNT_NOT_AUTHORIZED', actor_id => 9002 },
        undef,
        'SERVICE_ACCOUNT_NOT_AUTHORIZED',
    ],
    [ 'malformed authorization', [], undef, 'DIGITAL_CIRCULATION_UNAVAILABLE' ],
    [
        'malformed authorized actor',
        { allowed => 1, actor_id => 0 },
        undef,
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
    [
        'authorization exception',
        undef,
        'Bearer secret at C:\koha\Auth.pm line 9',
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
) {
    my ( $label, $response, $error, $code ) = @{$case};
    my $case_log = [];
    my ($case_application) = application(
        log => $case_log,
        authorization =>
            Local::ApplicationAuthorization->new( $response, $error, $case_log ),
    );
    my $result = $case_application->create_request( command() );
    ok !$result->{ok}, "$label fails closed";
    is $result->{code}, $code, "$label has stable code";
    is_deeply [ map { $_->[0] } @{$case_log} ], ['authorization'],
        "$label performs no patron, content, or persistence work";
}

for my $invalid_patron (
    undef, '', 0, -1, '1.5', '1e3', '123x',
    'c43c218e-ff68-4b51-9f55-0f761ea99941', [], {},
) {
    my ( $case_application, $case_log ) = application();
    my $result = $case_application->create_request(
        command(),
        patron_id => $invalid_patron
    );
    ok !$result->{ok}, 'malformed patron ID fails';
    is $result->{code}, 'INVALID_INPUT', 'malformed patron ID has stable code';
    is_deeply [ map { $_->[0] } @{$case_log} ], ['authorization'],
        'malformed patron stops after authorization';
}

for my $case (
    [
        'patron not found',
        sub {
            my ($id) = @_;
            return { found => 0 };
        },
        'PATRON_NOT_FOUND',
    ],
    [ 'assert-style patron found', sub { return 1 }, undef ],
    [
        'patron helper not found',
        sub { die 'INVALID_PATRON at Validation.pm line 4' },
        'PATRON_NOT_FOUND',
    ],
    [
        'patron lookup exception',
        sub { die 'DBI:mysql password=secret at C:\koha\Patrons.pm line 4' },
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
    [
        'malformed patron result',
        sub { return [] },
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
) {
    my ( $label, $validator, $code ) = @{$case};
    my $case_log = [];
    my ($case_application) = application(
        log => $case_log,
        patron_validator => sub {
            push @{$case_log}, [ patron => $_[0] ];
            return $validator->(@_);
        },
    );
    my $result = $case_application->create_request( command() );
    if ( defined $code ) {
        ok !$result->{ok}, "$label fails closed";
        is $result->{code}, $code, "$label has stable code";
        is_deeply [ map { $_->[0] } @{$case_log} ], [qw(authorization patron)],
            "$label never reaches eligibility or persistence";
    }
    else {
        ok $result->{ok}, "$label is accepted";
        is_deeply [ map { $_->[0] } @{$case_log} ],
            [qw(authorization patron eligibility persistence)],
            "$label continues through orchestration";
    }
}

for my $invalid_biblio (
    undef, '', 0, -1, '1.5', '1e3', '456x',
    'c43c218e-ff68-4b51-9f55-0f761ea99941', [], {},
) {
    my ( $case_application, $case_log ) = application();
    my $result = $case_application->create_request(
        command(),
        biblio_id => $invalid_biblio
    );
    ok !$result->{ok}, 'malformed biblio ID fails';
    is $result->{code}, 'INVALID_INPUT', 'malformed biblio ID has stable code';
    is_deeply [ map { $_->[0] } @{$case_log} ], [qw(authorization patron)],
        'malformed biblio never reaches eligibility or persistence';
}

for my $case (
    [
        'biblio not found',
        { eligible => 0, code => 'BIBLIO_NOT_FOUND', reason => 'BIBLIO_NOT_FOUND' },
        undef,
        'BIBLIO_NOT_FOUND',
    ],
    [
        'content missing',
        { eligible => 0, code => 'CONTENT_NOT_ELIGIBLE', reason => 'MISSING_PROTECTED_CONTENT' },
        undef,
        'CONTENT_NOT_ELIGIBLE',
    ],
    [
        'content disabled',
        { eligible => 0, code => 'CONTENT_NOT_ELIGIBLE', reason => 'CONTENT_DISABLED' },
        undef,
        'CONTENT_NOT_ELIGIBLE',
    ],
    [
        'content lookup unavailable',
        { eligible => 0, code => 'CONTENT_NOT_ELIGIBLE', reason => 'CONTENT_LOOKUP_UNAVAILABLE' },
        undef,
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
    [ 'malformed eligibility result', [], undef, 'DIGITAL_CIRCULATION_UNAVAILABLE' ],
    [
        'eligibility exception',
        undef,
        'SELECT secret at /srv/koha/Eligibility.pm line 4',
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
) {
    my ( $label, $response, $error, $code ) = @{$case};
    my $case_log = [];
    my ($case_application) = application(
        log => $case_log,
        eligibility =>
            Local::ApplicationEligibility->new( $response, $error, $case_log ),
    );
    my $result = $case_application->create_request( command() );
    ok !$result->{ok}, "$label fails closed";
    is $result->{code}, $code, "$label has stable code";
    is_deeply [ map { $_->[0] } @{$case_log} ],
        [qw(authorization patron eligibility)],
        "$label never reaches persistence";
}

for my $outcome (qw(CREATED IDEMPOTENT_REPLAY DUPLICATE_PENDING)) {
    my $case_log = [];
    my ($case_application) = application(
        log => $case_log,
        persistence =>
            Local::ApplicationPersistence->new(
            persistence_result($outcome),
            undef,
            $case_log
            ),
    );
    my $result = $case_application->create_request( command() );
    ok $result->{ok}, "$outcome persistence result succeeds";
    is $result->{outcome}, $outcome, "$outcome semantics are preserved";
}

for my $case (
    [
        'idempotency conflict',
        { ok => 0, code => 'IDEMPOTENCY_CONFLICT' },
        undef,
        'IDEMPOTENCY_CONFLICT',
    ],
    [
        'persistence unavailable',
        { ok => 0, code => 'DIGITAL_CIRCULATION_UNAVAILABLE' },
        undef,
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
    [
        'invalid idempotency UUID',
        { ok => 0, code => 'INVALID_IDEMPOTENCY_KEY' },
        undef,
        'INVALID_IDEMPOTENCY_KEY',
    ],
    [ 'malformed persistence result', [], undef, 'DIGITAL_CIRCULATION_UNAVAILABLE' ],
    [
        'incomplete successful persistence result',
        {
            ok             => 1,
            outcome        => 'CREATED',
            request        => request(),
            correlation_id => 'db421a13-f74a-4388-a681-897ec46156f4',
        },
        undef,
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
    [
        'persistence exception',
        undef,
        'DBI INSERT password=secret at C:\koha\RequestService.pm line 7',
        'DIGITAL_CIRCULATION_UNAVAILABLE',
    ],
) {
    my ( $label, $response, $error, $code ) = @{$case};
    my $case_log = [];
    my ($case_application) = application(
        log => $case_log,
        persistence =>
            Local::ApplicationPersistence->new( $response, $error, $case_log ),
    );
    my $result = $case_application->create_request( command() );
    ok !$result->{ok}, "$label fails safely";
    is $result->{code}, $code, "$label has stable code";
    unlike join( ' ', grep { defined && !ref } values %{$result} ),
        qr{DBI|SELECT|INSERT|password|Bearer|token|DSN|[A-Za-z]:[\\/]|/srv/}i,
        "$label exposes no internal exception details";
}

my $diagnostic_log = [];
my ($diagnostic_application) = application(
    authorization =>
        Local::ApplicationAuthorization->new(
        undef,
        'AUTHORIZATION_EXPLODED',
        $diagnostic_log
        ),
    log => $diagnostic_log,
    diagnostic => sub { die 'diagnostic callback secret' },
);
my $diagnostic_result =
    $diagnostic_application->create_request( command() );
is $diagnostic_result->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'diagnostic callback failure cannot change safe result';

open my $application_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/PortalRequestApplication.pm'
    or die $!;
my $source = do { local $/; <$application_fh> };
unlike $source, qr/\b(?:SELECT|INSERT|UPDATE|DELETE)\b/i,
    'application service contains no SQL';
unlike $source, qr/\b(?:begin_work|commit|rollback)\b/,
    'application service does not own transactions';
unlike $source, qr/\bstatus\s*=>\s*\d{3}\b|\brender\s*\(/,
    'application service contains no HTTP status mapping';
unlike $source, qr/circulate_remaining_permissions/,
    'application service does not substitute general circulation permission';
like $source, qr/PortalServiceAuthorization.*?authorize_controller/s,
    'application service reuses exact portal authorization';
like $source, qr/RequestService.*?create_portal_request/s,
    'application service reuses persistence service';

open my $api_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json'
    or die $!;
my $api_source = do { local $/; <$api_fh> };
like $api_source, qr/"post"\s*:/i, 'POST /requests exposes the application service';

done_testing;
