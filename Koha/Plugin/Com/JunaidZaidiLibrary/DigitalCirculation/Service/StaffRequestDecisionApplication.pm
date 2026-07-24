package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffRequestDecisionApplication;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestDecisionService;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization;

my %SAFE_DECISION_CODE = map { $_ => 1 } qw(
    INVALID_INPUT
    INVALID_DECISION
    INVALID_REASON
    REQUEST_NOT_FOUND
    VERSION_CONFLICT
    REQUEST_ALREADY_DECIDED
    INVALID_STATE
    DIGITAL_CIRCULATION_UNAVAILABLE
    INTERNAL_ERROR
);

my @SAFE_REQUEST_FIELDS = qw(
    request_id portal_request_id source patron_id biblio_id status requested_at
    approved_at approved_by rejected_at rejected_by rejection_reason cancelled_at
    created_at updated_at row_version
);

sub new {
    my ( $class, %args ) = @_;
    my $decision_service = $args{decision_service};
    unless ($decision_service) {
        my %service_args;
        my $plugin = $args{plugin};
        $service_args{table_resolver} = sub {
            my ($name) = @_;
            return $plugin->table($name);
        } if blessed($plugin) && $plugin->can('table');
        $decision_service =
            Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestDecisionService->new(
                %service_args
            );
    }

    return bless {
        authorization =>
            $args{authorization}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization->new(
                plugin => $args{plugin}
            ),
        command_validator =>
            $args{command_validator}
            || sub {
                my (%command) = @_;
                return Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestDecisionService->validate_command(
                    %command
                );
            },
        decision_service => $decision_service,
        diagnostic       => $args{diagnostic} || sub { return },
    }, $class;
}

sub decide_request {
    my ( $self, %args ) = @_;

    my $authorization = $self->_authorize( $args{controller} );
    return $authorization unless $authorization->{ok};
    my $actor_id = $authorization->{actor_id};

    my $command = $self->_validate_command(
        actor_id             => $actor_id,
        request_id           => $args{request_id},
        expected_row_version => $args{expected_row_version},
        decision             => $args{decision},
        reason               => $args{reason},
        correlation_id       => $args{correlation_id},
    );
    return $command unless $command->{ok};

    my $result;
    my $invoked = eval {
        $result = $self->{decision_service}->decide_request(
            actor_id             => $actor_id,
            request_id           => $command->{request_id},
            expected_row_version => $command->{expected_row_version},
            decision             => $command->{decision},
            reason               => $command->{reason},
            correlation_id       => $command->{correlation_id},
        );
        1;
    };
    unless ($invoked) {
        $self->_diagnose('DECISION_SERVICE_FAILED');
        return _failure('INTERNAL_ERROR');
    }

    return $self->_normalize_result(
        $result,
        actor_id             => $actor_id,
        request_id           => $command->{request_id},
        expected_row_version => $command->{expected_row_version},
        decision             => $command->{decision},
        correlation_id       => $command->{correlation_id},
    );
}

sub _authorize {
    my ( $self, $controller ) = @_;
    my $authorization = $self->{authorization};
    return $self->_dependency_failure(
        'AUTHORIZATION_DEPENDENCY_INVALID',
        'STAFF_NOT_AUTHORIZED'
    ) unless blessed($authorization)
        && $authorization->can('authorize_controller');

    my $result;
    my $authorized = eval {
        $result = $authorization->authorize_controller($controller);
        1;
    };
    return $self->_dependency_failure(
        'AUTHORIZATION_FAILED',
        'STAFF_NOT_AUTHORIZED'
    ) unless $authorized;
    return $self->_dependency_failure(
        'AUTHORIZATION_RESULT_INVALID',
        'INTERNAL_ERROR'
    ) unless ref($result) eq 'HASH'
        && exists $result->{allowed};

    unless ( $result->{allowed} ) {
        my $code = $result->{code} // '';
        return _failure($code)
            if $code eq 'AUTHENTICATION_REQUIRED'
            || $code eq 'STAFF_NOT_AUTHORIZED';
        return $self->_dependency_failure(
            'AUTHORIZATION_RESULT_INVALID',
            'INTERNAL_ERROR'
        );
    }

    return $self->_dependency_failure(
        'AUTHORIZATION_RESULT_INVALID',
        'INTERNAL_ERROR'
    ) unless _positive_decimal( $result->{actor_id} );

    return {
        ok       => 1,
        actor_id => 0 + $result->{actor_id},
    };
}

