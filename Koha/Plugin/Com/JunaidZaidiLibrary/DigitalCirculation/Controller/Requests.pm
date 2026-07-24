package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests;

use Modern::Perl;
use Mojo::Base 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Base';
use Mojo::JSON qw(true false);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository;

my %ERROR = (
    INVALID_INPUT => [
        400,
        'Request data is invalid.',
    ],
    INVALID_IDEMPOTENCY_KEY => [
        400,
        'The idempotency key is invalid.',
    ],
    INVALID_DECISION => [
        400,
        'The request decision is invalid.',
    ],
    INVALID_REASON => [
        400,
        'The decision reason is invalid.',
    ],
    AUTHENTICATION_REQUIRED => [
        401,
        'Authentication is required.',
    ],
    SERVICE_ACCOUNT_NOT_AUTHORIZED => [
        403,
        'The authenticated service account is not authorized.',
    ],
    STAFF_NOT_AUTHORIZED => [
        403,
        'The authenticated staff user is not authorized to decide digital requests.',
    ],
    REQUEST_NOT_FOUND => [
        404,
        'The digital request was not found.',
    ],
    PATRON_NOT_FOUND => [
        404,
        'The patron was not found.',
    ],
    BIBLIO_NOT_FOUND => [
        404,
        'The bibliographic record was not found.',
    ],
    CONTENT_NOT_ELIGIBLE => [
        409,
        'The bibliographic record is not eligible for digital circulation.',
    ],
    IDEMPOTENCY_CONFLICT => [
        409,
        'The idempotency key conflicts with an existing request.',
    ],
    VERSION_CONFLICT => [
        409,
        'The request has changed. Refresh it before trying again.',
    ],
    REQUEST_ALREADY_DECIDED => [
        409,
        'The request has already been decided.',
    ],
    INVALID_STATE => [
        409,
        'The request cannot be decided in its current state.',
    ],
    DIGITAL_CIRCULATION_UNAVAILABLE => [
        503,
        'Digital circulation is temporarily unavailable.',
    ],
    INTERNAL_ERROR => [
        500,
        'The request could not be completed.',
    ],
);

my @PUBLIC_REQUEST_FIELDS = qw(
    request_id
    portal_request_id
    patron_id
    biblio_id
    status
    requested_at
    row_version
);

my @PUBLIC_STAFF_DECISION_FIELDS = qw(
    request_id
    portal_request_id
    patron_id
    biblio_id
    status
    requested_at
    approved_at
    approved_by
    rejected_at
    rejected_by
    rejection_reason
    row_version
);

sub list {
    my $c = shift;
    return $c->query(
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository->new,
        'request_id',
        'REQUEST_NOT_FOUND'
    );
}

sub get {
    return shift->list(@_);
}

sub create {
    my ($c) = @_;
    $c->res->headers->header( 'Cache-Control' => 'no-store' );

    my $headers = $c->req->headers;
    my $content_type = eval { $headers->content_type };
    return _render_error( $c, 'INVALID_INPUT' )
        unless defined $content_type
        && $content_type =~ /\Aapplication\/json(?:\s*;\s*charset=[A-Za-z0-9._-]+)?\z/i;

    my $idempotency_key = eval { $headers->header('Idempotency-Key') };
    return _render_error( $c, 'INVALID_IDEMPOTENCY_KEY' )
        unless _uuid($idempotency_key);

    my $correlation_id = eval { $headers->header('X-Correlation-ID') };
    return _render_error( $c, 'INVALID_INPUT' )
        unless _uuid($correlation_id);

    my $body;
    my $body_read = eval {
        $body = $c->req->json;
        1;
    };
    return _render_error( $c, 'INVALID_INPUT' )
        unless $body_read && _valid_body($body);

    my $application;
    my $constructed = eval {
        $application = $c->_portal_request_application;
        1;
    };
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless $constructed
        && $application
        && eval { $application->can('create_request') };

    my $result;
    my $invoked = eval {
        $result = $application->create_request(
            controller        => $c,
            patron_id         => $body->{patron_id},
            biblio_id         => $body->{biblio_id},
            portal_request_id => $body->{portal_request_id},
            idempotency_key   => $idempotency_key,
            correlation_id    => $correlation_id,
        );
        1;
    };
    return _render_error( $c, 'INTERNAL_ERROR' ) unless $invoked;

    return _render_result( $c, $result, $correlation_id );
}

