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
    package Local::Headers;
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

    package Local::Request;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            headers    => Local::Headers->new( $args{headers} ),
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

    package Local::Response;
    sub new { bless { headers => Local::Headers->new }, $_[0] }
    sub headers { return shift->{headers} }

    package Local::Application;
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }
    sub create_request {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, \%args;
        die $self->{error} if defined $self->{error};
        return $self->{result};
    }

    package Local::RequestController;
    our @ISA = (
        'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests'
    );
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            req => Local::Request->new(%args),
            res => Local::Response->new,
            app => $args{app},
        }, $class;
    }
    sub req { return shift->{req} }
    sub res { return shift->{res} }
    sub render {
        my ( $self, %args ) = @_;
        $self->{rendered} = \%args;
        return \%args;
    }
    sub _portal_request_application { return shift->{app} }
}

my $portal_request_id = '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd';
my $idempotency_key   = 'eebc62e3-18ab-4bc1-b373-cad4ec10fe90';
my $correlation_id    = 'db421a13-f74a-4388-a681-897ec46156f4';

sub valid_body {
    return {
        portal_request_id => $portal_request_id,
        patron_id         => 123,
        biblio_id         => 456,
    };
}

sub authoritative_request {
    return {
        request_id        => 81,
        portal_request_id => $portal_request_id,
        patron_id         => 123,
        biblio_id         => 456,
        status            => 'PENDING',
        requested_at      => '2026-07-22T18:20:00Z',
        row_version       => 1,
        pending_guard     => '123:456',
        payload_json      => '{"private":true}',
    };
}

sub application_result {
    my ($outcome) = @_;
    return {
        ok                => 1,
        outcome           => $outcome,
        request           => authoritative_request(),
        idempotent_replay => $outcome eq 'IDEMPOTENT_REPLAY' ? 1 : 0,
        duplicate_pending => $outcome eq 'DUPLICATE_PENDING' ? 1 : 0,
        correlation_id    => $correlation_id,
    };
}

sub controller {
    my (%args) = @_;
    my $calls = [];
    my $app = $args{app} || Local::Application->new(
        calls  => $calls,
        result => exists $args{result}
            ? $args{result}
            : application_result('CREATED'),
        error  => $args{error},
    );
    my $headers = exists $args{headers}
        ? $args{headers}
        : {
            'Content-Type'     => 'application/json',
            'Idempotency-Key'  => $idempotency_key,
            'X-Correlation-ID' => $correlation_id,
        };
    my $c = Local::RequestController->new(
        app        => $app,
        body       => exists $args{body} ? $args{body} : valid_body(),
        headers    => $headers,
        json_error => $args{json_error},
    );
    return ( $c, $calls );
}

sub run_case {
    my (%args) = @_;
    my ( $c, $calls ) = controller(%args);
    $c->create;
    return ( $c->{rendered}, $calls, $c );
}

my ( $created, $created_calls, $created_controller ) = run_case();
is $created->{status}, 201, 'created outcome maps to HTTP 201';
is_deeply(
    [ sort keys %{ $created->{json} } ],
    [ sort qw(request idempotent_replay duplicate_pending correlation_id) ],
    'success response has only public envelope fields'
);
is_deeply(
    [ sort keys %{ $created->{json}{request} } ],
    [ sort qw(request_id portal_request_id patron_id biblio_id status requested_at row_version) ],
    'request response filters internal fields'
);
ok !$created->{json}{idempotent_replay}, 'created response is not a replay';
ok !$created->{json}{duplicate_pending}, 'created response is not a duplicate';
is $created->{json}{correlation_id}, $correlation_id,
    'created response returns the authoritative correlation ID';
is scalar @{$created_calls}, 1, 'application is called once';
is $created_calls->[0]{controller}, $created_controller,
    'trusted controller context is passed for authentication';
