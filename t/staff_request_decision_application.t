use Modern::Perl;
use Test::More;
use JSON::PP;
use lib '.';

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffRequestDecisionApplication;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;

{
    package Local::PortalConfigurationPlugin;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, reads => [] }, $class;
    }
    sub retrieve_data {
        my ( $self, $key ) = @_;
        push @{ $self->{reads} }, $key;
        die $self->{error} if $self->{error};
        return $self->{value};
    }
}

{
    package Local::StaffActor;
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }
    sub borrowernumber {
        die $_[0]{borrowernumber_error}
            if $_[0]{borrowernumber_error};
        return $_[0]{borrowernumber};
    }
    sub userid { return $_[0]{userid} }
}

{
    package Local::MissingBorrowernumberActor;
    sub new { return bless {}, $_[0] }
    sub userid { return 'ordinary' }
}

{
    # Mirrors Koha::Patron AUTOLOAD accessors: methods work, UNIVERSAL::can does not.
    package Local::AutoloadPatronActor;
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }
    sub AUTOLOAD {
        my ($self) = @_;
        my ($method) = our $AUTOLOAD =~ /::([^:]+)\z/;
        return if $method eq 'DESTROY';
        return $self->{$method} if exists $self->{$method};
        die "no such attribute $method\n";
    }
    sub can {
        my ( $self, $method ) = @_;
        return if $method eq 'borrowernumber' || $method eq 'userid';
        return UNIVERSAL::can( ref($self) || $self, $method );
    }
}

{
    package Local::StaffController;
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }
    sub stash {
        my ( $self, $key ) = @_;
        die $self->{stash_error} if $self->{stash_error};
        die 'unexpected stash key' unless $key eq 'koha.user';
        return $self->{actor};
    }
}

{
    package Local::StaffAuthorization;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, calls => [] }, $class;
    }
    sub authorize_controller {
        my ( $self, $controller ) = @_;
        push @{ $self->{calls} }, $controller;
        die $self->{error} if $self->{error};
        return $self->{result};
    }
}

{
    package Local::DecisionService;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, calls => [] }, $class;
    }
    sub decide_request {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, { %args };
        die $self->{error} if $self->{error};
        return $self->{result};
    }
}

my $authorization_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization';
my $application_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffRequestDecisionApplication';
my $correlation_id = 'db421a13-f74a-4388-a681-897ec46156f4';

sub actor {
    my (%args) = @_;
    $args{borrowernumber} = 53 unless exists $args{borrowernumber};
    $args{userid} = 'librarian53' unless exists $args{userid};
    return Local::StaffActor->new(%args);
}

sub controller {
    my (%args) = @_;
    $args{actor} = actor() unless exists $args{actor};
    return Local::StaffController->new(%args);
}

sub safe_request {
    my ( $status, %overrides ) = @_;
    my $approved = $status eq 'APPROVED';
    return {
        request_id             => 2,
        portal_request_id      => '1f7fe335-81f7-4dcf-bacd-1eb9d80b0770',
        source                 => 'PORTAL',
        patron_id              => 52,
        biblio_id              => 1,
        status                 => $status,
        requested_at           => '2026-07-23 16:54:49',
        approved_at            => $approved ? '2026-07-23 17:00:00' : undef,
        approved_by            => $approved ? 53 : undef,
        rejected_at            => $approved ? undef : '2026-07-23 17:00:00',
        rejected_by            => $approved ? undef : 53,
        rejection_reason       => $approved ? undef : 'Not eligible.',
        cancelled_at           => undef,
        created_at             => '2026-07-23 16:54:49',
        updated_at             => '2026-07-23 17:00:00',
        row_version            => 2,
        %overrides,
    };
}

sub success_result {
    my ( $status, %overrides ) = @_;
    return {
        ok                   => 1,
        outcome              => $status,
        request              => safe_request($status),
        previous_status      => 'PENDING',
        new_status           => $status,
        previous_row_version => 1,
        row_version          => 2,
        correlation_id       => $correlation_id,
        %overrides,
    };
}

sub application {
    my (%args) = @_;
    my $authorization =
        $args{authorization}
        || Local::StaffAuthorization->new(
            result => {
                allowed  => 1,
                actor_id => 53,
                code     => undef,
            }
        );
    my $decision_service =
        $args{decision_service}
        || Local::DecisionService->new(
            result => success_result('APPROVED')
        );
    my %constructor = (
        authorization    => $authorization,
        decision_service => $decision_service,
    );
    $constructor{command_validator} = $args{command_validator}
        if exists $args{command_validator};
    $constructor{diagnostic} = $args{diagnostic}
        if exists $args{diagnostic};
    return (
        $application_class->new(%constructor),
        $authorization,
        $decision_service
    );
}

