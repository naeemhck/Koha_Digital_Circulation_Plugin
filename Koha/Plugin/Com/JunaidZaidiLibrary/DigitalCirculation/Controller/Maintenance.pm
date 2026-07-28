package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Maintenance;

use Modern::Perl;
use Mojo::Base 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Base';

sub expire_loans {
    my ($c) = @_;
    $c->res->headers->header('Cache-Control' => 'no-store');
    my $correlation_id = eval { $c->req->headers->header('X-Correlation-ID') };
    return _error($c, 'INVALID_INPUT', 400) unless _uuid($correlation_id);
    my $content_type = eval { $c->req->headers->content_type };
    return _error($c, 'INVALID_INPUT', 400)
        unless defined($content_type) && $content_type =~ /\Aapplication\/json(?:\s*;\s*charset=[A-Za-z0-9._-]+)?\z/i;
    my $body = eval { $c->req->json };
    return _error($c, 'INVALID_INPUT', 400)
        unless ref($body) eq 'HASH' && !keys(%{$body});

    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanExpiryApplication;
    my $plugin = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    my $application = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanExpiryApplication->new(
        plugin => $plugin
    );
    my $result = eval {
        $application->expire_due(
            controller     => $c,
            correlation_id => $correlation_id,
        );
    };
    return _error($c, 'INTERNAL_ERROR', 500) unless ref($result) eq 'HASH';
    unless ($result->{ok}) {
        my %status = (
            INVALID_INPUT => 400,
            AUTHENTICATION_REQUIRED => 401,
            SERVICE_ACCOUNT_NOT_AUTHORIZED => 403,
            AUTOMATIC_EXPIRY_DISABLED => 409,
            EXPIRY_SWEEP_BUSY => 409,
            DIGITAL_CIRCULATION_UNAVAILABLE => 503,
        );
        return _error($c, $result->{code}, $status{$result->{code}} || 500);
    }
    return $c->render(status => 200, json => {
        scanned_count  => 0 + $result->{scanned_count},
        expired_count  => 0 + $result->{expired_count},
        skipped_count  => 0 + $result->{skipped_count},
        loans           => $result->{loans},
        correlation_id  => $result->{correlation_id},
    });
}

sub _error {
    my ($c, $code, $status) = @_;
    my %message = (
        INVALID_INPUT => 'Request data is invalid.',
        AUTHENTICATION_REQUIRED => 'Authentication is required.',
        SERVICE_ACCOUNT_NOT_AUTHORIZED => 'The authenticated service account is not authorized.',
        AUTOMATIC_EXPIRY_DISABLED => 'Automatic digital-loan expiry is not enabled.',
        EXPIRY_SWEEP_BUSY => 'A digital-loan expiry sweep is already running.',
        DIGITAL_CIRCULATION_UNAVAILABLE => 'Digital circulation is temporarily unavailable.',
        INTERNAL_ERROR => 'The request could not be completed.',
    );
    return $c->render(status => $status, json => {
        error => { code => $code, message => $message{$code} || $message{INTERNAL_ERROR} }
    });
}

sub _uuid {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && $value =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i;
}

1;