is_deeply(
    {
        map { $_ => $created_calls->[0]{$_} }
            qw(patron_id biblio_id portal_request_id idempotency_key correlation_id)
    },
    {
        patron_id         => 123,
        biblio_id         => 456,
        portal_request_id => $portal_request_id,
        idempotency_key   => $idempotency_key,
        correlation_id    => $correlation_id,
    },
    'body and UUID headers are passed to the application'
);
ok !exists $created_calls->[0]{actor_id},
    'controller never supplies a caller-controlled actor ID';
ok !exists $created_calls->[0]{source},
    'controller leaves the application to force PORTAL source';
is $created_controller->res->headers->header('Cache-Control'), 'no-store',
    'write response disables caching';

for my $case (
    [ 'IDEMPOTENT_REPLAY', 200, 1, 0 ],
    [ 'DUPLICATE_PENDING', 200, 0, 1 ],
) {
    my ( $outcome, $status, $replay, $duplicate ) = @{$case};
    my ($rendered) = run_case( result => application_result($outcome) );
    is $rendered->{status}, $status, "$outcome maps to HTTP $status";
    is $rendered->{json}{idempotent_replay} ? 1 : 0, $replay,
        "$outcome replay flag";
    is $rendered->{json}{duplicate_pending} ? 1 : 0, $duplicate,
        "$outcome duplicate flag";
}

for my $case (
    [ 'missing body', undef, undef ],
    [ 'malformed JSON', valid_body(), 'unexpected token at C:\secret\body.json line 1' ],
    [ 'missing required field', { portal_request_id => $portal_request_id, patron_id => 123 }, undef ],
    [ 'caller actor rejected', { %{ valid_body() }, actor_id => 999 }, undef ],
    [ 'caller source rejected', { %{ valid_body() }, source => 'STAFF' }, undef ],
) {
    my ( $label, $body, $json_error ) = @{$case};
    my ( $rendered, $calls ) = run_case(
        body       => $body,
        json_error => $json_error,
    );
    is $rendered->{status}, 400, "$label maps to HTTP 400";
    is $rendered->{json}{error}{code}, 'INVALID_INPUT',
        "$label has stable INVALID_INPUT code";
    is scalar @{$calls}, 0, "$label does not invoke the application";
}

for my $case (
    [
        'missing content type',
        {
            'Idempotency-Key'  => $idempotency_key,
            'X-Correlation-ID' => $correlation_id,
        },
        'INVALID_INPUT',
    ],
    [
        'missing idempotency header',
        {
            'Content-Type'     => 'application/json',
            'X-Correlation-ID' => $correlation_id,
        },
        'INVALID_IDEMPOTENCY_KEY',
    ],
    [
        'malformed idempotency header',
        {
            'Content-Type'     => 'application/json',
            'Idempotency-Key'  => 'not-a-uuid',
            'X-Correlation-ID' => $correlation_id,
        },
        'INVALID_IDEMPOTENCY_KEY',
    ],
    [
        'missing correlation header',
        {
            'Content-Type'    => 'application/json',
            'Idempotency-Key' => $idempotency_key,
        },
        'INVALID_INPUT',
    ],
    [
        'malformed correlation header',
        {
            'Content-Type'     => 'application/json',
            'Idempotency-Key'  => $idempotency_key,
            'X-Correlation-ID' => 'not-a-uuid',
        },
        'INVALID_INPUT',
    ],
) {
    my ( $label, $headers, $code ) = @{$case};
    my ( $rendered, $calls ) = run_case( headers => $headers );
    is $rendered->{status}, 400, "$label maps to HTTP 400";
    is $rendered->{json}{error}{code}, $code, "$label has stable code";
    is scalar @{$calls}, 0, "$label does not invoke the application";
}

my ( $case_insensitive, $case_calls ) = run_case(
    headers => {
        'content-type'     => 'application/json; charset=UTF-8',
        'idempotency-key'  => $idempotency_key,
        'x-correlation-id' => $correlation_id,
    }
);
is $case_insensitive->{status}, 201,
    'normal case-insensitive HTTP header matching is accepted';