sub command {
    return (
        controller           => controller(),
        request_id           => 2,
        expected_row_version => 1,
        decision             => 'APPROVE',
        reason               => undef,
        correlation_id       => $correlation_id,
    );
}

my @permission_checks;
my $staff_authorization = $authorization_class->new(
    service_account_checker => sub { return 0 },
    permission_checker => sub {
        my ( $trusted_actor, $permission ) = @_;
        push @permission_checks, [ $trusted_actor, $permission ];
        return 1;
    }
);
my $authorized = $staff_authorization->authorize_controller( controller() );
ok $authorized->{allowed}, 'authenticated permitted staff actor is authorized';
is $authorized->{actor_id}, 53,
    'staff actor borrowernumber is derived from trusted Koha user';
is scalar @permission_checks, 1, 'permission is checked exactly once';
isa_ok $permission_checks[0][0], 'Local::StaffActor';
is_deeply $permission_checks[0][1],
    { circulate => 'circulate_remaining_permissions' },
    'staff authorization uses the established circulation permission';
is_deeply $authorization_class->permission,
    { circulate => 'circulate_remaining_permissions' },
    'selected permission is exposed as a stable supported policy';

my $unauthenticated = $staff_authorization->authorize_controller(
    controller( actor => undef )
);
ok !$unauthenticated->{allowed}, 'missing Koha user is denied';
is $unauthenticated->{code}, 'AUTHENTICATION_REQUIRED',
    'missing Koha user has stable authentication code';

my $invalid_controller =
    $staff_authorization->authorize_controller( bless {}, 'Local::NoStash' );
is $invalid_controller->{code}, 'AUTHENTICATION_REQUIRED',
    'controller without trusted stash is unauthenticated';
my $broken_stash = $staff_authorization->authorize_controller(
    controller( stash_error => 'cookie=/private SQLSTATE' )
);
is $broken_stash->{code}, 'AUTHENTICATION_REQUIRED',
    'stash exception fails closed as unauthenticated';

for my $invalid_actor (
    Local::MissingBorrowernumberActor->new,
    actor( borrowernumber => undef ),
    actor( borrowernumber => 0 ),
    actor( borrowernumber => -1 ),
    actor( borrowernumber => '1.5' ),
    actor( borrowernumber => '1e3' ),
    actor( borrowernumber => '53staff' ),
    actor( borrowernumber => [] ),
    actor( borrowernumber_error => 'raw patron object failed' ),
    )
{
    my $denied = $staff_authorization->authorize_controller(
        controller( actor => $invalid_actor )
    );
    ok !$denied->{allowed}, 'malformed authenticated actor is denied';
    is $denied->{code}, 'STAFF_NOT_AUTHORIZED',
        'malformed authenticated actor has stable staff denial';
}

my $ordinary_authorization = $authorization_class->new(
    service_account_checker => sub { return 0 },
    permission_checker => sub { return 0 }
);
my $ordinary = $ordinary_authorization->authorize_controller( controller() );
is $ordinary->{code}, 'STAFF_NOT_AUTHORIZED',
    'ordinary patron without permission is denied';
my $portal_only = $ordinary_authorization->authorize_controller(
    controller(
        portal_service_account_ids => '53',
        actor => actor(),
    )
);
is $portal_only->{code}, 'STAFF_NOT_AUTHORIZED',
    'portal allowlist context alone cannot authorize a staff decision';
my $permission_exception = $authorization_class->new(
    service_account_checker => sub { return 0 },
    permission_checker => sub { die 'permission internals C:\secret SQL' }
)->authorize_controller( controller() );
is $permission_exception->{code}, 'STAFF_NOT_AUTHORIZED',
    'permission lookup exception fails closed';
for my $denied ( $ordinary, $portal_only, $permission_exception ) {
    is_deeply [ sort keys %{$denied} ],
        [qw(actor_id allowed code)],
        'staff denial exposes no permission or Koha-user details';
}

my $configured_plugin =
    Local::PortalConfigurationPlugin->new( value => '5,53,530' );
