use Modern::Perl;
use Test::More;
use lib '.';

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
    our @ISA = ('Exporter');
    our @EXPORT_OK = qw(true false);
    sub true () { 1 }
    sub false () { 0 }
    $INC{'Mojo/JSON.pm'} = __FILE__;

    package C4::Context;
    $INC{'C4/Context.pm'} = __FILE__;
}

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Base;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests;

{
    package Local::DecisionHeaders;
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

    package Local::DecisionRequest;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            headers    => Local::DecisionHeaders->new( $args{headers} ),
            body       => $args{body},
            json_error => $args{json_error},
        }, $class;
    }
    sub headers { return shift->{headers} }
    sub json {
        my ($self) = @_;
        die $self->{json_error} if defined $self->{json_error};
        return $self->{body};
    }

    package Local::DecisionResponse;
    sub new { bless { headers => Local::DecisionHeaders->new }, $_[0] }
    sub headers { return shift->{headers} }

    package Local::DecisionApplication;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, calls => [] }, $class;
    }
    sub decide_request {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, { %args };
        die $self->{error} if defined $self->{error};
        return $self->{result};
    }

    package Local::StaffDecisionController;
    our @ISA = (
        'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests'
    );
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            req        => Local::DecisionRequest->new(%args),
            res        => Local::DecisionResponse->new,
            app        => $args{app},
            request_id => $args{request_id},
        }, $class;
    }
    sub req { return shift->{req} }
    sub res { return shift->{res} }
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
    sub _staff_request_decision_application { return shift->{app} }
}

my $correlation_id = 'db421a13-f74a-4388-a681-897ec46156f4';
my $portal_request_id = '1f7fe335-81f7-4dcf-bacd-1eb9d80b0770';

sub decision_body {
    return {
        expected_row_version => 1,
        decision             => 'APPROVE',
        reason               => undef,
    };
}

sub decided_request {
    my ( $status, %overrides ) = @_;
    my $approved = $status eq 'APPROVED';
    return {
        request_id             => 2,
        portal_request_id      => $portal_request_id,
        patron_id              => 52,
        biblio_id              => 1,
        status                 => $status,
        requested_at           => '2026-07-23T10:00:00Z',
        approved_at            => $approved ? '2026-07-23T10:15:00Z' : undef,
        approved_by            => $approved ? 53 : undef,
        rejected_at            => $approved ? undef : '2026-07-23T10:15:00Z',
        rejected_by            => $approved ? undef : 53,
        rejection_reason       => $approved ? undef : 'Not eligible.',
        row_version            => 2,
        portal_idempotency_key => 'must-not-escape',
        pending_guard          => '52:1',
        payload_json           => '{"must":"not escape"}',
        loan_id                => 999,
        %overrides,
    };
}

sub success_result {
    my ( $status, %overrides ) = @_;
    return {
        ok                   => 1,
        outcome              => $status,
        request              => decided_request($status),
        previous_status      => 'PENDING',
        new_status           => $status,
        previous_row_version => 1,
        row_version          => 2,
        correlation_id       => $correlation_id,
        audit_event          => { payload_json => 'private' },
        %overrides,
    };
}

sub controller {
    my (%args) = @_;
    my $application =
        $args{app}
        || Local::DecisionApplication->new(
            result => exists $args{result}
            ? $args{result}
            : success_result('APPROVED'),
            error => $args{error},
        );
    my $headers = exists $args{headers}
        ? $args{headers}
        : {
            'Content-Type'     => 'application/json',
            'X-Correlation-ID' => $correlation_id,
        };
    my $c = Local::StaffDecisionController->new(
        app        => $application,
        request_id => exists $args{request_id} ? $args{request_id} : 2,
        body       => exists $args{body} ? $args{body} : decision_body(),
        headers    => $headers,
        json_error => $args{json_error},
    );
    return ( $c, $application );
}

sub run_case {
    my (%args) = @_;
    my ( $c, $application ) = controller(%args);
    $c->decide;
    return ( $c->{rendered}, $application->{calls}, $c );
}

