package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalRequestApplication;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestService;

my %SAFE_PERSISTENCE_CODE = map { $_ => 1 } qw(
    INVALID_INPUT
    INVALID_IDEMPOTENCY_KEY
    IDEMPOTENCY_CONFLICT
    DIGITAL_CIRCULATION_UNAVAILABLE
    INTERNAL_ERROR
);

sub new {
    my ( $class, %args ) = @_;
    my $request_service = $args{request_service};
    unless ($request_service) {
        my %service_args;
        my $plugin = $args{plugin};
        $service_args{table_resolver} = sub {
            my ($name) = @_;
            return $plugin->table($name);
        } if blessed($plugin) && $plugin->can('table');
        $request_service =
            Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestService->new(
                %service_args
            );
    }
    return bless {
        authorization =>
            $args{authorization}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization->new(
                plugin => $args{plugin}
            ),
        patron_validator => $args{patron_validator} || \&_default_patron_validator,
        eligibility =>
            $args{eligibility}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility->new,
        request_service => $request_service,
        diagnostic => $args{diagnostic} || sub { return },
    }, $class;
}

sub create_request {
    my ( $self, %args ) = @_;

    my $authorization = $self->_authorize( $args{controller} );
    return $authorization unless $authorization->{ok};
    my $actor_id = $authorization->{actor_id};

    return _failure('INVALID_INPUT')
        unless _positive_decimal( $args{patron_id} );
    my $patron_id = 0 + $args{patron_id};

    my $patron_result;
    my $patron_ok = eval {
        $patron_result = $self->{patron_validator}->($patron_id);
        1;
    };
    unless ($patron_ok) {
        my $error = defined $@ ? "$@" : '';
        return _failure('PATRON_NOT_FOUND')
            if $error =~ /\AINVALID_PATRON\b/;
        $self->_diagnose('PATRON_LOOKUP_FAILED');
        return _failure('DIGITAL_CIRCULATION_UNAVAILABLE');
    }
    my $patron_state = _patron_state( $patron_result, $patron_id );
    return _failure('PATRON_NOT_FOUND')
        if $patron_state eq 'NOT_FOUND';
    if ( $patron_state ne 'FOUND' ) {
        $self->_diagnose('PATRON_RESULT_INVALID');
        return _failure('DIGITAL_CIRCULATION_UNAVAILABLE');
    }

    return _failure('INVALID_INPUT')
        unless _positive_decimal( $args{biblio_id} );
    my $biblio_id = 0 + $args{biblio_id};

    my $eligibility = $self->_check_eligibility($biblio_id);
    return $eligibility unless $eligibility->{ok};

    my $persistence;
    my $persistence_ok = eval {
        $persistence = $self->{request_service}->create_portal_request(
            actor_id          => $actor_id,
            patron_id         => $patron_id,
            biblio_id         => $biblio_id,
            portal_request_id => $args{portal_request_id},
            idempotency_key   => $args{idempotency_key},
            correlation_id    => $args{correlation_id},
            source            => 'PORTAL',
        );
        1;
    };
    unless ($persistence_ok) {
        $self->_diagnose('REQUEST_PERSISTENCE_FAILED');
        return _failure('DIGITAL_CIRCULATION_UNAVAILABLE');
    }

    return $self->_normalize_persistence(
        $persistence,
        $args{correlation_id}
    );
}

sub _authorize {
    my ( $self, $controller ) = @_;
    my $authorization_service = $self->{authorization};
    return $self->_dependency_failure('AUTHORIZATION_DEPENDENCY_INVALID')
        unless blessed($authorization_service)
        && $authorization_service->can('authorize_controller');

    my $result;
    my $read = eval {
        $result = $authorization_service->authorize_controller($controller);
        1;
    };
    return $self->_dependency_failure('AUTHORIZATION_FAILED')
        unless $read;
    return $self->_dependency_failure('AUTHORIZATION_RESULT_INVALID')
        unless ref($result) eq 'HASH'
        && exists $result->{allowed};

    unless ( $result->{allowed} ) {
        my $code = $result->{code} // '';
        return _failure($code)
            if $code eq 'AUTHENTICATION_REQUIRED'
            || $code eq 'SERVICE_ACCOUNT_NOT_AUTHORIZED';
        return $self->_dependency_failure('AUTHORIZATION_RESULT_INVALID');
    }

    return $self->_dependency_failure('AUTHORIZATION_RESULT_INVALID')
        unless _positive_decimal( $result->{actor_id} );
    return {
        ok       => 1,
        actor_id => 0 + $result->{actor_id},
    };
}

