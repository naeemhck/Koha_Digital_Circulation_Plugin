use Modern::Perl;
use Test::More;
use lib '.';

BEGIN {
    package C4::Context;
    sub dbh { die 'unexpected C4::Context->dbh in staff loan issuance application unit test' }
    $INC{'C4/Context.pm'} = __FILE__;
}

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication;
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
    package Local::IssuanceService;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, calls => [] }, $class;
    }
    sub issue_loan {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, { %args };
        die $self->{error} if $self->{error};
        return $self->{result};
    }
}

my $authorization_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization';
my $application_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication';

sub actor {
    my (%args) = @_;
    $args{borrowernumber} = 51 unless exists $args{borrowernumber};
    $args{userid} = 'librarian51' unless exists $args{userid};
    return Local::StaffActor->new(%args);
}

sub controller {
    my (%args) = @_;
    $args{actor} = actor() unless exists $args{actor};
    return Local::StaffController->new(%args);
}

sub safe_loan {
    my (%overrides) = @_;
    return {
        loan_id     => 9,
        request_id  => 6,
        patron_id   => 52,
        biblio_id   => 1,
        status      => 'ACTIVE',
        started_at  => '2026-07-25 10:00:00',
        due_at      => '2026-08-08 10:00:00',
        row_version => 1,
        %overrides,
    };
}

sub success_result {
    my (%overrides) = @_;
    my $loan = safe_loan(%overrides);
    return {
        ok   => 1,
        loan => $loan,
    };
}

sub application {
    my (%args) = @_;
    my $authorization =
        $args{authorization}
        || Local::StaffAuthorization->new(
            result => {
                allowed  => 1,
                actor_id => 51,
                code     => undef,
            }
        );
    my $issuance_service =
        $args{issuance_service}
        || Local::IssuanceService->new( result => success_result() );
    my %constructor = (
        authorization    => $authorization,
        issuance_service => $issuance_service,
    );
    $constructor{diagnostic} = $args{diagnostic}
        if exists $args{diagnostic};
    return (
        $application_class->new(%constructor),
        $authorization,
        $issuance_service
    );
}

