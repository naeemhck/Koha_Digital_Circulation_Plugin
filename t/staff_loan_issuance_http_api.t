use Modern::Perl;
use Test::More;
use JSON qw(decode_json);
use lib '.', 't/lib';

BEGIN {
    package Mojolicious::Controller;
    sub new { bless {}, $_[0] }
    $INC{'Mojolicious/Controller.pm'} = __FILE__;

    package Mojo::Base;
    sub import {
        my ( $class, $base ) = @_;
        return unless $base;
        my $caller = caller;
        no strict 'refs';
        @{"${caller}::ISA"} = ($base);
    }
    $INC{'Mojo/Base.pm'} = __FILE__;

    package Mojo::JSON;
    require Exporter;
    our @ISA       = ('Exporter');
    our @EXPORT_OK = qw(true false);
    sub true  () { 1 }
    sub false () { 0 }
    $INC{'Mojo/JSON.pm'} = __FILE__;

    package C4::Context;
    sub dbh { die 'unexpected C4::Context->dbh in issuance HTTP unit test' }
    $INC{'C4/Context.pm'} = __FILE__;
}

use LoanIssuanceFakes;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Base;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::ConfiguredLoanPeriodPolicy;

{
    package Local::IssueHeaders;
    sub new {
        my ( $class, $values ) = @_;
        return bless {
            values => {
                map { lc($_) => $values->{$_} }
                    keys %{ $values || {} }
            }
        }, $class;
    }
    sub header {
        my ( $self, $name, $value ) = @_;
        $self->{values}{ lc $name } = $value if @_ == 3;
        return $self->{values}{ lc $name };
    }
    sub content_type { return shift->header('Content-Type') }

    package Local::IssueRequest;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            headers    => Local::IssueHeaders->new( $args{headers} ),
            body       => $args{body},
            raw_body   => exists $args{raw_body} ? $args{raw_body} : undef,
            json_error => $args{json_error},
        }, $class;
    }
    sub headers { return shift->{headers} }
    sub body {
        my ($self) = @_;
        return $self->{raw_body} if exists $self->{raw_body};
        return undef unless defined $self->{body};
        require JSON;
        return JSON::encode_json( $self->{body} );
    }
    sub json {
        my ($self) = @_;
        die $self->{json_error} if defined $self->{json_error};
        return $self->{body};
    }

    package Local::IssueResponse;
    sub new { bless { headers => Local::IssueHeaders->new }, $_[0] }
    sub headers { return shift->{headers} }

    package Local::IssuanceApplication;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, calls => [] }, $class;
    }
    sub issue_loan {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, { %args };
        die $self->{error} if defined $self->{error};
        return $self->{result};
    }

    package Local::IssuanceService;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, calls => [] }, $class;
    }
    sub issue_loan {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, { %args };
        die $self->{error} if defined $self->{error};
        return $self->{result};
    }

    package Local::PortalConfigurationPlugin;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args }, $class;
    }
    sub retrieve_data {
        my ( $self, $key ) = @_;
        return $self->{value} if $key eq 'portal_service_account_ids';
        return $self->{duration} if $key eq 'default_loan_duration_days';
        return;
    }

    package Local::StaffActor;
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }
    sub borrowernumber { return $_[0]{borrowernumber} }
    sub userid         { return $_[0]{userid} }

    package Local::IssueController;
    our @ISA = (
        'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests'
    );
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            req        => Local::IssueRequest->new(%args),
            res        => Local::IssueResponse->new,
            app        => $args{app},
            request_id => $args{request_id},
            stash_user => $args{stash_user},
        }, $class;
    }
    sub req { return shift->{req} }
    sub res { return shift->{res} }
    sub stash {
        my ( $self, $key ) = @_;
        die 'unexpected stash key' unless $key eq 'koha.user';
        return $self->{stash_user};
    }
    sub param {
        my ( $self, $name ) = @_;
        die 'unexpected parameter' unless $name eq 'request_id';
        return $self->{request_id};
    }
    sub render {
        my ( $self, %args ) = @_;
        $self->{rendered} = \%args;
        return \%args;
    }
    sub _staff_loan_issuance_application { return shift->{app} }
}

my $correlation_id = 'db421a13-f74a-4388-a681-897ec46156f4';
my $bundle = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation';

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
    return {
        ok   => 1,
        loan => safe_loan(),
    };
}

