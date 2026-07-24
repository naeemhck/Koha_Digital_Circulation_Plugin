package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffLoanIssuanceApplication;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization;

my %SAFE_ISSUANCE_CODE = map { $_ => 1 } qw(
    INVALID_INPUT
    REQUEST_NOT_FOUND
    REQUEST_NOT_APPROVED
    LOAN_ALREADY_EXISTS
    PROTECTED_CONTENT_UNAVAILABLE
    INVALID_MAPPING
    INVALID_LOAN_PERIOD
    DIGITAL_CIRCULATION_UNAVAILABLE
    INTERNAL_ERROR
);

my @SAFE_LOAN_RESPONSE_FIELDS = qw(
    loan_id request_id patron_id biblio_id status
    started_at due_at row_version
);

my %KNOWN_SERVICE_LOAN_FIELDS = map { $_ => 1 } (
    @SAFE_LOAN_RESPONSE_FIELDS,
    qw(
        returned_at revoked_at expired_at
        approved_by renewal_count created_at updated_at
    )
);

my %ALLOWED_COMMAND_KEYS = map { $_ => 1 } qw(controller request_id);

sub new {
    my ( $class, %args ) = @_;
    my $issuance_service = $args{issuance_service};
    unless ($issuance_service) {
        my $plugin = $args{plugin};
        if ( blessed($plugin) && $plugin->can('_build_loan_issuance_service') ) {
            $issuance_service = $plugin->_build_loan_issuance_service;
        }
        else {
            my %service_args;
            $service_args{table_resolver} = sub {
                my ($name) = @_;
                return $plugin->table($name);
            } if blessed($plugin) && $plugin->can('table');
            $issuance_service =
                Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService->new(
                    %service_args
                );
        }
    }

    return bless {
        authorization =>
            $args{authorization}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StaffDecisionAuthorization->new(
                plugin => $args{plugin}
            ),
        issuance_service => $issuance_service,
        diagnostic       => $args{diagnostic} || sub { return },
    }, $class;
}

sub issue_loan {
    my ( $self, %args ) = @_;

    my $authorization = $self->_authorize( $args{controller} );
    return $authorization unless $authorization->{ok};
    my $actor_id = $authorization->{actor_id};

    my $command = $self->_validate_command(%args);
    return $command unless $command->{ok};

    my $result;
    my $invoked = eval {
        $result = $self->{issuance_service}->issue_loan(
            request_id => $command->{request_id},
            actor_id   => $actor_id,
        );
        1;
    };
    unless ($invoked) {
        $self->_diagnose('issuance_application_exception');
        return _failure('INTERNAL_ERROR');
    }

    return $self->_normalize_result(
        $result,
        request_id => $command->{request_id},
        actor_id   => $actor_id,
    );
}

sub _authorize {
    my ( $self, $controller ) = @_;
    my $authorization = $self->{authorization};
    return $self->_dependency_failure(
        'staff_not_authorized',
        'STAFF_NOT_AUTHORIZED'
    ) unless blessed($authorization)
        && $authorization->can('authorize_controller');

    my $result;
    my $authorized = eval {
        $result = $authorization->authorize_controller($controller);
        1;
    };
    unless ($authorized) {
        $self->_diagnose('issuance_application_exception');
        return _failure('INTERNAL_ERROR');
    }
    return $self->_dependency_failure(
        'malformed_service_result',
        'INTERNAL_ERROR'
    ) unless ref($result) eq 'HASH'
        && exists $result->{allowed};

    unless ( $result->{allowed} ) {
        my $code = $result->{code} // '';
        if ( $code eq 'AUTHENTICATION_REQUIRED' ) {
            $self->_diagnose('authentication_missing');
            return _failure($code);
        }
        if ( $code eq 'STAFF_NOT_AUTHORIZED' ) {
            $self->_diagnose('staff_not_authorized');
            return _failure($code);
        }
        return $self->_dependency_failure(
            'malformed_service_result',
            'INTERNAL_ERROR'
        );
    }

    return $self->_dependency_failure(
        'malformed_service_result',
        'INTERNAL_ERROR'
    ) unless _positive_decimal( $result->{actor_id} );

    return {
        ok       => 1,
        actor_id => 0 + $result->{actor_id},
    };
}

sub _validate_command {
    my ( $self, %command ) = @_;

    for my $key ( keys %command ) {
        unless ( $ALLOWED_COMMAND_KEYS{$key} ) {
            $self->_diagnose('invalid_command');
            return _failure('INVALID_INPUT');
        }
    }

    unless ( _positive_decimal( $command{request_id} ) ) {
        $self->_diagnose('invalid_command');
        return _failure('INVALID_INPUT');
    }

    return {
        ok         => 1,
        request_id => 0 + $command{request_id},
    };
}

sub _normalize_result {
    my ( $self, $result, %expected ) = @_;
    unless ( defined $result && ref($result) eq 'HASH' && exists $result->{ok} )
    {
        return $self->_dependency_failure(
            'malformed_service_result',
            'INTERNAL_ERROR'
        );
    }

    unless ( $result->{ok} ) {
        my $code = $result->{code} // '';
        if ( $SAFE_ISSUANCE_CODE{$code} ) {
            $self->_diagnose('issuance_service_failure');
            return _failure($code);
        }
        return $self->_dependency_failure(
            'malformed_service_result',
            'INTERNAL_ERROR'
        );
    }

    my $loan = $result->{loan};
    return $self->_dependency_failure(
        'malformed_service_result',
        'INTERNAL_ERROR'
    ) unless ref($loan) eq 'HASH';

    for my $field ( keys %{$loan} ) {
        return $self->_dependency_failure(
            'malformed_service_result',
            'INTERNAL_ERROR'
        ) unless $KNOWN_SERVICE_LOAN_FIELDS{$field};
    }

    for my $field (@SAFE_LOAN_RESPONSE_FIELDS) {
        return $self->_dependency_failure(
            'malformed_service_result',
            'INTERNAL_ERROR'
        ) unless exists $loan->{$field};
    }

    return $self->_dependency_failure(
        'malformed_service_result',
        'INTERNAL_ERROR'
    ) unless _positive_decimal( $loan->{loan_id} )
        && _positive_decimal( $loan->{request_id} )
        && 0 + $loan->{request_id} == $expected{request_id}
        && _positive_decimal( $loan->{patron_id} )
        && _positive_decimal( $loan->{biblio_id} )
        && ( $loan->{status} // '' ) eq 'ACTIVE'
        && _timestamp( $loan->{started_at} )
        && _timestamp( $loan->{due_at} )
        && $loan->{due_at} gt $loan->{started_at}
        && _positive_decimal( $loan->{row_version} );

    for my $field (@SAFE_LOAN_RESPONSE_FIELDS) {
        return $self->_dependency_failure(
            'malformed_service_result',
            'INTERNAL_ERROR'
        ) if defined $loan->{$field} && ref( $loan->{$field} );
    }

    my $safe = { map { $_ => $loan->{$_} } @SAFE_LOAN_RESPONSE_FIELDS };
    for my $numeric (qw(loan_id request_id patron_id biblio_id row_version)) {
        $safe->{$numeric} = 0 + $safe->{$numeric};
    }

    return {
        ok   => 1,
        loan => $safe,
    };
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

sub _timestamp {
    my ($value) = @_;
    return defined $value
        && !ref($value)
        && $value =~ /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/;
}

sub _failure {
    my ($code) = @_;
    return {
        ok   => 0,
        code => $code,
    };
}

1;