my ( $approval, $approval_calls, $approval_controller ) = run_case();
is $approval->{status}, 200, 'approved decision maps to HTTP 200';
is_deeply [ sort keys %{ $approval->{json} } ],
    [
        sort qw(
          request previous_status new_status previous_row_version row_version
          correlation_id
        )
    ],
    'approval response has only public decision envelope fields';
is_deeply [ sort keys %{ $approval->{json}{request} } ],
    [
        sort qw(
          request_id portal_request_id patron_id biblio_id status requested_at
          approved_at approved_by rejected_at rejected_by rejection_reason
          row_version
        )
    ],
    'approval request uses exact staff public field allowlist';
is $approval->{json}{request}{status}, 'APPROVED',
    'approval response has approved status';
is $approval->{json}{request}{approved_by}, 53,
    'approval response includes trusted deciding actor';
is $approval->{json}{request}{row_version}, 2,
    'approval response includes incremented request version';
is $approval->{json}{previous_row_version}, 1,
    'approval response includes previous version';
is $approval->{json}{row_version}, 2,
    'approval response includes new version';
is scalar @{$approval_calls}, 1, 'decision application is called exactly once';
is $approval_calls->[0]{controller}, $approval_controller,
    'trusted controller context is passed unchanged';
is_deeply(
    {
        map { $_ => $approval_calls->[0]{$_} }
            qw(request_id expected_row_version decision reason correlation_id)
    },
    {
        request_id           => 2,
        expected_row_version => 1,
        decision             => 'APPROVE',
        reason               => undef,
        correlation_id       => $correlation_id,
    },
    'path, body, and correlation command fields are passed exactly'
);
for my $forbidden (
    qw(
      actor_id actor_patron_id patron_id biblio_id status source approved_by
      rejected_by loan_id renewal_id
    )
    )
{
    ok !exists $approval_calls->[0]{$forbidden},
        "controller does not supply $forbidden";
}
for my $forbidden (
    qw(
      portal_idempotency_key pending_guard payload_json loan_id audit_event
    )
    )
{
    ok !exists $approval->{json}{request}{$forbidden}
        && !exists $approval->{json}{$forbidden},
        "$forbidden is filtered from approval response";
}
is $approval_controller->res->headers->header('Cache-Control'), 'no-store',
    'decision response disables caching';

my $rejection_body = {
    expected_row_version => 1,
    decision             => 'REJECT',
    reason               => 'Not eligible.',
};
my ( $rejection, $rejection_calls ) = run_case(
    body   => $rejection_body,
    result => success_result('REJECTED'),
);
is $rejection->{status}, 200, 'rejected decision maps to HTTP 200';
is $rejection->{json}{request}{status}, 'REJECTED',
    'rejection response has rejected status';
is $rejection->{json}{request}{rejected_by}, 53,
    'rejection response includes rejecting actor';
is $rejection->{json}{request}{rejection_reason}, 'Not eligible.',
    'rejection response includes safe rejection reason';
is $rejection_calls->[0]{decision}, 'REJECT',
    'rejection decision passes unchanged';
is $rejection_calls->[0]{reason}, 'Not eligible.',
    'rejection reason passes unchanged';
ok !exists $rejection->{json}{audit_event},
    'rejection response excludes audit event data';

for my $case (
    [ undef, 'missing path request ID' ],
    [ '', 'blank path request ID' ],
    [ 0, 'zero path request ID' ],
    [ -2, 'negative path request ID' ],
    [ '2.0', 'decimal path request ID' ],
    [ '2e0', 'exponent path request ID' ],
    [ '2request', 'partial path request ID' ],
    [ [], 'reference path request ID' ],
    )
{
    my ( $rendered, $calls ) = run_case( request_id => $case->[0] );
    is $rendered->{status}, 400, "$case->[1] maps to HTTP 400";
    is $rendered->{json}{error}{code}, 'INVALID_INPUT',
        "$case->[1] has stable code";
    is scalar @{$calls}, 0, "$case->[1] does not invoke application";
}