sub _validate_command {
    my ( $self, %command ) = @_;
    my $validator = $self->{command_validator};
    my $result;
    my $executed = eval {
        if ( ref($validator) eq 'CODE' ) {
            $result = $validator->(%command);
        }
        elsif ( blessed($validator) && $validator->can('validate_command') ) {
            $result = $validator->validate_command(%command);
        }
        else {
            die 'INVALID_COMMAND_VALIDATOR';
        }
        1;
    };
    unless ($executed) {
        $self->_diagnose('COMMAND_VALIDATION_FAILED');
        return _failure('INTERNAL_ERROR');
    }

    return $self->_dependency_failure(
        'COMMAND_VALIDATION_RESULT_INVALID',
        'INTERNAL_ERROR'
    ) unless ref($result) eq 'HASH' && exists $result->{ok};
    unless ( $result->{ok} ) {
        my $code = $result->{code} // '';
        return _failure($code)
            if $code eq 'INVALID_INPUT'
            || $code eq 'INVALID_DECISION'
            || $code eq 'INVALID_REASON';
        return $self->_dependency_failure(
            'COMMAND_VALIDATION_RESULT_INVALID',
            'INTERNAL_ERROR'
        );
    }

    return $self->_dependency_failure(
        'COMMAND_VALIDATION_RESULT_INVALID',
        'INTERNAL_ERROR'
    ) unless _positive_decimal( $command{request_id} )
        && _positive_decimal( $command{expected_row_version} )
        && defined $result->{decision}
        && !ref( $result->{decision} )
        && $result->{decision} eq $command{decision}
        && ( $result->{decision} eq 'APPROVE'
            || $result->{decision} eq 'REJECT' )
        && _uuid( $command{correlation_id} )
        && ( !defined $result->{reason} || !ref( $result->{reason} ) );

    return {
        ok                   => 1,
        request_id           => 0 + $command{request_id},
        expected_row_version => 0 + $command{expected_row_version},
        decision             => $result->{decision},
        reason               => $result->{reason},
        correlation_id       => $command{correlation_id},
    };
}

sub _normalize_result {
    my ( $self, $result, %expected ) = @_;
    return $self->_dependency_failure(
        'DECISION_RESULT_INVALID',
        'INTERNAL_ERROR'
    ) unless ref($result) eq 'HASH' && exists $result->{ok};

    unless ( $result->{ok} ) {
        my $code = $result->{code} // '';
        return _failure($code) if $SAFE_DECISION_CODE{$code};
        return $self->_dependency_failure(
            'DECISION_RESULT_INVALID',
            'INTERNAL_ERROR'
        );
    }

    my $target =
        $expected{decision} eq 'APPROVE' ? 'APPROVED' : 'REJECTED';
    return $self->_dependency_failure(
        'DECISION_RESULT_INVALID',
        'INTERNAL_ERROR'
    ) unless ( $result->{outcome} // '' ) eq $target
        && ( $result->{previous_status} // '' ) eq 'PENDING'
        && ( $result->{new_status} // '' ) eq $target
        && _positive_decimal( $result->{previous_row_version} )
        && 0 + $result->{previous_row_version}
        == $expected{expected_row_version}
        && _positive_decimal( $result->{row_version} )
        && 0 + $result->{row_version}
        == $expected{expected_row_version} + 1
        && defined $result->{correlation_id}
        && !ref( $result->{correlation_id} )
        && $result->{correlation_id} eq $expected{correlation_id};

    my $request = _safe_request(
        $result->{request},
        actor_id   => $expected{actor_id},
        request_id => $expected{request_id},
        status     => $target,
        row_version => $result->{row_version},
    );
    return $self->_dependency_failure(
        'DECISION_RESULT_INVALID',
        'INTERNAL_ERROR'
    ) unless $request;

    return {
        ok                   => 1,
        outcome              => $target,
        request              => $request,
        previous_status      => 'PENDING',
        new_status           => $target,
        previous_row_version => 0 + $result->{previous_row_version},
        row_version          => 0 + $result->{row_version},
        correlation_id       => $expected{correlation_id},
    };
}

sub _safe_request {
    my ( $request, %expected ) = @_;
    return unless ref($request) eq 'HASH';
    for my $field (
        qw(
        request_id portal_request_id source patron_id biblio_id status
        requested_at row_version
        )
        )
    {
        return unless exists $request->{$field};
    }
    return unless _positive_decimal( $request->{request_id} )
        && 0 + $request->{request_id} == $expected{request_id};
    return unless _uuid( $request->{portal_request_id} );
    return unless ( $request->{source} // '' ) eq 'PORTAL';
    return unless _positive_decimal( $request->{patron_id} );
    return unless _positive_decimal( $request->{biblio_id} );
    return unless ( $request->{status} // '' ) eq $expected{status};
    return unless defined $request->{requested_at}
        && !ref( $request->{requested_at} )
        && length( $request->{requested_at} );
    return unless _positive_decimal( $request->{row_version} )
        && 0 + $request->{row_version} == 0 + $expected{row_version};
    for my $field (@SAFE_REQUEST_FIELDS) {
        return if exists $request->{$field}
            && defined $request->{$field}
            && ref( $request->{$field} );
    }

    my $actor_field =
        $expected{status} eq 'APPROVED' ? 'approved_by' : 'rejected_by';
    return unless _positive_decimal( $request->{$actor_field} )
        && 0 + $request->{$actor_field} == $expected{actor_id};

    my $safe = { map { $_ => $request->{$_} } @SAFE_REQUEST_FIELDS };
    for my $numeric (qw(request_id patron_id biblio_id row_version)) {
        $safe->{$numeric} = 0 + $safe->{$numeric};
    }
    for my $actor (qw(approved_by rejected_by)) {
        next unless defined $safe->{$actor};
        return unless _positive_decimal( $safe->{$actor} );
        $safe->{$actor} = 0 + $safe->{$actor};
    }
    return $safe;
}

sub _dependency_failure {
    my ( $self, $category, $code ) = @_;
    $self->_diagnose($category);
    return _failure($code);
}

sub _diagnose {
    my ( $self, $category ) = @_;
    eval { $self->{diagnostic}->($category) };
    return;
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

sub _failure {
    my ($code) = @_;
    return {
        ok   => 0,
        code => $code,
    };
}

1;