sub _check_eligibility {
    my ( $self, $biblio_id ) = @_;
    my $eligibility_service = $self->{eligibility};
    return $self->_dependency_failure('ELIGIBILITY_DEPENDENCY_INVALID')
        unless blessed($eligibility_service)
        && $eligibility_service->can('check_biblio_eligibility');

    my $result;
    my $read = eval {
        $result = $eligibility_service->check_biblio_eligibility(
            biblio_id => $biblio_id
        );
        1;
    };
    return $self->_dependency_failure('ELIGIBILITY_LOOKUP_FAILED')
        unless $read;
    return $self->_dependency_failure('ELIGIBILITY_RESULT_INVALID')
        unless ref($result) eq 'HASH'
        && exists $result->{eligible};

    if ( $result->{eligible} ) {
        return $self->_dependency_failure('ELIGIBILITY_RESULT_INVALID')
            unless _positive_decimal( $result->{biblio_id} )
            && 0 + $result->{biblio_id} == $biblio_id;
        return { ok => 1 };
    }

    my $code   = $result->{code} // '';
    my $reason = $result->{reason} // '';
    return _failure('BIBLIO_NOT_FOUND')
        if $code eq 'BIBLIO_NOT_FOUND';
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE')
        if $reason eq 'CONTENT_LOOKUP_UNAVAILABLE';
    return _failure('CONTENT_NOT_ELIGIBLE')
        if $code eq 'CONTENT_NOT_ELIGIBLE';
    return $self->_dependency_failure('ELIGIBILITY_RESULT_INVALID');
}

sub _normalize_persistence {
    my ( $self, $result, $correlation_id ) = @_;
    return $self->_dependency_failure('PERSISTENCE_RESULT_INVALID')
        unless ref($result) eq 'HASH'
        && exists $result->{ok};

    unless ( $result->{ok} ) {
        my $code = $result->{code} // '';
        return _failure($code) if $SAFE_PERSISTENCE_CODE{$code};
        return $self->_dependency_failure('PERSISTENCE_RESULT_INVALID');
    }

    my $outcome = $result->{outcome} // '';
    my %flags = (
        CREATED            => [ 0, 0 ],
        IDEMPOTENT_REPLAY  => [ 1, 0 ],
        DUPLICATE_PENDING  => [ 0, 1 ],
    );
    return $self->_dependency_failure('PERSISTENCE_RESULT_INVALID')
        unless exists $flags{$outcome}
        && ref( $result->{request} ) eq 'HASH'
        && defined $correlation_id
        && !ref($correlation_id)
        && ( $result->{correlation_id} // '' ) eq $correlation_id
        && exists $result->{idempotent_replay}
        && exists $result->{duplicate_pending}
        && !!$result->{idempotent_replay} == $flags{$outcome}[0]
        && !!$result->{duplicate_pending} == $flags{$outcome}[1];

    return {
        ok                => 1,
        outcome           => $outcome,
        request           => $result->{request},
        idempotent_replay => $flags{$outcome}[0],
        duplicate_pending => $flags{$outcome}[1],
        correlation_id    => $correlation_id,
    };
}

sub _default_patron_validator {
    my ($patron_id) = @_;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::Validation;
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::Validation::assert_patron(
        $patron_id
    );
    return {
        found     => 1,
        patron_id => 0 + $patron_id,
    };
}

sub _positive_decimal {
    my ($value) = @_;
    return defined $value && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
}

sub _patron_state {
    my ( $result, $patron_id ) = @_;
    return 'NOT_FOUND' unless defined $result;
    if ( !ref($result) ) {
        return 'FOUND'     if "$result" eq '1';
        return 'NOT_FOUND' if "$result" eq '0';
        return 'INVALID';
    }
    return 'INVALID' unless ref($result) eq 'HASH'
        && exists $result->{found};
    return 'NOT_FOUND' unless $result->{found};
    return 'INVALID'
        unless _positive_decimal( $result->{patron_id} )
        && 0 + $result->{patron_id} == $patron_id;
    return 'FOUND';
}

sub _dependency_failure {
    my ( $self, $category ) = @_;
    $self->_diagnose($category);
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE');
}

sub _diagnose {
    my ( $self, $category ) = @_;
    eval { $self->{diagnostic}->($category) };
    return;
}

sub _failure {
    my ($code) = @_;
    return {
        ok   => 0,
        code => $code,
    };
}

1;