for my $case (
    [ undef, undef, 'missing body' ],
    [ decision_body(), 'invalid JSON at C:\private\Request.pm line 3', 'malformed JSON' ],
    [ { decision => 'APPROVE' }, undef, 'missing expected version' ],
    [ { expected_row_version => 1 }, undef, 'missing decision' ],
    [ { %{ decision_body() }, actor_id => 999 }, undef, 'caller actor field' ],
    [ { %{ decision_body() }, patron_id => 52 }, undef, 'caller patron field' ],
    [ { %{ decision_body() }, status => 'APPROVED' }, undef, 'caller status field' ],
    [ { %{ decision_body() }, row_version => 1 }, undef, 'replacement row version field' ],
    [ { %{ decision_body() }, loan_id => 9 }, undef, 'loan field' ],
    [ { %{ decision_body() }, source => 'STAFF' }, undef, 'source field' ],
    [ { %{ decision_body() }, expected_row_version => 0 }, undef, 'zero expected version' ],
    [ { %{ decision_body() }, expected_row_version => '1e0' }, undef, 'exponent expected version' ],
    )
{
    my ( $body, $json_error, $label ) = @{$case};
    my ( $rendered, $calls ) = run_case(
        body       => $body,
        json_error => $json_error,
    );
    is $rendered->{status}, 400, "$label maps to HTTP 400";
    is $rendered->{json}{error}{code}, 'INVALID_INPUT',
        "$label has stable INVALID_INPUT";
    is scalar @{$calls}, 0, "$label does not invoke application";
}

for my $case (
    [
        'missing content type',
        { 'X-Correlation-ID' => $correlation_id },
    ],
    [
        'missing correlation header',
        { 'Content-Type' => 'application/json' },
    ],
    [
        'malformed correlation header',
        {
            'Content-Type'     => 'application/json',
            'X-Correlation-ID' => 'not-a-uuid',
        },
    ],
    )
{
    my ( $rendered, $calls ) = run_case( headers => $case->[1] );
    is $rendered->{status}, 400, "$case->[0] maps to HTTP 400";
    is $rendered->{json}{error}{code}, 'INVALID_INPUT',
        "$case->[0] has stable code";
    is scalar @{$calls}, 0, "$case->[0] does not invoke application";
}

for my $case (
    [ 'APPROVED', 'INVALID_DECISION', 'unsupported direct status' ],
    [ 'DELETE', 'INVALID_DECISION', 'unsupported command' ],
    )
{
    my $body = decision_body();
    $body->{decision} = $case->[0];
    my ( $rendered, $calls ) = run_case(
        body => $body,
        result => { ok => 0, code => $case->[1] },
    );
    is $rendered->{status}, 400, "$case->[2] maps to HTTP 400";
    is $rendered->{json}{error}{code}, $case->[1],
        "$case->[2] retains application classification";
    is scalar @{$calls}, 1, "$case->[2] is validated by application layer";
}

for my $case (
    [ undef, 'missing rejection reason' ],
    [ '<script>unsafe</script>', 'unsafe rejection reason' ],
    )
{
    my ( $rendered, $calls ) = run_case(
        body => {
            expected_row_version => 1,
            decision             => 'REJECT',
            reason               => $case->[0],
        },
        result => { ok => 0, code => 'INVALID_REASON' },
    );
    is $rendered->{status}, 400, "$case->[1] maps to HTTP 400";
    is $rendered->{json}{error}{code}, 'INVALID_REASON',
        "$case->[1] retains application classification";
    is scalar @{$calls}, 1, "$case->[1] reaches shared application validation";
}

