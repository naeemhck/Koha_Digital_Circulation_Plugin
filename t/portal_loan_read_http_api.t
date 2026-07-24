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
    our @ISA       = ('Exporter');
    our @EXPORT_OK = qw(true false);
    sub true  () { 1 }
    sub false () { 0 }
    $INC{'Mojo/JSON.pm'} = __FILE__;

    package C4::Context;
    sub dbh { die 'unexpected C4::Context->dbh in portal loan-read HTTP test' }
    $INC{'C4/Context.pm'} = __FILE__;
}

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Base;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Patrons;

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

    package Local::Request;
    sub new {
        my ( $class, %args ) = @_;
        return bless { headers => Local::Headers->new( $args{headers} ) }, $class;
    }
    sub headers { return shift->{headers} }

    package Local::Response;
    sub new { bless { headers => Local::Headers->new }, $_[0] }
    sub headers { return shift->{headers} }

    package Local::PortalLoanApp;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args, calls => [] }, $class;
    }
    sub list_patron_loans {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, {%args};
        die $self->{error} if defined $self->{error};
        return $self->{result};
    }

    package Local::PatronController;
    our @ISA = (
        'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Patrons'
    );
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            req       => Local::Request->new(%args),
            res       => Local::Response->new,
            app       => $args{app},
            patron_id => $args{patron_id},
            page      => $args{page},
            per_page  => $args{per_page},
        }, $class;
    }
    sub req { return shift->{req} }
    sub res { return shift->{res} }
    sub param {
        my ( $self, $name ) = @_;
        return $self->{patron_id} if $name eq 'patron_id';
        return $self->{page}      if $name eq 'page';
        return $self->{per_page}  if $name eq 'per_page';
        die "unexpected parameter $name";
    }
    sub render {
        my ( $self, %args ) = @_;
        $self->{rendered} = \%args;
        return \%args;
    }
    sub _portal_loan_read_application { return shift->{app} }
}

my $correlation_id    = 'db421a13-f74a-4388-a681-897ec46156f4';
my $portal_request_id = '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd';

sub safe_loan {
    return {
        loan_id           => 1,
        request_id        => 7,
        portal_request_id => $portal_request_id,
        patron_id         => 50,
        biblio_id         => 1,
        status            => 'ACTIVE',
        started_at        => '2026-07-24 17:27:14',
        due_at            => '2026-08-07 17:27:14',
        returned_at       => undef,
        revoked_at        => undef,
        expired_at        => undef,
        renewal_count     => 0,
        row_version       => 1,
        created_at        => '2026-07-24 17:27:14',
        updated_at        => '2026-07-24 17:27:14',
    };
}

sub success_result {
    my (%overrides) = @_;
    return {
        ok     => 1,
        loans  => $overrides{loans} // [ safe_loan() ],
        pagination => $overrides{pagination} // {
            page        => 1,
            per_page    => 20,
            total       => 1,
            total_pages => 1,
        },
    };
}

sub controller {
    my (%args) = @_;
    my $app =
        $args{app}
        || Local::PortalLoanApp->new(
            result => exists $args{result} ? $args{result} : success_result(),
            error  => $args{error},
        );
    my $headers = exists $args{headers}
        ? $args{headers}
        : { 'X-Correlation-ID' => $correlation_id };
    return Local::PatronController->new(
        app       => $app,
        headers   => $headers,
        patron_id => exists $args{patron_id} ? $args{patron_id} : 50,
        page      => $args{page},
        per_page  => $args{per_page},
    );
}

sub run {
    my (%args) = @_;
    my $c = controller(%args);
    $c->list_loans;
    return ( $c->{rendered}, $c->{app}{calls}, $c );
}

my ( $rendered, $calls, $c ) = run();
is $rendered->{status}, 200, 'successful list returns HTTP 200';
is_deeply [ sort keys %{ $rendered->{json} } ], [ sort qw(loans pagination) ],
    'success envelope uses loans and pagination';
is scalar @{ $rendered->{json}{loans} }, 1, 'one loan in success body';
is $rendered->{json}{loans}[0]{portal_request_id}, $portal_request_id,
    'response includes portal_request_id';
ok !exists $rendered->{json}{loans}[0]{approved_by}, 'approved_by absent';
ok !exists $rendered->{json}{loans}[0]{cardnumber},  'no patron PII';
ok !exists $rendered->{json}{loans}[0]{patron_name}, 'no patron name';
unlike JSON_DUMP($rendered), qr/pdf|token|oauth|secret|password|stack/i,
    'response avoids sensitive disclosure markers';