sub controller {
    my (%args) = @_;
    my $application =
        $args{app}
        || Local::IssuanceApplication->new(
            result => exists $args{result} ? $args{result} : success_result(),
            error  => $args{error},
        );
    my $headers = exists $args{headers}
        ? $args{headers}
        : { 'X-Correlation-ID' => $correlation_id };
    my %ctor = (
        app        => $application,
        request_id => exists $args{request_id} ? $args{request_id} : 6,
        headers    => $headers,
        json_error => $args{json_error},
        stash_user => $args{stash_user},
    );
    $ctor{body} = $args{body} if exists $args{body};
    $ctor{raw_body} = $args{raw_body} if exists $args{raw_body};
    my $c = Local::IssueController->new(%ctor);
    return ( $c, $application );
}

sub run_case {
    my (%args) = @_;
    my ( $c, $application ) = controller(%args);
    $c->issue;
    return ( $c->{rendered}, $application->{calls}, $c );
}

# --- Success ---
my ( $success, $success_calls ) = run_case();
is $success->{status}, 201, 'successful issuance maps to HTTP 201';
is_deeply [ sort keys %{ $success->{json} } ],
    [
    qw(biblio_id due_at loan_id patron_id request_id row_version started_at status)
    ],
    'success returns only safe loan fields';
is $success->{json}{status}, 'ACTIVE', 'success status is ACTIVE';
is $success->{json}{request_id}, 6, 'success preserves path request_id';
is scalar @$success_calls, 1, 'application invoked once';
is $success_calls->[0]{request_id}, 6,
    'path request_id is the only caller-selected business identifier';
ok exists $success_calls->[0]{controller},
    'trusted controller context is forwarded';
ok !exists $success_calls->[0]{actor_id},
    'caller actor authority is not forwarded';
ok !exists $success_calls->[0]{patron_id},
    'caller patron authority is not forwarded';
ok !exists $success_calls->[0]{due_at},
    'caller due date is not forwarded';

# --- Correlation header validation ---
for my $headers (
    {},
    { 'X-Correlation-ID' => '' },
    { 'X-Correlation-ID' => 'not-a-uuid' },
    { 'X-Correlation-ID' => " $correlation_id " },
    )
{
    my ( $rendered, $calls ) = run_case( headers => $headers );
    is $rendered->{status}, 400, 'invalid correlation maps to HTTP 400';
    is $rendered->{json}{error}{code}, 'INVALID_INPUT',
        'invalid correlation uses INVALID_INPUT';
    is scalar @$calls, 0, 'invalid correlation never invokes application';
}

# --- Body rejection ---
for my $body (
    { actor_id => 999 },
    { patron_id => 888 },
    { biblio_id => 777 },
    { due_at => '2026-08-08 10:00:00' },
    { duration => 14 },
    { duration_days => 14 },
    { status => 'ACTIVE' },
    { token => 'secret' },
    { unexpected => 1 },
    )
{
    my ( $rendered, $calls ) = run_case(
        body     => $body,
        raw_body => '{"x":1}',
    );
    is $rendered->{status}, 400, 'authority-bearing body maps to HTTP 400';
    is $rendered->{json}{error}{code}, 'INVALID_INPUT',
        'authority-bearing body uses INVALID_INPUT';
    is scalar @$calls, 0, 'authority-bearing body never invokes application';
}

my ( $empty_object ) = run_case(
    body     => {},
    raw_body => '{}',
);
is $empty_object->{status}, 201,
    'empty JSON object is accepted when body absence is impractical';

my ( $no_body ) = run_case( raw_body => '' );
is $no_body->{status}, 201, 'bodyless request is accepted';

# --- Authz failure mappings via application ---
for my $case (
    [ 'AUTHENTICATION_REQUIRED', 401 ],
    [ 'STAFF_NOT_AUTHORIZED',    403 ],
    )
{
    my ( $code, $status ) = @{$case};
    my ( $rendered, $calls ) = run_case(
        result => { ok => 0, code => $code }
    );
    is $rendered->{status}, $status, "$code maps to HTTP $status";
    is $rendered->{json}{error}{code}, $code, "$code preserves stable code";
}

# --- Application failure mappings ---
for my $case (
    [ 'REQUEST_NOT_FOUND',              404 ],
    [ 'REQUEST_NOT_APPROVED',           409 ],
    [ 'LOAN_ALREADY_EXISTS',            409 ],
    [ 'INVALID_MAPPING',                409 ],
    [ 'PROTECTED_CONTENT_UNAVAILABLE',  503 ],
    [ 'INVALID_LOAN_PERIOD',            503 ],
    [ 'DIGITAL_CIRCULATION_UNAVAILABLE',503 ],
    [ 'INTERNAL_ERROR',                 500 ],
    [ 'INVALID_INPUT',                  400 ],
    )
{
    my ( $code, $status ) = @{$case};
    my ( $rendered ) = run_case(
        result => { ok => 0, code => $code }
    );
    is $rendered->{status}, $status, "$code maps to HTTP $status";
    is $rendered->{json}{error}{code}, $code, "$code preserves stable code";
    is_deeply [ sort keys %{ $rendered->{json} } ], [qw(error)],
        "$code exposes only the standard error envelope";
    is_deeply [ sort keys %{ $rendered->{json}{error} } ],
        [qw(code message)],
        "$code error object has only code and message";
}