my %error_status = (
    INVALID_INPUT                   => 400,
    INVALID_DECISION                => 400,
    INVALID_REASON                  => 400,
    AUTHENTICATION_REQUIRED         => 401,
    STAFF_NOT_AUTHORIZED            => 403,
    REQUEST_NOT_FOUND               => 404,
    VERSION_CONFLICT                => 409,
    REQUEST_ALREADY_DECIDED         => 409,
    INVALID_STATE                   => 409,
    DIGITAL_CIRCULATION_UNAVAILABLE => 503,
    INTERNAL_ERROR                  => 500,
);
for my $code ( sort keys %error_status ) {
    my ( $rendered, $calls ) = run_case(
        result => {
            ok         => 0,
            code       => $code,
            detail     => 'DBI SELECT password at C:\private.pm line 4',
            permission => { circulate => 1 },
            token      => 'Bearer secret',
        }
    );
    is $rendered->{status}, $error_status{$code},
        "$code maps to HTTP $error_status{$code}";
    is_deeply [ sort keys %{ $rendered->{json} } ], ['error'],
        "$code uses standard error envelope";
    is_deeply [ sort keys %{ $rendered->{json}{error} } ],
        [qw(code message)], "$code exposes only code and safe message";
    unlike $rendered->{json}{error}{message},
        qr{SQL|DBI|password|Bearer|token|DSN|[A-Za-z]:[\\/]|/srv/|line \d+|circulate}i,
        "$code response leaks no dependency or permission detail";
    is scalar @{$calls}, 1, "$code performs no automatic retry";
}

is(
    ( run_case(
        result => { ok => 0, code => 'VERSION_CONFLICT' }
    ) )[0]{json}{error}{message},
    'The request has changed. Refresh it before trying again.',
    'version conflict has exact refresh message'
);
is(
    ( run_case(
        result => { ok => 0, code => 'REQUEST_ALREADY_DECIDED' }
    ) )[0]{json}{error}{message},
    'The request has already been decided.',
    'repeated decision has exact message'
);
is(
    ( run_case(
        result => { ok => 0, code => 'STAFF_NOT_AUTHORIZED' }
    ) )[0]{json}{error}{message},
    'The authenticated staff user is not authorized for this digital circulation action.',
    'staff denial has exact safe message'
);

for my $case (
    [ 'missing result', undef ],
    [ 'malformed failure', { ok => 0, code => 'DBI_SECRET' } ],
    [ 'malformed success', { ok => 1 } ],
    [
        'wrong status',
        success_result( 'APPROVED', new_status => 'REJECTED' )
    ],
    [
        'wrong request',
        success_result(
            'APPROVED',
            request => decided_request( 'APPROVED', request_id => 99 )
        )
    ],
    [
        'wrong version',
        success_result( 'APPROVED', row_version => 3 )
    ],
    [
        'wrong correlation',
        success_result(
            'APPROVED',
            correlation_id => '00000000-0000-4000-8000-000000000000'
        )
    ],
    [
        'reference public field',
        success_result(
            'APPROVED',
            request => decided_request(
                'APPROVED',
                approved_at => bless( {}, 'Local::RawKohaUser' )
            )
        )
    ],
    )
{
    my ($rendered) = run_case( result => $case->[1] );
    is $rendered->{status}, 500, "$case->[0] maps to HTTP 500";
    is $rendered->{json}{error}{code}, 'INTERNAL_ERROR',
        "$case->[0] fails closed";
}

my ($exception) = run_case(
    error => 'DBI SQLSTATE DSN password cookie Bearer token at C:\private.pm line 9'
);
is $exception->{status}, 500, 'application exception maps to HTTP 500';
is_deeply $exception->{json},
    {
        error => {
            code    => 'INTERNAL_ERROR',
            message => 'The request could not be completed.',
        }
    },
    'application exception is replaced by safe standard envelope';

open my $controller_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Controller/Requests.pm'
    or die $!;
my $source = do { local $/; <$controller_fh> };
unlike $source, qr/\b(?:SELECT|INSERT|UPDATE|DELETE)\b/i,
    'controller contains no SQL';
unlike $source, qr/\b(?:begin_work|commit|rollback)\b/,
    'controller owns no transaction';
unlike $source, qr/PortalServiceAuthorization|portal_service_account_ids/,
    'controller does not use portal authorization';
unlike $source, qr/haspermission|circulate_remaining_permissions/,
    'controller does not inspect permissions directly';
unlike $source,
    qr/INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)/i,
    'controller creates no loan or renewal';
like $source,
    qr/StaffRequestDecisionApplication->new\(\s*plugin\s*=>\s*\$plugin/s,
    'production decision construction supplies real plugin instance';
like $source,
    qr/sub decide \{.*?decide_request\(.*?controller\s*=>\s*\$c/s,
    'decision method passes trusted controller context to application';

done_testing;
