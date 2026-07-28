package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Loans;

use Modern::Perl;
use Mojo::Base 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Base';
use Mojo::JSON qw(true false);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository;

my %ERROR = (
    INVALID_INPUT => [
        400,
        'Request data is invalid.',
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
        'The authenticated staff user is not authorized.',
    ],
    LOAN_NOT_FOUND => [
        404,
        'The digital loan was not found.',
    ],
    LOAN_CORRELATION_MISMATCH => [
        409,
        'The digital loan does not match the supplied identities.',
    ],
    VERSION_CONFLICT => [
        409,
        'The loan has changed. Refresh it before trying again.',
    ],
    LOAN_NOT_RETURNABLE => [
        409,
        'The digital loan cannot be returned in its current state.',
    ],
    RENEWALS_DISABLED => [ 409, 'Digital loan renewal is not enabled.' ],
    STAFF_REVOCATIONS_DISABLED => [ 409, 'Digital loan revocation is not enabled.' ],
    LOAN_NOT_RENEWABLE => [ 409, 'The digital loan cannot be renewed in its current state.' ],
    LOAN_NOT_REVOCABLE => [ 409, 'The digital loan cannot be revoked in its current state.' ],
    MAXIMUM_RENEWALS_REACHED => [ 409, 'The maximum number of renewals has been reached.' ],
    LOAN_PAST_DUE => [ 409, 'Past-due digital loans cannot be renewed.' ],
    DIGITAL_CIRCULATION_UNAVAILABLE => [
        503,
        'Digital circulation is temporarily unavailable.',
    ],
    INTERNAL_ERROR => [
        500,
        'The request could not be completed.',
    ],
);

my @PUBLIC_LOAN_FIELDS = qw(
    loan_id
    request_id
    portal_request_id
    patron_id
    biblio_id
    status
    started_at
    due_at
    returned_at
    revoked_at
    expired_at
    renewal_count
    row_version
    created_at
    updated_at
);

sub list {
    my $c = shift;
    return $c->query(
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository->new,
        'loan_id',
        'LOAN_NOT_FOUND'
    );
}

sub get {
    return shift->list(@_);
}

sub return_loan {
    my ($c) = @_;
    $c->res->headers->header( 'Cache-Control' => 'no-store' );

    my $loan_id = eval { $c->param('loan_id') };
    return _render_error( $c, 'INVALID_INPUT' )
        unless _positive_decimal($loan_id);

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
        unless $body_read && _valid_return_body($body);

    my $application;
    my $constructed = eval {
        $application = $c->_portal_loan_return_application;
        1;
    };
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless $constructed
        && $application
        && eval { $application->can('return_loan') };

    my $result;
    my $invoked = eval {
        $result = $application->return_loan(
            controller           => $c,
            loan_id              => 0 + $loan_id,
            patron_id            => $body->{patron_id},
            portal_request_id    => $body->{portal_request_id},
            expected_row_version => $body->{expected_row_version},
            correlation_id       => $correlation_id,
        );
        1;
    };
    return _render_error( $c, 'INTERNAL_ERROR' ) unless $invoked;

    return _render_return_result(
        $c,
        $result,
        loan_id        => 0 + $loan_id,
        correlation_id => $correlation_id,
    );
}

sub renew {
    my ($c) = @_;
    my $parsed = _parse_lifecycle_request(
        $c,
        [qw(patron_id portal_request_id expected_row_version)],
        sub {
            my ($body) = @_;
            return _positive_decimal($body->{patron_id})
                && _uuid($body->{portal_request_id})
                && _positive_decimal($body->{expected_row_version});
        }
    );
    return unless $parsed;
    my $application = eval { $c->_portal_loan_renewal_application };
    return _render_error($c, 'INTERNAL_ERROR') unless $application;
    my $result = eval {
        $application->renew(
            controller           => $c,
            loan_id              => $parsed->{loan_id},
            patron_id            => $parsed->{body}{patron_id},
            portal_request_id    => $parsed->{body}{portal_request_id},
            expected_row_version => $parsed->{body}{expected_row_version},
            correlation_id       => $parsed->{correlation_id},
        );
    };
    return _render_lifecycle_result(
        $c, $result,
        loan_id        => $parsed->{loan_id},
        correlation_id => $parsed->{correlation_id},
        status         => 'ACTIVE',
    );
}

sub revoke {
    my ($c) = @_;
    my $parsed = _parse_lifecycle_request(
        $c,
        [qw(expected_row_version reason)],
        sub {
            my ($body) = @_;
            return _positive_decimal($body->{expected_row_version})
                && _reason($body->{reason});
        }
    );
    return unless $parsed;
    my $application = eval { $c->_staff_loan_revocation_application };
    return _render_error($c, 'INTERNAL_ERROR') unless $application;
    my $result = eval {
        $application->revoke(
            controller           => $c,
            loan_id              => $parsed->{loan_id},
            expected_row_version => $parsed->{body}{expected_row_version},
            correlation_id       => $parsed->{correlation_id},
            reason               => $parsed->{body}{reason},
        );
    };
    return _render_lifecycle_result(
        $c, $result,
        loan_id        => $parsed->{loan_id},
        correlation_id => $parsed->{correlation_id},
        status         => 'REVOKED',
    );
}

sub _portal_loan_return_application {
    my ($c) = @_;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReturnApplication;
    my $plugin =
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    return
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReturnApplication
        ->new( plugin => $plugin );
}

