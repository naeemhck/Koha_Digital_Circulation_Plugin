package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Patrons;

use Modern::Perl;
use Mojo::Base 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Base';

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
    DIGITAL_CIRCULATION_UNAVAILABLE => [
        503,
        'Digital circulation is temporarily unavailable.',
    ],
    INTERNAL_ERROR => [
        500,
        'The request could not be completed.',
    ],
);

sub list_loans {
    my ($c) = @_;
    $c->res->headers->header( 'Cache-Control' => 'no-store' );

    my $headers = $c->req->headers;
    my $correlation_id = eval { $headers->header('X-Correlation-ID') };
    return _render_error( $c, 'INVALID_INPUT' )
        unless _uuid($correlation_id);

    my $patron_id = eval { $c->param('patron_id') };
    return _render_error( $c, 'INVALID_INPUT' )
        unless _positive_decimal($patron_id);

    my $page = eval { $c->param('page') };
    if ( defined $page && length($page) ) {
        return _render_error( $c, 'INVALID_INPUT' )
            unless _positive_decimal($page);
        $page = 0 + $page;
    }
    else {
        $page = 1;
    }

    my $per_page = eval { $c->param('per_page') };
    if ( defined $per_page && length($per_page) ) {
        return _render_error( $c, 'INVALID_INPUT' )
            unless _positive_decimal($per_page) && $per_page <= 100;
        $per_page = 0 + $per_page;
    }
    else {
        $per_page = 20;
    }

    my $application;
    my $constructed = eval {
        $application = $c->_portal_loan_read_application;
        1;
    };
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless $constructed
        && $application
        && eval { $application->can('list_patron_loans') };

    my $result;
    my $invoked = eval {
        $result = $application->list_patron_loans(
            controller => $c,
            patron_id  => 0 + $patron_id,
            page       => $page,
            per_page   => $per_page,
        );
        1;
    };
    return _render_error( $c, 'INTERNAL_ERROR' ) unless $invoked;

    return _render_list_result( $c, $result );
}

sub _portal_loan_read_application {
    my ($c) = @_;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReadApplication;
    my $plugin =
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    return
        Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReadApplication
        ->new( plugin => $plugin );
}

sub _render_list_result {
    my ( $c, $result ) = @_;
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless ref($result) eq 'HASH'
        && exists $result->{ok};

    unless ( $result->{ok} ) {
        my $code = $result->{code} // '';
        return _render_error( $c, $code ) if exists $ERROR{$code};
        return _render_error( $c, 'INTERNAL_ERROR' );
    }

    return _render_error( $c, 'INTERNAL_ERROR' )
        unless ref( $result->{loans} ) eq 'ARRAY'
        && ref( $result->{pagination} ) eq 'HASH';

    my $pagination = $result->{pagination};
    for my $field (qw(page per_page total total_pages)) {
        return _render_error( $c, 'INTERNAL_ERROR' )
            unless defined $pagination->{$field}
            && !ref( $pagination->{$field} )
            && $pagination->{$field} =~ /\A[0-9]+\z/;
    }
    return _render_error( $c, 'INTERNAL_ERROR' )
        unless $pagination->{page} =~ /\A[1-9][0-9]*\z/
        && $pagination->{per_page} =~ /\A[1-9][0-9]*\z/;

    return $c->render(
        status => 200,
        json   => {
            loans      => $result->{loans},
            pagination => {
                page        => 0 + $pagination->{page},
                per_page    => 0 + $pagination->{per_page},
                total       => 0 + $pagination->{total},
                total_pages => 0 + $pagination->{total_pages},
            },
        },
    );
}

sub _render_error {
    my ( $c, $code ) = @_;
    my $entry = $ERROR{$code} || $ERROR{INTERNAL_ERROR};
    my ( $status, $message ) = @{$entry};
    return $c->render(
        status => $status,
        json   => {
            error => {
                code    => exists $ERROR{$code} ? $code : 'INTERNAL_ERROR',
                message => $message,
            },
        },
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
        && $value =~
/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i;
}

1;