# --- Malformed results ---
for my $result (
    undef,
    [],
    { ok => 1 },
    { ok => 1, loan => safe_loan( loan_id => undef ) },
    { ok => 1, loan => { %{ safe_loan() }, content_path => '/secret.pdf' } },
    { ok => 1, loan => safe_loan( status => 'PENDING' ) },
    { ok => 0, code => 'SQLSTATE_SECRET' },
    )
{
    my ( $rendered ) = run_case( result => $result );
    is $rendered->{status}, 500, 'malformed result maps to HTTP 500';
    is $rendered->{json}{error}{code}, 'INTERNAL_ERROR',
        'malformed result uses INTERNAL_ERROR';
    unlike join( ' ', grep { defined && !ref } values %{ $rendered->{json}{error} } ),
        qr{SQLSTATE|secret\.pdf|token}i,
        'malformed result exposes no raw details';
}

my ( $exception ) = run_case( error => 'dbh DSN=secret SQLSTATE' );
is $exception->{status}, 500, 'application exception maps to HTTP 500';
is $exception->{json}{error}{code}, 'INTERNAL_ERROR',
    'application exception uses INTERNAL_ERROR';
unlike $exception->{json}{error}{message}, qr{DSN|SQLSTATE|secret}i,
    'application exception exposes no raw exception text';

# --- Actor separation through real application ---
{
    my $issuance = Local::IssuanceService->new( result => success_result() );
    my $app = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication->new(
        authorization => Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization->new(
            plugin => Local::PortalConfigurationPlugin->new( value => '53' ),
            permission_checker => sub { return 1 },
        ),
        issuance_service => $issuance,
    );
    my $c = Local::IssueController->new(
        app        => $app,
        request_id => 6,
        headers    => { 'X-Correlation-ID' => $correlation_id },
        raw_body   => '',
        stash_user => Local::StaffActor->new(
            borrowernumber => 53,
            userid         => 'service53',
        ),
    );
    $c->issue;
    is $c->{rendered}{status}, 403, 'actor 53 maps to HTTP 403';
    is $c->{rendered}{json}{error}{code}, 'STAFF_NOT_AUTHORIZED',
        'actor 53 receives STAFF_NOT_AUTHORIZED';
    is scalar @{ $issuance->{calls} }, 0,
        'actor 53 never reaches LoanIssuanceService';
}

{
    my $issuance = Local::IssuanceService->new( result => success_result() );
    my $app = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication->new(
        authorization => Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization->new(
            plugin => Local::PortalConfigurationPlugin->new( value => '53' ),
            permission_checker => sub { return 1 },
        ),
        issuance_service => $issuance,
    );
    my $c = Local::IssueController->new(
        app        => $app,
        request_id => 6,
        headers    => { 'X-Correlation-ID' => $correlation_id },
        raw_body   => '',
        stash_user => Local::StaffActor->new(
            borrowernumber => 51,
            userid         => 'librarian51',
        ),
    );
    $c->issue;
    is $c->{rendered}{status}, 201, 'actor 51 can issue successfully';
    is_deeply $issuance->{calls}[0],
        {
            request_id => 6,
            actor_id   => 51,
        },
        'actor 51 is forwarded exactly from trusted Koha context';
}

{
    my $issuance = Local::IssuanceService->new( result => success_result() );
    my $app = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication->new(
        authorization => Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization->new(
            service_account_checker => sub { return 0 },
            permission_checker      => sub { return 1 },
        ),
        issuance_service => $issuance,
    );
    my $c = Local::IssueController->new(
        app        => $app,
        request_id => 6,
        headers    => { 'X-Correlation-ID' => $correlation_id },
        raw_body   => '',
        stash_user => undef,
    );
    $c->issue;
    is $c->{rendered}{json}{error}{code}, 'AUTHENTICATION_REQUIRED',
        'missing Koha user maps to AUTHENTICATION_REQUIRED';
    is scalar @{ $issuance->{calls} }, 0,
        'missing Koha user never reaches LoanIssuanceService';
}