is $c->res->headers->header('Cache-Control'), 'no-store', 'cache disabled';
is scalar @{$calls}, 1, 'application invoked once';
is $calls->[0]{controller}, $c, 'trusted controller passed';
is_deeply(
    {
        map { $_ => $calls->[0]{$_} }
            qw(patron_id page per_page)
    },
    { patron_id => 50, page => 1, per_page => 20 },
    'defaults page=1 per_page=20'
);

( $rendered, $calls ) = run(
    result => success_result(
        loans      => [],
        pagination => {
            page        => 1,
            per_page    => 20,
            total       => 0,
            total_pages => 0
        }
    )
);
is $rendered->{status}, 200, 'empty list returns HTTP 200';
is_deeply $rendered->{json}{loans}, [], 'empty loans array';

( $rendered, $calls ) = run(
    page     => 2,
    per_page => 100,
    result   => success_result(
        loans => [ safe_loan(), { %{ safe_loan() }, loan_id => 2 } ],
        pagination => {
            page        => 2,
            per_page    => 100,
            total       => 2,
            total_pages => 1
        }
    )
);
is $calls->[0]{page},     2,   'page query forwarded';
is $calls->[0]{per_page}, 100, 'per_page max 100 accepted';

for my $case (
    [ 'missing correlation', {}, 50 ],
    [ 'bad correlation', { 'X-Correlation-ID' => 'bad' }, 50 ],
    [ 'padded correlation', { 'X-Correlation-ID' => " $correlation_id" }, 50 ],
  )
{
    my ( $label, $headers, $patron_id ) = @{$case};
    ( $rendered, $calls ) = run( headers => $headers, patron_id => $patron_id );
    is $rendered->{status}, 400, "$label -> 400";
    is $rendered->{json}{error}{code}, 'INVALID_INPUT', "$label INVALID_INPUT";
    is scalar @{$calls}, 0, "$label does not call application";
}

for my $patron_id ( 0, -1, '01', '50a', '1.5' ) {
    ( $rendered, $calls ) = run( patron_id => $patron_id );
    is $rendered->{status}, 400, "bad patron $patron_id -> 400";
    is $rendered->{json}{error}{code}, 'INVALID_INPUT',
        "bad patron $patron_id INVALID_INPUT";
    is scalar @{$calls}, 0, "bad patron $patron_id skips application";
}

for my $case ( [ page => 0 ], [ page => '01' ], [ per_page => 0 ], [ per_page => 101 ] )
{
    my ( $field, $value ) = @{$case};
    ( $rendered, $calls ) = run( $field => $value );
    is $rendered->{status}, 400, "bad $field=$value -> 400";
    is $rendered->{json}{error}{code}, 'INVALID_INPUT',
        "bad $field INVALID_INPUT";
    is scalar @{$calls}, 0, "bad $field skips application";
}

( $rendered, $calls ) = run(
    result => { ok => 0, code => 'AUTHENTICATION_REQUIRED' } );
is $rendered->{status}, 401, 'missing authentication -> 401';
is $rendered->{json}{error}{code}, 'AUTHENTICATION_REQUIRED',
    'authn code preserved';

( $rendered, $calls ) = run(
    result => { ok => 0, code => 'SERVICE_ACCOUNT_NOT_AUTHORIZED' } );
is $rendered->{status}, 403, 'actor 51 denial -> 403';
is $rendered->{json}{error}{code}, 'SERVICE_ACCOUNT_NOT_AUTHORIZED',
    'uses SERVICE_ACCOUNT_NOT_AUTHORIZED not PORTAL_SERVICE_NOT_AUTHORIZED';

( $rendered, $calls ) = run(
    result => { ok => 0, code => 'DIGITAL_CIRCULATION_UNAVAILABLE' } );
is $rendered->{status}, 503, 'unavailable -> 503';

( $rendered, $calls ) = run( result => { ok => 0, code => 'WEIRD' } );
is $rendered->{status}, 500, 'unknown code -> 500';
is $rendered->{json}{error}{code}, 'INTERNAL_ERROR',
    'unknown code remapped to INTERNAL_ERROR';

( $rendered, $calls ) = run( error => 'boom' );
is $rendered->{status}, 500, 'application exception -> 500';

( $rendered, $calls ) = run(
    result => {
        ok         => 1,
        loans      => 'bad',
        pagination => {
            page        => 1,
            per_page    => 20,
            total       => 0,
            total_pages => 0
        }
    }
);
is $rendered->{status}, 500, 'malformed success envelope -> 500';

sub JSON_DUMP {
    my ($rendered) = @_;
    require JSON;
    return JSON::encode_json( $rendered->{json} // {} );
}

done_testing;