sub _portal_loan_renewal_application {
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanRenewalApplication;
    my $plugin = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    return Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanRenewalApplication->new(
        plugin => $plugin
    );
}

sub _staff_loan_revocation_application {
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanRevocationApplication;
    my $plugin = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    return Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanRevocationApplication->new(
        plugin => $plugin
    );
}

sub _parse_lifecycle_request {
    my ( $c, $keys, $validator ) = @_;
    $c->res->headers->header('Cache-Control' => 'no-store');
    my $loan_id = eval { $c->param('loan_id') };
    unless (_positive_decimal($loan_id)) {
        _render_error($c, 'INVALID_INPUT');
        return;
    }
    my $content_type = eval { $c->req->headers->content_type };
    unless (defined($content_type)
        && $content_type =~ /\Aapplication\/json(?:\s*;\s*charset=[A-Za-z0-9._-]+)?\z/i) {
        _render_error($c, 'INVALID_INPUT');
        return;
    }
    my $correlation_id = eval { $c->req->headers->header('X-Correlation-ID') };
    unless (_uuid($correlation_id)) {
        _render_error($c, 'INVALID_INPUT');
        return;
    }
    my $body = eval { $c->req->json };
    unless (ref($body) eq 'HASH') {
        _render_error($c, 'INVALID_INPUT');
        return;
    }
    my %allowed = map { $_ => 1 } @{$keys};
    if (grep { !$allowed{$_} } keys %{$body}) {
        _render_error($c, 'INVALID_INPUT');
        return;
    }
    unless ($validator->($body)) {
        _render_error($c, 'INVALID_INPUT');
        return;
    }
    return {
        loan_id        => 0 + $loan_id,
        correlation_id => $correlation_id,
        body           => $body,
    };
}

sub _render_lifecycle_result {
    my ( $c, $result, %expected ) = @_;
    return _render_error($c, 'INTERNAL_ERROR')
        unless ref($result) eq 'HASH' && exists $result->{ok};
    return _render_error($c, $result->{code})
        unless $result->{ok};
    my $loan = $result->{loan};
    return _render_error($c, 'INTERNAL_ERROR')
        unless ref($loan) eq 'HASH'
        && _positive_decimal($loan->{loan_id})
        && $loan->{loan_id} == $expected{loan_id}
        && ($loan->{status} // '') eq $expected{status}
        && _uuid($result->{correlation_id})
        && $result->{correlation_id} eq $expected{correlation_id};
    my %public;
    for my $field (@PUBLIC_LOAN_FIELDS) {
        return _render_error($c, 'INTERNAL_ERROR') unless exists $loan->{$field};
        $public{$field} = $loan->{$field};
    }
    return $c->render(
        status => 200,
        json => {
            loan => \%public,
            idempotent_replay => $result->{idempotent_replay} ? true : false,
            correlation_id => $result->{correlation_id},
        }
    );
}

sub _valid_return_body {
    my ($body) = @_;
    return unless ref($body) eq 'HASH';
    my %allowed = map { $_ => 1 }
        qw(patron_id portal_request_id expected_row_version);
    for my $key ( keys %{$body} ) {
        return unless $allowed{$key};
    }
    return unless _positive_decimal( $body->{patron_id} );
    return unless _uuid( $body->{portal_request_id} );
    return unless _positive_decimal( $body->{expected_row_version} );
    return 1;
}

sub _render_return_result {
    my ( $c, $result, %expected ) = @_;
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless ref($result) eq 'HASH'
        && exists $result->{ok};

    unless ( $result->{ok} ) {
        my $code = $result->{code} // '';
        return _render_error( $c, $code ) if exists $ERROR{$code};
        return _render_error( $c, 'INTERNAL_ERROR' );
    }

    my $loan = $result->{loan};
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless ref($loan) eq 'HASH'
        && defined $result->{idempotent_replay}
        && _uuid( $result->{correlation_id} )
        && $result->{correlation_id} eq $expected{correlation_id}
        && _positive_decimal( $loan->{loan_id} )
        && 0 + $loan->{loan_id} == $expected{loan_id}
        && ( $loan->{status} // '' ) eq 'RETURNED';

    my %public;
    for my $field (@PUBLIC_LOAN_FIELDS) {
        return _render_error( $c, 'INTERNAL_ERROR' )
            unless exists $loan->{$field};
        $public{$field} = $loan->{$field};
    }

    return $c->render(
        status => 200,
        json   => {
            loan              => \%public,
            idempotent_replay => $result->{idempotent_replay} ? true : false,
            correlation_id    => $result->{correlation_id},
        }
    );
}

sub _render_error {
    my ( $c, $code ) = @_;
    my $entry = $ERROR{$code} || $ERROR{INTERNAL_ERROR};
    return $c->render(
        status => $entry->[0],
        json   => {
            error => {
                code    => ( $ERROR{$code} ? $code : 'INTERNAL_ERROR' ),
                message => $entry->[1],
            }
        }
    );
}

sub _positive_decimal {
    my ($value) = @_;
    return defined $value && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
}

sub _uuid {
    my ($value) = @_;
    return defined $value
        && !ref($value)
        && $value =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i;
}

sub _reason {
    my ($value) = @_;
    return unless defined($value) && !ref($value)
        && $value !~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
    $value =~ s/\A\s+|\s+\z//g;
    return length($value) >= 3 && length($value) <= 500;
}

1;