my @configured_permission_checks;
my $configured_authorization = $authorization_class->new(
    plugin => $configured_plugin,
    permission_checker => sub {
        push @configured_permission_checks, [@_];
        return 1;
    },
);
for my $configured_id ( 5, 53, 530 ) {
    my $denied = $configured_authorization->authorize_controller(
        controller(
            actor => actor(
                borrowernumber => $configured_id,
                userid         => "configured$configured_id",
            )
        )
    );
    is $denied->{code}, 'STAFF_NOT_AUTHORIZED',
        "configured portal actor $configured_id is denied staff decisions";
}
is scalar @configured_permission_checks, 0,
    'configured service actors are rejected before staff permission lookup';
is_deeply $configured_plugin->{reads},
    [ ( 'portal_service_account_ids' ) x 3 ],
    'staff exclusion reads only the authoritative plugin configuration key';

my $ordinary_librarian = $configured_authorization->authorize_controller(
    controller(
        actor => actor(
            borrowernumber => 51,
            userid         => 'librarian51',
        )
    )
);
ok $ordinary_librarian->{allowed},
    'ordinary librarian outside the portal allowlist remains authorized';
is $ordinary_librarian->{actor_id}, 51,
    'ordinary librarian borrowernumber is forwarded exactly';
is scalar @configured_permission_checks, 1,
    'ordinary librarian permission is checked exactly once';

my $substring_librarian = $configured_authorization->authorize_controller(
    controller(
        actor => actor(
            borrowernumber => 3,
            userid         => 'librarian3',
        )
    )
);
ok $substring_librarian->{allowed},
    'numeric membership uses exact identity rather than substring matching';

my $autoload_actor = Local::AutoloadPatronActor->new(
    borrowernumber => 51,
    userid         => 'naeem_super',
);
ok !$autoload_actor->can('borrowernumber'),
    'autoload-style patron reports no borrowernumber via can()';
ok !$autoload_actor->can('userid'),
    'autoload-style patron reports no userid via can()';
is $autoload_actor->borrowernumber, 51,
    'autoload-style patron still exposes borrowernumber by call';
my $autoload_authorized = $configured_authorization->authorize_controller(
    controller( actor => $autoload_actor )
);
ok $autoload_authorized->{allowed},
    'staff authorization accepts Koha AUTOLOAD-style patron accessors';
is $autoload_authorized->{actor_id}, 51,
    'autoload-style patron identity is preserved';

my $blank_permission_checks = 0;
my $blank_authorization = $authorization_class->new(
    plugin => Local::PortalConfigurationPlugin->new( value => '  ' ),
    permission_checker => sub {
        $blank_permission_checks++;
        return 1;
    },
);
my $blank_staff = $blank_authorization->authorize_controller(
    controller(
        actor => actor(
            borrowernumber => 51,
            userid         => 'librarian51',
        )
    )
);
ok $blank_staff->{allowed},
    'blank portal configuration excludes no otherwise authorized librarian';
is $blank_permission_checks, 1,
    'blank configuration preserves the independent staff permission check';

for my $configuration_failure (
    Local::PortalConfigurationPlugin->new( value => '5,53x,530' ),
    Local::PortalConfigurationPlugin->new( value => [] ),
    Local::PortalConfigurationPlugin->new(
        error => 'plugin path C:\secret SQLSTATE token=private'
    ),
) {
    my $permission_checks = 0;
    my $authorization = $authorization_class->new(
        plugin => $configuration_failure,
        permission_checker => sub {
            $permission_checks++;
            return 1;
        },
    );
    my $denied = $authorization->authorize_controller(
        controller(
            actor => actor(
                borrowernumber => 51,
                userid         => 'librarian51',
            )
        )
    );
    is $denied->{code}, 'STAFF_NOT_AUTHORIZED',
        'malformed or unavailable configuration fails closed';
    is $permission_checks, 0,
        'configuration failure stops before staff permission lookup';
    unlike join( ' ', grep { defined && !ref } values %{$denied} ),
        qr{SQLSTATE|token|[A-Za-z]:[\\/]|plugin path}i,
        'configuration failure exposes no raw diagnostic detail';
}

my $portal_authorization_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization';
my $portal_actor_53 = $portal_authorization_class->new(
    plugin => Local::PortalConfigurationPlugin->new( value => '53' )
)->authorize_controller(
    controller(
        actor => actor(
            borrowernumber => 53,
            userid         => 'service53',
        )
    )
);
ok $portal_actor_53->{allowed},
    'the same configured actor 53 remains authorized for portal request creation';