is scalar @{$case_calls}, 1, 'case-insensitive headers reach the application';

my %error_status = (
    INVALID_INPUT                   => 400,
    INVALID_IDEMPOTENCY_KEY         => 400,
    AUTHENTICATION_REQUIRED         => 401,
    SERVICE_ACCOUNT_NOT_AUTHORIZED  => 403,
    PATRON_NOT_FOUND                => 404,
    BIBLIO_NOT_FOUND                => 404,
    CONTENT_NOT_ELIGIBLE            => 409,
    IDEMPOTENCY_CONFLICT            => 409,
    DIGITAL_CIRCULATION_UNAVAILABLE => 503,
    INTERNAL_ERROR                  => 500,
);
for my $code ( sort keys %error_status ) {
    my ($rendered) = run_case(
        result => {
            ok      => 0,
            code    => $code,
            detail  => 'SELECT password FROM borrowers at C:\koha\Controller.pm line 7',
            token   => 'Bearer secret',
        }
    );
    is $rendered->{status}, $error_status{$code},
        "$code maps to HTTP $error_status{$code}";
    is_deeply [ sort keys %{ $rendered->{json} } ], ['error'],
        "$code uses the standard error envelope";
    is_deeply [ sort keys %{ $rendered->{json}{error} } ],
        [qw(code message)], "$code exposes only safe error fields";
    unlike $rendered->{json}{error}{message},
        qr{SQL|DBI|password|Bearer|token|DSN|[A-Za-z]:[\\/]|/srv/|line \d+}i,
        "$code message contains no sensitive dependency detail";
}

for my $case (
    [ 'unknown failure code', { ok => 0, code => 'DBI_DUPLICATE_SECRET' } ],
    [ 'missing result', undef ],
    [ 'malformed success', { ok => 1, outcome => 'CREATED' } ],
    [ 'unknown outcome', { %{ application_result('CREATED') }, outcome => 'MAGIC' } ],
    [ 'wrong correlation', { %{ application_result('CREATED') }, correlation_id => '00000000-0000-4000-8000-000000000000' } ],
) {
    my ( $label, $result ) = @{$case};
    my ($rendered) = run_case( result => $result );
    is $rendered->{status}, 500, "$label maps to HTTP 500";
    is $rendered->{json}{error}{code}, 'INTERNAL_ERROR',
        "$label maps to safe INTERNAL_ERROR";
}

my ($exception) = run_case(
    error => 'DBI SELECT password client_secret Bearer token DSN at C:\koha\Request.pm line 88'
);
is $exception->{status}, 500, 'application exception maps to HTTP 500';
is_deeply(
    $exception->{json},
    {
        error => {
            code    => 'INTERNAL_ERROR',
            message => 'The request could not be completed.',
        }
    },
    'application exception is replaced by the safe error envelope'
);

open my $controller_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/Controller/Requests.pm'
    or die $!;
my $source = do { local $/; <$controller_fh> };
unlike $source, qr/\b(?:SELECT|INSERT|UPDATE|DELETE)\b/i,
    'controller contains no persistence SQL';
unlike $source, qr/\b(?:begin_work|commit|rollback)\b/,
    'controller contains no transaction logic';
unlike $source, qr/portal_service_account_ids|split\s*\/,\//,
    'controller contains no allowlist parsing';
unlike $source, qr/Authorization|Bearer|access_token|client_secret/,
    'controller contains no manual bearer-token handling';
like $source, qr/PortalRequestApplication->new\(\s*plugin\s*=>\s*\$plugin/s,
    'production construction supplies a real plugin instance';
like $source, qr/controller\s*=>\s*\$c/s,
    'application receives trusted Koha controller context';
unlike $source, qr/\$body->?\{(?:actor_id|actor_patron_id|source)\}/,
    'controller never trusts body actor or source values';

done_testing;