sub decide {
    my ($c) = @_;
    $c->res->headers->header( 'Cache-Control' => 'no-store' );

    my $request_id = eval { $c->param('request_id') };
    return _render_error( $c, 'INVALID_INPUT' )
        unless _positive_decimal($request_id);

    my $headers = $c->req->headers;
    my $content_type = eval { $headers->content_type };
    return _render_error( $c, 'INVALID_INPUT' )
        unless defined $content_type
        && $content_type =~ /\Aapplication\/json(?:\s*;\s*charset=[A-Za-z0-9._-]+)?\z/i;

    my $correlation_id = eval { $headers->header('X-Correlation-ID') };
    return _render_error( $c, 'INVALID_INPUT' )
        unless _uuid($correlation_id);

    my $body;
    my $body_read = eval {
        $body = $c->req->json;
        1;
    };
    return _render_error( $c, 'INVALID_INPUT' )
        unless $body_read && _valid_decision_body($body);

    my $application;
    my $constructed = eval {
        $application = $c->_staff_request_decision_application;
        1;
    };
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless $constructed
        && $application
        && eval { $application->can('decide_request') };

    my $result;
    my $invoked = eval {
        $result = $application->decide_request(
            controller           => $c,
            request_id           => 0 + $request_id,
            expected_row_version => $body->{expected_row_version},
            decision             => $body->{decision},
            reason               => $body->{reason},
            correlation_id       => $correlation_id,
        );
        1;
    };
    return _render_error( $c, 'INTERNAL_ERROR' ) unless $invoked;

    return _render_decision_result(
        $c,
        $result,
        request_id     => 0 + $request_id,
        correlation_id => $correlation_id,
    );
}

sub _portal_request_application {
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalRequestApplication;

    my $plugin =
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    return Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalRequestApplication->new(
        plugin => $plugin
    );
}

sub _staff_request_decision_application {
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffRequestDecisionApplication;

    my $plugin =
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    return Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffRequestDecisionApplication->new(
        plugin => $plugin
    );
}