my $service_actor_permission_checks = 0;
my $service_actor_decision_service = Local::DecisionService->new(
    result => success_result('APPROVED')
);
my $service_actor_application = $application_class->new(
    authorization => $authorization_class->new(
        plugin => Local::PortalConfigurationPlugin->new( value => '53' ),
        permission_checker => sub {
            $service_actor_permission_checks++;
            return 1;
        },
    ),
    decision_service => $service_actor_decision_service,
);
my $service_actor_result =
    $service_actor_application->decide_request(command());
is $service_actor_result->{code}, 'STAFF_NOT_AUTHORIZED',
    'configured actor 53 receives the stable external staff denial';
is scalar @{ $service_actor_decision_service->{calls} }, 0,
    'configured actor denial never invokes decision persistence';
is $service_actor_permission_checks, 0,
    'configured actor circulation permission cannot override exclusion';

my ( $approval_application, $approval_authorization, $approval_service ) =
    application();
my $approval = $approval_application->decide_request(
    command(),
    reason    => '   ',
    actor_id  => 999,
    patron_id => 888,
);
ok $approval->{ok}, 'authorized approval succeeds';
is $approval->{outcome}, 'APPROVED', 'approval outcome is preserved';
is $approval->{previous_status}, 'PENDING',
    'approval previous status is preserved';
is $approval->{new_status}, 'APPROVED',
    'approval new status is preserved';
is $approval->{previous_row_version}, 1,
    'approval previous row version is preserved';
is $approval->{row_version}, 2, 'approval row version is preserved';
is $approval->{correlation_id}, $correlation_id,
    'approval correlation ID is preserved';
is scalar @{ $approval_service->{calls} }, 1,
    'approval invokes persistence exactly once';
is_deeply $approval_service->{calls}[0],
    {
        actor_id             => 53,
        request_id           => 2,
        expected_row_version => 1,
        decision             => 'APPROVE',
        reason               => undef,
        correlation_id       => $correlation_id,
    },
    'only trusted actor and validated command fields reach persistence';
ok !exists $approval_service->{calls}[0]{patron_id},
    'request subject cannot be supplied by staff command';
ok !exists $approval_service->{calls}[0]{body_actor_id},
    'body actor cannot be forwarded';
is $approval->{request}{patron_id}, 52,
    'request subject remains the persistence-owned patron';
is $approval->{request}{approved_by}, 53,
    'approved request actor matches authenticated librarian';
ok !exists $approval->{request}{portal_idempotency_key},
    'safe application result excludes idempotency key';

my $rejection_service = Local::DecisionService->new(
    result => success_result('REJECTED')
);
my ( $rejection_application ) =
    application( decision_service => $rejection_service );
my $rejection = $rejection_application->decide_request(
    command(),
    decision => 'REJECT',
    reason   => 'Not eligible.',
);
ok $rejection->{ok}, 'authorized rejection succeeds';
is $rejection->{outcome}, 'REJECTED', 'rejection outcome is preserved';
is_deeply $rejection_service->{calls}[0],
    {
        actor_id             => 53,
        request_id           => 2,
        expected_row_version => 1,
        decision             => 'REJECT',
        reason               => 'Not eligible.',
        correlation_id       => $correlation_id,
    },
    'rejection command reaches persistence without mutation';
is $rejection->{request}{rejection_reason}, 'Not eligible.',
    'safe rejection reason is returned';
is $rejection->{request}{rejected_by}, 53,
    'rejected request actor matches authenticated librarian';

for my $authorization_case (
    [
        Local::StaffAuthorization->new(
            result => {
                allowed => 0,
                code    => 'AUTHENTICATION_REQUIRED',
            }
        ),
        'AUTHENTICATION_REQUIRED',
        'application preserves authentication failure',
    ],
    [
        Local::StaffAuthorization->new(
            result => {
                allowed => 0,
                code    => 'STAFF_NOT_AUTHORIZED',
            }
        ),
        'STAFF_NOT_AUTHORIZED',
        'application preserves staff authorization failure',
    ],
    [
        Local::StaffAuthorization->new(
            error => 'permission hash password=secret'
        ),
        'STAFF_NOT_AUTHORIZED',
        'authorization exception becomes safe staff denial',
    ],
    )
{
    my $unreached_service = Local::DecisionService->new(
        result => success_result('APPROVED')
    );
    my ($app) = application(
        authorization    => $authorization_case->[0],
        decision_service => $unreached_service,
    );
    my $result = $app->decide_request(command());
    is $result->{code}, $authorization_case->[1], $authorization_case->[2];
    is scalar @{ $unreached_service->{calls} }, 0,
        "$authorization_case->[2] does not probe persistence";
}

