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

1;