sub _render_result {
    my ( $c, $result, $correlation_id ) = @_;
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless ref($result) eq 'HASH'
        && exists $result->{ok};

    unless ( $result->{ok} ) {
        my $code = $result->{code} // '';
        return _render_error(
            $c,
            exists $ERROR{$code} ? $code : 'INTERNAL_ERROR'
        );
    }

    my %outcome = (
        CREATED           => [ 201, false, false ],
        IDEMPOTENT_REPLAY => [ 200, true,  false ],
        DUPLICATE_PENDING => [ 200, false, true ],
    );
    my $mapping = $outcome{ $result->{outcome} // '' };
    my $request = _public_request( $result->{request} );
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless $mapping
        && $request
        && ( $result->{correlation_id} // '' ) eq $correlation_id;

    return $c->render(
        status => $mapping->[0],
        json   => {
            request           => $request,
            idempotent_replay => $mapping->[1],
            duplicate_pending => $mapping->[2],
            correlation_id    => $correlation_id,
        }
    );
}

sub _render_error {
    my ( $c, $code ) = @_;
    $code = 'INTERNAL_ERROR' unless exists $ERROR{$code};
    my ( $status, $message ) = @{ $ERROR{$code} };
    return $c->render(
        status => $status,
        json   => {
            error => {
                code    => $code,
                message => $message,
            }
        }
    );
}

sub _render_decision_result {
    my ( $c, $result, %expected ) = @_;
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless ref($result) eq 'HASH'
        && exists $result->{ok};

    unless ( $result->{ok} ) {
        my $code = $result->{code} // '';
        return _render_error(
            $c,
            exists $ERROR{$code} ? $code : 'INTERNAL_ERROR'
        );
    }

    my $status = $result->{new_status} // '';
    my $request = _public_staff_decision_request( $result->{request} );
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless $request
        && ( $status eq 'APPROVED' || $status eq 'REJECTED' )
        && ( $result->{outcome} // '' ) eq $status
        && ( $result->{previous_status} // '' ) eq 'PENDING'
        && $request->{status} eq $status
        && $request->{request_id} == $expected{request_id}
        && _positive_decimal( $result->{previous_row_version} )
        && _positive_decimal( $result->{row_version} )
        && 0 + $result->{row_version}
        == 0 + $result->{previous_row_version} + 1
        && $request->{row_version} == 0 + $result->{row_version}
        && defined $result->{correlation_id}
        && !ref( $result->{correlation_id} )
        && $result->{correlation_id} eq $expected{correlation_id};

    return $c->render(
        status => 200,
        json   => {
            request              => $request,
            previous_status      => 'PENDING',
            new_status           => $status,
            previous_row_version => 0 + $result->{previous_row_version},
            row_version          => 0 + $result->{row_version},
            correlation_id       => $expected{correlation_id},
        }
    );
}

sub _valid_body {
    my ($body) = @_;
    return unless ref($body) eq 'HASH';
    return unless keys %{$body} == 3;
    for my $field (qw(portal_request_id patron_id biblio_id)) {
        return unless exists $body->{$field};
    }
    return _uuid( $body->{portal_request_id} )
        && _positive_decimal( $body->{patron_id} )
        && _positive_decimal( $body->{biblio_id} );
}

sub _valid_decision_body {
    my ($body) = @_;
    return unless ref($body) eq 'HASH';
    return unless keys %{$body} == 2 || keys %{$body} == 3;
    return unless exists $body->{expected_row_version}
        && exists $body->{decision};
    for my $field ( keys %{$body} ) {
        return unless $field eq 'expected_row_version'
            || $field eq 'decision'
            || $field eq 'reason';
    }
    return _positive_decimal( $body->{expected_row_version} )
        && defined $body->{decision}
        && !ref( $body->{decision} );
}

sub _public_request {
    my ($request) = @_;
    return unless ref($request) eq 'HASH';
    for my $field (@PUBLIC_REQUEST_FIELDS) {
        return unless exists $request->{$field};
    }
    return unless _positive_decimal( $request->{request_id} )
        && _uuid( $request->{portal_request_id} )
        && _positive_decimal( $request->{patron_id} )
        && _positive_decimal( $request->{biblio_id} )
        && defined $request->{status}
        && !ref( $request->{status} )
        && $request->{status} =~ /\A(?:PENDING|APPROVED|REJECTED|CANCELLED)\z/
        && defined $request->{requested_at}
        && !ref( $request->{requested_at} )
        && length $request->{requested_at}
        && _positive_decimal( $request->{row_version} );

    return {
        request_id        => 0 + $request->{request_id},
        portal_request_id => $request->{portal_request_id},
        patron_id         => 0 + $request->{patron_id},
        biblio_id         => 0 + $request->{biblio_id},
        status            => $request->{status},
        requested_at      => $request->{requested_at},
        row_version       => 0 + $request->{row_version},
    };
}

sub _public_staff_decision_request {
    my ($request) = @_;
    return unless ref($request) eq 'HASH';
    for my $field (@PUBLIC_STAFF_DECISION_FIELDS) {
        return unless exists $request->{$field};
        return if defined $request->{$field} && ref( $request->{$field} );
    }

    return unless _positive_decimal( $request->{request_id} )
        && _uuid( $request->{portal_request_id} )
        && _positive_decimal( $request->{patron_id} )
        && _positive_decimal( $request->{biblio_id} )
        && defined $request->{status}
        && $request->{status} =~ /\A(?:APPROVED|REJECTED)\z/
        && defined $request->{requested_at}
        && length $request->{requested_at}
        && _positive_decimal( $request->{row_version} );

    if ( $request->{status} eq 'APPROVED' ) {
        return unless defined $request->{approved_at}
            && length $request->{approved_at}
            && _positive_decimal( $request->{approved_by} )
            && !defined $request->{rejected_at}
            && !defined $request->{rejected_by}
            && !defined $request->{rejection_reason};
    }
    else {
        return unless defined $request->{rejected_at}
            && length $request->{rejected_at}
            && _positive_decimal( $request->{rejected_by} )
            && defined $request->{rejection_reason}
            && length $request->{rejection_reason}
            && length( $request->{rejection_reason} ) <= 4096
            && !defined $request->{approved_at}
            && !defined $request->{approved_by};
    }

    my $public = {
        map { $_ => $request->{$_} } @PUBLIC_STAFF_DECISION_FIELDS
    };
    for my $numeric (qw(request_id patron_id biblio_id row_version)) {
        $public->{$numeric} = 0 + $public->{$numeric};
    }
    for my $actor (qw(approved_by rejected_by)) {
        $public->{$actor} = 0 + $public->{$actor}
            if defined $public->{$actor};
    }
    return $public;
}

sub _positive_decimal {
    my ($value) = @_;
    return defined $value
        && !ref($value)
        && $value =~ /\A[1-9][0-9]*\z/;
}

sub _uuid {
    my ($value) = @_;
    return defined $value
        && !ref($value)
        && $value =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i;
}

1;