my @invalid_commands = (
    [ request_id => undef, 'INVALID_INPUT', 'missing request ID' ],
    [ request_id => '2x', 'INVALID_INPUT', 'partial request ID' ],
    [ expected_row_version => 0, 'INVALID_INPUT', 'zero row version' ],
    [ expected_row_version => '1e0', 'INVALID_INPUT', 'exponent row version' ],
    [ decision => 'APPROVED', 'INVALID_DECISION', 'direct approved status' ],
    [ decision => 'DELETE', 'INVALID_DECISION', 'unsupported decision' ],
    [ correlation_id => 'not-a-uuid', 'INVALID_INPUT', 'malformed UUID' ],
    [ reason => '<b>approve</b>', 'INVALID_REASON', 'unsafe approval reason' ],
);
for my $case (@invalid_commands) {
    my ( $field, $value, $code, $label ) = @{$case};
    my $unreached = Local::DecisionService->new(
        result => success_result('APPROVED')
    );
    my ($app) = application( decision_service => $unreached );
    my %args = command();
    $args{$field} = $value;
    my $result = $app->decide_request(%args);
    is $result->{code}, $code, "$label is rejected";
    is scalar @{ $unreached->{calls} }, 0,
        "$label does not invoke persistence";
}

for my $case (
    [ undef, 'missing rejection reason' ],
    [ '   ', 'blank rejection reason' ],
    [ '<script>alert(1)</script>', 'unsafe rejection reason' ],
    [ 'x' x 4097, 'oversized rejection reason' ],
    [ {}, 'object rejection reason' ],
    )
{
    my $unreached = Local::DecisionService->new(
        result => success_result('REJECTED')
    );
    my ($app) = application( decision_service => $unreached );
    my $result = $app->decide_request(
        command(),
        decision => 'REJECT',
        reason   => $case->[0],
    );
    is $result->{code}, 'INVALID_REASON', "$case->[1] is rejected";
    is scalar @{ $unreached->{calls} }, 0,
        "$case->[1] does not invoke persistence";
}

my %preserved_failure = map { $_ => 1 } qw(
    INVALID_INPUT INVALID_DECISION INVALID_REASON REQUEST_NOT_FOUND
    VERSION_CONFLICT REQUEST_ALREADY_DECIDED INVALID_STATE
    DIGITAL_CIRCULATION_UNAVAILABLE INTERNAL_ERROR
);
for my $code ( sort keys %preserved_failure ) {
    my $service = Local::DecisionService->new(
        result => {
            ok      => 0,
            code    => $code,
            details => 'must not escape',
        }
    );
    my ($app) = application( decision_service => $service );
    my $result = $app->decide_request(command());
    is_deeply $result, { ok => 0, code => $code },
        "safe persistence failure $code is preserved without details";
}

for my $malformed (
    undef,
    [],
    {},
    { ok => 0, code => 'DBI_FAILED', sql => 'SELECT secret' },
    success_result( 'APPROVED', outcome => 'REJECTED' ),
    success_result( 'APPROVED', previous_status => 'REJECTED' ),
    success_result( 'APPROVED', row_version => 99 ),
    success_result( 'APPROVED', correlation_id => 'different' ),
    success_result(
        'APPROVED',
        request => safe_request( 'APPROVED', approved_by => 999 )
    ),
    success_result(
        'APPROVED',
        request => safe_request( 'APPROVED', rejection_reason => bless( {}, 'Local::RawUserObject' ) )
    ),
    success_result(
        'APPROVED',
        request => {
            %{ safe_request('APPROVED') },
            portal_idempotency_key => 'secret',
        }
    ),
    )
{
    my $service = Local::DecisionService->new( result => $malformed );
    my ($app) = application( decision_service => $service );
    my $result = $app->decide_request(command());
    if (
        ref($malformed) eq 'HASH'
        && $malformed->{ok}
        && ref( $malformed->{request} ) eq 'HASH'
        && exists $malformed->{request}{portal_idempotency_key}
        )
    {
        ok $result->{ok}, 'extra persistence request field is safely removed';
        ok !exists $result->{request}{portal_idempotency_key},
            'extra persistence request field does not escape';
    }
    else {
        is_deeply $result, { ok => 0, code => 'INTERNAL_ERROR' },
            'malformed persistence result fails closed';
    }
}