sub command {
    return (
        controller => controller(),
        request_id => 6,
    );
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

for my $auth_case (
    [
        Local::StaffAuthorization->new(
            result => {
                allowed => 0,
                code    => 'AUTHENTICATION_REQUIRED',
            }
        ),
        'AUTHENTICATION_REQUIRED',
        'missing stash user',
    ],
    [
        Local::StaffAuthorization->new(
            result => {
                allowed => 0,
                code    => 'AUTHENTICATION_REQUIRED',
            }
        ),
        'AUTHENTICATION_REQUIRED',
        'undefined user',
    ],
    )
{
    my ( $auth, $code, $label ) = @{$auth_case};
    my $service = Local::IssuanceService->new( result => success_result() );
    my ($app) = application(
        authorization    => $auth,
        issuance_service => $service,
    );
    my $result = $app->issue_loan(command());
    ok !$result->{ok}, "$label is denied";
    is $result->{code}, $code, "$label has stable authentication code";
    is scalar @{ $service->{calls} }, 0,
        "$label never invokes LoanIssuanceService";
}

my $malformed_auth = $authorization_class->new(
    service_account_checker => sub { return 0 },
    permission_checker      => sub { return 1 },
);
for my $invalid_actor (
    Local::MissingBorrowernumberActor->new,
    actor( borrowernumber => undef ),
    actor( borrowernumber => 0 ),
    actor( borrowernumber => -1 ),
    actor( borrowernumber => '1.5' ),
    actor( borrowernumber => '1e3' ),
    actor( borrowernumber => '51staff' ),
    actor( borrowernumber => [] ),
    actor( borrowernumber_error => 'raw patron object failed' ),
    )
{
    my $service = Local::IssuanceService->new( result => success_result() );
    my $app = $application_class->new(
        authorization    => $malformed_auth,
        issuance_service => $service,
    );
    my $result = $app->issue_loan(
        controller => controller( actor => $invalid_actor ),
        request_id => 6,
    );
    ok !$result->{ok}, 'malformed authenticated actor is denied';
    is $result->{code}, 'STAFF_NOT_AUTHORIZED',
        'malformed authenticated actor has stable staff denial';
    is scalar @{ $service->{calls} }, 0,
        'malformed actor never invokes LoanIssuanceService';
}

my $missing_user_service = Local::IssuanceService->new( result => success_result() );
my $missing_user_app = $application_class->new(
    authorization => $authorization_class->new(
        service_account_checker => sub { return 0 },
        permission_checker      => sub { return 1 },
    ),
    issuance_service => $missing_user_service,
);
my $missing_user = $missing_user_app->issue_loan(
    controller => controller( actor => undef ),
    request_id => 6,
);
is $missing_user->{code}, 'AUTHENTICATION_REQUIRED',
    'missing Koha user has stable authentication code';
is scalar @{ $missing_user_service->{calls} }, 0,
    'missing Koha user never invokes LoanIssuanceService';

# ---------------------------------------------------------------------------
# Staff authorization / portal-service exclusion
# ---------------------------------------------------------------------------

my $configured_plugin =
    Local::PortalConfigurationPlugin->new( value => '53' );
my $service_actor_permission_checks = 0;
my $service_actor_issuance = Local::IssuanceService->new(
    result => success_result()
);
my $service_actor_application = $application_class->new(
    authorization => $authorization_class->new(
        plugin => $configured_plugin,
        permission_checker => sub {
            $service_actor_permission_checks++;
            return 1;
        },
    ),
    issuance_service => $service_actor_issuance,
);
my $service_actor_result = $service_actor_application->issue_loan(
    controller => controller(
        actor => actor(
            borrowernumber => 53,
            userid         => 'service53',
        )
    ),
    request_id => 6,
);
is $service_actor_result->{code}, 'STAFF_NOT_AUTHORIZED',
    'configured actor 53 receives STAFF_NOT_AUTHORIZED for loan issuance';
is scalar @{ $service_actor_issuance->{calls} }, 0,
    'configured actor 53 never invokes LoanIssuanceService';
is $service_actor_permission_checks, 0,
    'configured actor circulation permission cannot override exclusion';
is_deeply [ sort keys %{$service_actor_result} ],
    [qw(code ok)],
    'actor 53 denial discloses no request existence information';

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
    'portal allowlist still authorizes actor 53 for portal request creation only';

my @permission_checks;
my $librarian_issuance = Local::IssuanceService->new( result => success_result() );
my $librarian_application = $application_class->new(
    authorization => $authorization_class->new(
        plugin => $configured_plugin,
        permission_checker => sub {
            my ( $trusted_actor, $permission ) = @_;
            push @permission_checks, [ $trusted_actor, $permission ];
            return 1;
        },
    ),
    issuance_service => $librarian_issuance,
);
my $librarian_result = $librarian_application->issue_loan(
    controller => controller(
        actor => actor(
            borrowernumber => 51,
            userid         => 'librarian51',
        )
    ),
    request_id => 6,
);
ok $librarian_result->{ok},
    'actor 51 outside portal allowlist is authorized for loan issuance';
is scalar @{ $librarian_issuance->{calls} }, 1,
    'actor 51 reaches LoanIssuanceService exactly once';
is_deeply $librarian_issuance->{calls}[0],
    {
        request_id => 6,
        actor_id   => 51,
    },
    'actor 51 is forwarded exactly as trusted actor_id';
is scalar @permission_checks, 1,
    'ordinary librarian permission is checked exactly once';
is_deeply $permission_checks[0][1],
    { circulate => 'circulate_remaining_permissions' },
    'staff issuance uses circulate_remaining_permissions';

my $ordinary_issuance = Local::IssuanceService->new( result => success_result() );
my $ordinary_application = $application_class->new(
    authorization => $authorization_class->new(
        service_account_checker => sub { return 0 },
        permission_checker      => sub { return 0 },
    ),
    issuance_service => $ordinary_issuance,
);
my $ordinary_result = $ordinary_application->issue_loan(command());
is $ordinary_result->{code}, 'STAFF_NOT_AUTHORIZED',
    'ordinary staff without permission is denied';
is scalar @{ $ordinary_issuance->{calls} }, 0,
    'ordinary staff denial never invokes LoanIssuanceService';

# ---------------------------------------------------------------------------
# Input validation (authorized actor)
# ---------------------------------------------------------------------------

my ( $validation_app, undef, $validation_service ) = application();
for my $invalid_request_id (
    undef, 0, -1, 1.5, '1e3', '6x', [], {}, \*STDOUT, bless( \do { my $o = 1 }, 'Local::Boolean' )
    )
{
    my $result = $validation_app->issue_loan(
        controller => controller(),
        defined $invalid_request_id
        ? ( request_id => $invalid_request_id )
        : (),
    );
    is $result->{code}, 'INVALID_INPUT',
        'invalid request_id is rejected as INVALID_INPUT';
}

# whitespace-padded, leading zero, and other noncanonical forms
for my $invalid_request_id ( ' 6 ', '06', '+6', '' ) {
    my $result = $validation_app->issue_loan(
        controller => controller(),
        request_id => $invalid_request_id,
    );
    is $result->{code}, 'INVALID_INPUT',
        "noncanonical request_id is rejected";
}
is scalar @{ $validation_service->{calls} }, 0,
    'invalid request_id values never reach LoanIssuanceService';

for my $forbidden_field (
    [ actor_id              => 999 ],
    [ patron_id             => 888 ],
    [ biblio_id             => 777 ],
    [ due_at                => '2026-08-08 10:00:00' ],
    [ status                => 'ACTIVE' ],
    [ started_at            => '2026-07-25 10:00:00' ],
    [ portal_ebook_uuid     => 'uuid' ],
    [ expected_request_row_version => 1 ],
    [ duration              => 14 ],
    [ returned_at           => undef ],
    [ revoked_at            => undef ],
    [ expired_at            => undef ],
    [ approved_by           => 51 ],
    [ renewal_count         => 0 ],
    [ correlation_id        => 'db421a13-f74a-4388-a681-897ec46156f4' ],
    )
{
    my ( $field, $value ) = @{$forbidden_field};
    my $service = Local::IssuanceService->new( result => success_result() );
    my ($app) = application( issuance_service => $service );
    my $result = $app->issue_loan(
        command(),
        $field => $value,
    );
    is $result->{code}, 'INVALID_INPUT',
        "caller-supplied $field is rejected as INVALID_INPUT";
    is scalar @{ $service->{calls} }, 0,
        "caller-supplied $field never reaches LoanIssuanceService";
}

# ---------------------------------------------------------------------------
# Trusted command forwarding / successful result
# ---------------------------------------------------------------------------

my ( $success_app, $success_auth, $success_service ) = application();
my $success = $success_app->issue_loan(
    command(),
);
ok $success->{ok}, 'authorized issuance succeeds';
is_deeply $success_service->{calls}[0],
    {
        request_id => 6,
        actor_id   => 51,
    },
    'service receives only validated request_id and trusted actor_id';
is_deeply [ sort keys %{ $success->{loan} } ],
    [
    qw(biblio_id due_at loan_id patron_id request_id row_version started_at status)
    ],
    'success returns only safe allowlisted loan fields';
is $success->{loan}{status}, 'ACTIVE', 'success preserves ACTIVE status';
is $success->{loan}{request_id}, 6, 'success preserves request_id';
is $success->{loan}{loan_id}, 9, 'success preserves loan_id';
ok !exists $success->{loan}{approved_by},
    'optional service fields outside response allowlist are not forwarded';
ok !exists $success->{actor_id},
    'application success does not expose actor_id';

my $service_with_known_extras = Local::IssuanceService->new(
    result => {
        ok   => 1,
        loan => {
            %{ safe_loan() },
            returned_at    => undef,
            revoked_at     => undef,
            expired_at     => undef,
            approved_by    => 51,
            renewal_count  => 0,
            created_at     => '2026-07-25 10:00:00',
            updated_at     => '2026-07-25 10:00:00',
        },
    }
);
my ($extras_app) = application( issuance_service => $service_with_known_extras );
my $extras = $extras_app->issue_loan(command());
ok $extras->{ok}, 'known service loan fields are accepted and filtered';
is_deeply [ sort keys %{ $extras->{loan} } ],
    [
    qw(biblio_id due_at loan_id patron_id request_id row_version started_at status)
    ],
    'known extra service fields are stripped from the application result';

# ---------------------------------------------------------------------------
# Service failure forwarding
# ---------------------------------------------------------------------------

for my $code (
    qw(
        REQUEST_NOT_FOUND
        REQUEST_NOT_APPROVED
        LOAN_ALREADY_EXISTS
        PROTECTED_CONTENT_UNAVAILABLE
        INVALID_MAPPING
        INVALID_LOAN_PERIOD
        DIGITAL_CIRCULATION_UNAVAILABLE
        INTERNAL_ERROR
        INVALID_INPUT
    )
    )
{
    my $service = Local::IssuanceService->new(
        result => {
            ok   => 0,
            code => $code,
        }
    );
    my ($app) = application( issuance_service => $service );
    my $result = $app->issue_loan(command());
    ok !$result->{ok}, "service failure $code is not ok";
    is $result->{code}, $code, "service failure $code is forwarded";
    is_deeply [ sort keys %{$result} ], [qw(code ok)],
        "service failure $code exposes no raw details";
}

# ---------------------------------------------------------------------------
# Malformed service results
# ---------------------------------------------------------------------------

for my $malformed (
    [ undef, 'undefined result' ],
    [ [], 'non-hash result' ],
    [ { ok => 1 }, 'ok without loan' ],
    [
        {
            ok   => 1,
            loan => safe_loan( loan_id => undef ),
        },
        'loan without loan_id',
    ],
    [
        {
            ok   => 1,
            loan => {
                %{ safe_loan() },
                content_path => '/secret/protected.pdf',
            },
        },
        'loan with unsafe additional fields',
    ],
    [
        {
            ok   => 1,
            loan => safe_loan( status => 'PENDING' ),
        },
        'malformed status',
    ],
    [
        {
            ok   => 1,
            loan => safe_loan( started_at => 'not-a-timestamp' ),
        },
        'malformed timestamps',
    ],
    [
        {
            ok   => 1,
            loan => safe_loan( due_at => '2026-07-01 10:00:00' ),
        },
        'due_at not after started_at',
    ],
    [
        {
            ok   => 0,
            code => 'SQLSTATE_SECRET',
        },
        'unknown failure code',
    ],
    )
{
    my ( $service_result, $label ) = @{$malformed};
    my $service = Local::IssuanceService->new( result => $service_result );
    my ($app) = application( issuance_service => $service );
    my $result = $app->issue_loan(command());
    ok !$result->{ok}, "$label fails closed";
    is $result->{code}, 'INTERNAL_ERROR',
        "$label returns INTERNAL_ERROR";
    unlike join( ' ', grep { defined && !ref } values %{$result} ),
        qr{SQLSTATE|secret|protected\.pdf|token|[A-Za-z]:[\\/]}i,
        "$label exposes no raw diagnostic detail";
}

# ---------------------------------------------------------------------------
# Exception handling / diagnostics
# ---------------------------------------------------------------------------

my $auth_throw_service = Local::IssuanceService->new( result => success_result() );
my ($auth_throw_app) = application(
    authorization => Local::StaffAuthorization->new(
        error => 'permission hash password=secret'
    ),
    issuance_service => $auth_throw_service,
);
my $auth_throw = $auth_throw_app->issue_loan(command());
is $auth_throw->{code}, 'INTERNAL_ERROR',
    'authorization dependency exception fails closed';
is scalar @{ $auth_throw_service->{calls} }, 0,
    'authorization exception never invokes LoanIssuanceService';
unlike join( ' ', grep { defined && !ref } values %{$auth_throw} ),
    qr{password|secret}i,
    'authorization exception exposes no raw details';

my $service_throw = Local::IssuanceService->new(
    error => 'dbh DSN=mysql://secret SQLSTATE'
);
my ($service_throw_app) = application( issuance_service => $service_throw );
my $service_exception = $service_throw_app->issue_loan(command());
is $service_exception->{code}, 'INTERNAL_ERROR',
    'service exception becomes INTERNAL_ERROR';
unlike join( ' ', grep { defined && !ref } values %{$service_exception} ),
    qr{DSN|SQLSTATE|secret}i,
    'service exception exposes no raw details';

my @diagnostics;
my $diag_ok_service = Local::IssuanceService->new(
    result => {
        ok   => 0,
        code => 'REQUEST_NOT_FOUND',
    }
);
my ($diag_app) = application(
    issuance_service => $diag_ok_service,
    diagnostic       => sub {
        my ($category) = @_;
        push @diagnostics, $category;
        die 'diagnostic sink failed';
    },
);
my $diag_result = $diag_app->issue_loan(command());
is $diag_result->{code}, 'REQUEST_NOT_FOUND',
    'diagnostic callback failure does not replace the safe result';
ok scalar( grep { $_ eq 'issuance_service_failure' } @diagnostics ),
    'issuance_service_failure diagnostic is emitted';

my @auth_diagnostics;
my ($auth_diag_app) = application(
    authorization => Local::StaffAuthorization->new(
        result => {
            allowed => 0,
            code    => 'STAFF_NOT_AUTHORIZED',
        }
    ),
    issuance_service => Local::IssuanceService->new( result => success_result() ),
    diagnostic       => sub {
        push @auth_diagnostics, $_[0];
        die 'diagnostic sink failed';
    },
);
my $auth_diag = $auth_diag_app->issue_loan(command());
is $auth_diag->{code}, 'STAFF_NOT_AUTHORIZED',
    'authorization failure remains safe when diagnostics throw';
ok scalar( grep { $_ eq 'staff_not_authorized' } @auth_diagnostics ),
    'staff_not_authorized diagnostic is emitted';

# ---------------------------------------------------------------------------
# Trust-boundary regressions
# ---------------------------------------------------------------------------

my $portal_only_issuance = Local::IssuanceService->new( result => success_result() );
my $portal_only_app = $application_class->new(
    authorization => $authorization_class->new(
        plugin => Local::PortalConfigurationPlugin->new( value => '53' ),
        permission_checker => sub { return 0 },
    ),
    issuance_service => $portal_only_issuance,
);
is $portal_only_app->issue_loan(
    controller => controller(
        actor => actor(
            borrowernumber => 53,
            userid         => 'service53',
        )
    ),
    request_id => 6,
)->{code}, 'STAFF_NOT_AUTHORIZED',
    'portal allowlist never authorizes staff loan issuance';

my $no_allowlist_needed = Local::IssuanceService->new( result => success_result() );
my $no_allowlist_app = $application_class->new(
    authorization => $authorization_class->new(
        plugin => Local::PortalConfigurationPlugin->new( value => '53' ),
        permission_checker => sub { return 1 },
    ),
    issuance_service => $no_allowlist_needed,
);
ok $no_allowlist_app->issue_loan(
    controller => controller(
        actor => actor(
            borrowernumber => 51,
            userid         => 'librarian51',
        )
    ),
    request_id => 6,
)->{ok},
    'ordinary librarian does not need portal allowlist membership';

my $caller_actor_service = Local::IssuanceService->new( result => success_result() );
my ($caller_actor_app) = application(
    authorization => Local::StaffAuthorization->new(
        result => {
            allowed  => 1,
            actor_id => 51,
            code     => undef,
        }
    ),
    issuance_service => $caller_actor_service,
);
my $caller_actor_denied = $caller_actor_app->issue_loan(
    command(),
    actor_id => 999,
);
is $caller_actor_denied->{code}, 'INVALID_INPUT',
    'caller-supplied actor_id never grants authority';
is scalar @{ $caller_actor_service->{calls} }, 0,
    'caller-supplied actor_id never replaces authenticated actor';

# ---------------------------------------------------------------------------
# Source contract for application module
# ---------------------------------------------------------------------------

open my $source_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Service/StaffLoanIssuanceApplication.pm'
    or die $!;
my $source = do { local $/; <$source_fh> };
close $source_fh;

like $source,
    qr/StaffDecisionAuthorization->new\(\s*plugin\s*=>\s*\$args\{plugin\}/s,
    'application reuses StaffDecisionAuthorization with plugin configuration';
like $source, qr/\$self->\{issuance_service\}->issue_loan/,
    'application delegates to LoanIssuanceService';
like $source, qr/request_id\s*=>\s*\$command->\{request_id\}/,
    'application forwards validated request_id';
like $source, qr/actor_id\s*=>\s*\$actor_id/,
    'application forwards trusted actor_id';
unlike $source, qr/PortalServiceAuthorization/,
    'application does not authorize through PortalServiceAuthorization';
unlike $source,
    qr/\b(?:SELECT|INSERT|UPDATE|DELETE)\b|\b(?:begin_work|commit|rollback)\b|\bstatus\s*=>\s*\d{3}\b|\brender\s*\(/i,
    'application contains no SQL, transaction, or HTTP mapping';
unlike $source, qr/\b(?:AddIssue|GetIssue|issues|old_issues)\b/,
    'application creates no native Koha issue';
unlike $source, qr/reader[_-]?token|entitlement|byte-range/i,
    'application contains no reader/access behavior';

my $issue_loan = do {
    if ( $source =~ /sub issue_loan \{(.*?)\nsub /s ) {
        $1;
    }
    else {
        '';
    }
};
ok length($issue_loan), 'issue_loan method body is extractable';
ok index( $issue_loan, '_authorize' ) < index( $issue_loan, '_validate_command' )
    && index( $issue_loan, '_validate_command' )
    < index( $issue_loan, 'issuance_service' )
    && index( $issue_loan, 'issuance_service' )
    < index( $issue_loan, '_normalize_result' ),
    'application preserves authorization-before-validation order';

done_testing;