{
    my $issuance = Local::IssuanceService->new( result => success_result() );
    my $app = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication->new(
        authorization => Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization->new(
            service_account_checker => sub { return 0 },
            permission_checker      => sub { return 0 },
        ),
        issuance_service => $issuance,
    );
    my $c = Local::IssueController->new(
        app        => $app,
        request_id => 6,
        headers    => { 'X-Correlation-ID' => $correlation_id },
        raw_body   => '',
        stash_user => Local::StaffActor->new(
            borrowernumber => 51,
            userid         => 'ordinary',
        ),
    );
    $c->issue;
    is $c->{rendered}{json}{error}{code}, 'STAFF_NOT_AUTHORIZED',
        'staff without permission is denied';
    is scalar @{ $issuance->{calls} }, 0,
        'unauthorized staff never reaches LoanIssuanceService';
}

# --- Transaction / idempotency through HTTP + application + service ---
sub approved_request {
    return {
        request_id             => 6,
        portal_request_id      => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
        portal_idempotency_key => 'ffffffff-1111-4222-8333-444444444444',
        source                 => 'PORTAL',
        patron_id              => 52,
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

sub wired_controller {
    my (%args) = @_;
    my $dbh = $args{dbh} || Local::LoanIssuanceDBH->new(
        requests => [ approved_request() ],
    );
    my $service = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService->new(
        dbh                => $dbh,
        request_repository => Local::LoanIssuanceRequestRepository->new,
        loan_repository    => Local::LoanIssuanceLoanRepository->new,
        event_repository   => Local::LoanIssuanceEventRepository->new(
            insert_error => $args{event_error},
        ),
        eligibility => Local::LoanIssuanceEligibility->new(
            biblio_id => 1,
            result    => $args{eligibility_result},
        ),
        due_date_policy => Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::ConfiguredLoanPeriodPolicy->new(
            config_reader => sub {
                exists $args{duration} ? $args{duration} : 14
            },
        ),
        clock          => sub {'2026-07-25 10:00:00'},
        uuid_generator => sub {'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0011'},
    );
    my $app = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication->new(
        authorization => Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization->new(
            service_account_checker => sub { return 0 },
            permission_checker      => sub { return 1 },
        ),
        issuance_service => $service,
    );
    my $c = Local::IssueController->new(
        app        => $app,
        request_id => 6,
        headers    => { 'X-Correlation-ID' => $correlation_id },
        raw_body   => '',
        stash_user => Local::StaffActor->new(
            borrowernumber => 51,
            userid         => 'librarian51',
        ),
    );
    return ( $c, $dbh );
}

{
    my ( $c, $dbh ) = wired_controller();
    $c->issue;
    is $c->{rendered}{status}, 201, 'wired success issues through HTTP path';
    is scalar @{ $dbh->{loans} },  1, 'successful request creates one loan';
    is scalar @{ $dbh->{events} }, 1, 'successful request creates one LOAN_CREATED event';
    is $dbh->{events}[0]{event_type}, 'LOAN_CREATED', 'event type is LOAN_CREATED';

    $c->issue;
    is $c->{rendered}{status}, 409, 'repeat issuance maps to HTTP 409';
    is $c->{rendered}{json}{error}{code}, 'LOAN_ALREADY_EXISTS',
        'repeat issuance returns LOAN_ALREADY_EXISTS';
    is scalar @{ $dbh->{loans} },  1, 'repeat creates no second loan';
    is scalar @{ $dbh->{events} }, 1, 'repeat creates no second event';
}

{
    my ( $c, $dbh ) = wired_controller(
        event_error => 'event insert failed'
    );
    $c->issue;
    ok !$c->{rendered}{json}{error}{ok},
        'event failure is not successful';
    ok $c->{rendered}{json}{error}{code} eq 'INTERNAL_ERROR'
        || $c->{rendered}{json}{error}{code} eq
        'DIGITAL_CIRCULATION_UNAVAILABLE',
        'event failure fails closed with a safe unavailable/internal code';
    is scalar @{ $dbh->{loans} },  0, 'event failure rolls back loan';
    is scalar @{ $dbh->{events} }, 0, 'event failure creates no event';
}

{
    my ( $c, $dbh ) = wired_controller( duration => undef );
    $c->issue;
    is $c->{rendered}{json}{error}{code}, 'INVALID_LOAN_PERIOD',
        'policy failure maps through HTTP';
    is scalar @{ $dbh->{loans} },  0, 'policy failure creates zero loans';
    is scalar @{ $dbh->{events} }, 0, 'policy failure creates zero events';
}

{
    my ( $c, $dbh ) = wired_controller(
        eligibility_result => {
            eligible  => 0,
            biblio_id => 1,
            code      => 'CONTENT_NOT_ELIGIBLE',
            reason    => 'CONTENT_LOOKUP_UNAVAILABLE',
        }
    );
    $c->issue;
    is $c->{rendered}{json}{error}{code}, 'PROTECTED_CONTENT_UNAVAILABLE',
        'protected-content failure maps through HTTP';
    is scalar @{ $dbh->{loans} },  0, 'content failure creates zero loans';
    is scalar @{ $dbh->{events} }, 0, 'content failure creates zero events';
}

# --- OpenAPI / source contracts ---
open my $api_fh, '<', "$bundle/openapi.json" or die $!;
my $api = decode_json( do { local $/; <$api_fh> } );
my @posts;
for my $path ( sort keys %{$api} ) {
    push @posts, $path if exists $api->{$path}{post};
}
is_deeply \@posts,
    [
        '/requests',
        '/requests/{request_id}/decision',
        '/requests/{request_id}/issue',
    ],
    'OpenAPI has exactly three POST routes';
my $issue = $api->{'/requests/{request_id}/issue'}{post};
is $issue->{operationId}, 'jzlIssueDigitalLoan',
    'issuance operation ID is exact';
is $issue->{'x-mojo-to'},
    'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#issue',
    'issuance route maps to Requests#issue';
is_deeply $issue->{'x-koha-authorization'}{permissions},
    { circulate => 'circulate_remaining_permissions' },
    'issuance route declares established staff permission';
my $has_body_parameter = 0;
for my $parameter ( @{ $issue->{parameters} || [] } ) {
    $has_body_parameter = 1
        if ref($parameter) eq 'HASH'
        && ( $parameter->{in} // '' ) eq 'body';
}
ok !$has_body_parameter, 'issuance OpenAPI requires no request body';
is_deeply [ sort keys %{ $issue->{responses} } ],
    [qw(201 400 401 403 404 409 500 503)],
    'issuance response statuses are complete';
ok !$issue->{responses}{201}{schema}{additionalProperties},
    'issuance success schema forbids additional properties';
ok exists $issue->{responses}{201}{schema}{properties}{loan_id},
    'issuance success schema includes loan_id';
like $issue->{description}, qr/separate from approval/i,
    'OpenAPI states issuance is separate from approval';
like $issue->{description}, qr/does not create a native Koha issue/i,
    'OpenAPI states no native Koha issue is created';
like $issue->{description}, qr/does not grant reader access/i,
    'OpenAPI states no reader access is granted';

open my $source_fh, '<', "$bundle/Controller/Requests.pm" or die $!;
my $source = do { local $/; <$source_fh> };
close $source_fh;
like $source, qr/sub issue/,
    'controller exposes issue action';
like $source, qr/StaffLoanIssuanceApplication/,
    'controller delegates to StaffLoanIssuanceApplication';
like $source, qr/_staff_loan_issuance_application/,
    'controller constructs issuance application through adapter';
unlike $source, qr/LoanIssuanceService->new/,
    'controller does not construct LoanIssuanceService directly';
my ($decide_body) = $source =~ /sub decide \{(.*?)sub issue \{/s;
my ($issue_body)  = $source =~ /sub issue \{(.*?)sub _portal_request_application \{/s;
ok length($decide_body) && length($issue_body),
    'decide and issue method bodies are extractable';
unlike $decide_body, qr/issue_loan|StaffLoanIssuanceApplication/,
    'decide action remains unwired from loan issuance';
unlike $issue_body, qr/decide_request|StaffRequestDecisionApplication/,
    'issue action remains unwired from request decisions';

open my $decision_service_fh, '<',
    "$bundle/Service/RequestDecisionService.pm"
    or die $!;
my $decision_service = do { local $/; <$decision_service_fh> };
unlike $decision_service, qr/LoanIssuanceService|issue_loan/,
    'decision endpoint service path remains unwired from issuance';

open my $tool_fh, '<', "$bundle/tool.tt" or die $!;
my $tool = do { local $/; <$tool_fh> };
open my $js_fh, '<', "$bundle/static/js/jzl-digital-circulation.js" or die $!;
my $js = do { local $/; <$js_fh> };
like $tool . $js, qr/Issue Loan/,
    'staff UI exposes Issue Loan through the verified issuance API';
like $js, qr{encodeURIComponent\(String\(id\)\) \+\s*'/issue'},
    'staff UI calls the verified issuance route';
like $tool, qr/Approval alone does not create a loan/,
    'staff UI continues to state approval alone creates no loan';
unlike $js, qr/(?:grantAccess|activateReader|reader[_-]?token)/i,
    'staff issuance UI adds no reader-access behavior';

done_testing;