my $throwing_service = Local::DecisionService->new(
    error => 'DBI SQLSTATE DSN=C:\private Authorization: Bearer token'
);
my ($throwing_application) =
    application( decision_service => $throwing_service );
is_deeply $throwing_application->decide_request(command()),
    { ok => 0, code => 'INTERNAL_ERROR' },
    'decision-service exception is normalized without leakage';

my $validator_service = Local::DecisionService->new(
    result => success_result('APPROVED')
);
my ($validator_application) = application(
    decision_service  => $validator_service,
    command_validator => sub { die 'validator stack /srv/private.pm' },
    diagnostic        => sub { die 'diagnostic password=secret' },
);
is_deeply $validator_application->decide_request(command()),
    { ok => 0, code => 'INTERNAL_ERROR' },
    'validator and diagnostic exceptions cannot escape';
is scalar @{ $validator_service->{calls} }, 0,
    'validator exception does not invoke persistence';

for my $result (
    $unauthenticated, $invalid_controller, $broken_stash,
    $ordinary, $portal_only, $permission_exception,
    $throwing_application->decide_request(command()),
    $validator_application->decide_request(command()),
    )
{
    unlike join( ' ', grep { defined && !ref } values %{$result} ),
        qr{DBI|SQLSTATE|SELECT|UPDATE|INSERT|password|Authorization|Bearer|token|cookie|DSN|[A-Za-z]:[\\/]|/srv/|permission\s*=>}i,
        'application failure exposes no exception, credential, path, or permission details';
}

my $application_path =
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/StaffRequestDecisionApplication.pm';
open my $application_fh, '<', $application_path or die $!;
my $application_source = do { local $/; <$application_fh> };
unlike $application_source,
    qr/\b(?:SELECT|INSERT|UPDATE|DELETE|begin_work|commit|rollback)\b/i,
    'application contains no SQL or transaction logic';
unlike $application_source,
    qr/\b(?:render|status\s*=>\s*\d{3})\b/,
    'application contains no HTTP mapping';
unlike $application_source, qr/PortalServiceAuthorization|portal_service_account_ids/,
    'application delegates identity exclusion without performing portal authorization';
like $application_source,
    qr/StaffDecisionAuthorization->new\(\s*plugin\s*=>\s*\$args\{plugin\}/s,
    'application supplies the production plugin to staff authorization';
unlike $application_source,
    qr/INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)/i,
    'application contains no loan or renewal write';
like $application_source,
    qr/StaffDecisionAuthorization.*?RequestDecisionService/s,
    'application composes distinct staff authorization and decision persistence services';

my $authorization_path =
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/StaffDecisionAuthorization.pm';
open my $authorization_fh, '<', $authorization_path or die $!;
my $authorization_source = do { local $/; <$authorization_fh> };
like $authorization_source, qr/stash\('koha\.user'\)/,
    'staff actor comes from Koha controller context';
like $authorization_source,
    qr/PERMISSION_SUBPERM\s*=>\s*'circulate_remaining_permissions'.*?haspermission/s,
    'production staff authorization uses the established Koha permission';
like $authorization_source,
    qr/PortalServiceAuthorization->new\(.*?load_config.*?_parse_allowlist/s,
    'staff authorization reuses canonical portal configuration loading and parsing';
unlike $authorization_source,
    qr/PortalServiceAuthorization->authorize_controller/,
    'staff authorization never uses portal action authorization';
like $authorization_source,
    qr/_configured_portal_service_account.*?permission_checker/s,
    'configured service-account exclusion occurs before staff permission lookup';

open my $api_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json'
    or die $!;
my $api = JSON::PP::decode_json( do { local $/; <$api_fh> } );
my @posts =
    sort map { exists $api->{$_}{post} ? $_ : () } keys %{$api};
is_deeply \@posts,
    [ '/requests', '/requests/{request_id}/decision' ],
    'OpenAPI exposes only request creation and staff decision POST routes';

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

open my $schema_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation.pm'
    or die $!;
my $schema_source = do { local $/; <$schema_fh> };
like $schema_source, qr/our \$SCHEMA_VERSION\s*=\s*1;/,
    'schema version remains one';

done_testing;
