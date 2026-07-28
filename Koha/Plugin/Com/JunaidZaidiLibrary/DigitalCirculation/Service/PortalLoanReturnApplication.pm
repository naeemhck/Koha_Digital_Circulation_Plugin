package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReturnApplication;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanReturnService;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;

my %SAFE_RETURN_CODE = map { $_ => 1 } qw(
    INVALID_INPUT
    AUTHENTICATION_REQUIRED
    SERVICE_ACCOUNT_NOT_AUTHORIZED
    LOAN_NOT_FOUND
    LOAN_CORRELATION_MISMATCH
    VERSION_CONFLICT
    LOAN_NOT_RETURNABLE
    DIGITAL_CIRCULATION_UNAVAILABLE
    INTERNAL_ERROR
);

my @SAFE_LOAN_RESPONSE_FIELDS = qw(
    loan_id request_id portal_request_id patron_id biblio_id status
    started_at due_at returned_at revoked_at expired_at
    renewal_count row_version created_at updated_at
);

my %KNOWN_SERVICE_LOAN_FIELDS = map { $_ => 1 } @SAFE_LOAN_RESPONSE_FIELDS;

my %ALLOWED_COMMAND_KEYS = map { $_ => 1 } qw(
    controller
    loan_id
    patron_id
    portal_request_id
    expected_row_version
    correlation_id
);

sub new {
    my ( $class, %args ) = @_;
    my $return_service = $args{return_service};
    unless ($return_service) {
        my $plugin = $args{plugin};
        my %service_args;
        $service_args{table_resolver} = sub {
            my ($name) = @_;
            return $plugin->table($name);
        } if blessed($plugin) && $plugin->can('table');
        $return_service =
            Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanReturnService->new(
                %service_args
            );
    }

    return bless {
        authorization =>
            $args{authorization}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization
            ->new( plugin => $args{plugin} ),
        return_service => $return_service,
        diagnostic     => $args{diagnostic} || sub { return },
    }, $class;
}

sub return_loan {
    my ( $self, %args ) = @_;

    my $authorization = $self->_authorize( $args{controller} );
    return $authorization unless $authorization->{ok};
    my $actor_id = $authorization->{actor_id};

    my $command = $self->_validate_command(%args);
    return $command unless $command->{ok};

    my $result;
    my $invoked = eval {
        $result = $self->{return_service}->return_loan(
            loan_id              => $command->{loan_id},
            patron_id            => $command->{patron_id},
            portal_request_id    => $command->{portal_request_id},
            expected_row_version => $command->{expected_row_version},
            actor_id             => $actor_id,
            correlation_id       => $command->{correlation_id},
        );
        1;
    };
    unless ($invoked) {
        $self->_diagnose('return_application_exception');
        return _failure('INTERNAL_ERROR');
    }

    return $self->_normalize_result(
        $result,
        loan_id           => $command->{loan_id},
        patron_id         => $command->{patron_id},
        portal_request_id => $command->{portal_request_id},
        correlation_id    => $command->{correlation_id},
        actor_id          => $actor_id,
    );
}

sub _authorize {
    my ( $self, $controller ) = @_;
    my $authorization = $self->{authorization};
    return $self->_dependency_failure(
        'service_account_not_authorized',
        'SERVICE_ACCOUNT_NOT_AUTHORIZED'
    ) unless blessed($authorization)
        && $authorization->can('authorize_controller');

    my $result;
    my $authorized = eval {
        $result = $authorization->authorize_controller($controller);
        1;
    };
    unless ($authorized) {
        $self->_diagnose('return_application_exception');
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
        if ( $code eq 'SERVICE_ACCOUNT_NOT_AUTHORIZED' ) {
            $self->_diagnose('service_account_not_authorized');
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

    unless ( _positive_decimal( $command{loan_id} )
        && _positive_decimal( $command{patron_id} )
        && _positive_decimal( $command{expected_row_version} )
        && _uuid( $command{portal_request_id} )
        && _uuid( $command{correlation_id} ) )
    {
        $self->_diagnose('invalid_command');
        return _failure('INVALID_INPUT');
    }

    return {
        ok                   => 1,
        loan_id              => 0 + $command{loan_id},
        patron_id            => 0 + $command{patron_id},
        expected_row_version => 0 + $command{expected_row_version},
        portal_request_id    => lc $command{portal_request_id},
        correlation_id       => $command{correlation_id},
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
        if ( $SAFE_RETURN_CODE{$code} ) {
            $self->_diagnose('return_service_failure');
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

    my %safe_loan;
    for my $field (@SAFE_LOAN_RESPONSE_FIELDS) {
        return $self->_dependency_failure(
            'malformed_service_result',
            'INTERNAL_ERROR'
        ) unless exists $loan->{$field};
        $safe_loan{$field} = $loan->{$field};
    }

    return $self->_dependency_failure(
        'malformed_service_result',
        'INTERNAL_ERROR'
    ) unless _positive_decimal( $safe_loan{loan_id} )
        && 0 + $safe_loan{loan_id} == $expected{loan_id}
        && _positive_decimal( $safe_loan{patron_id} )
        && 0 + $safe_loan{patron_id} == $expected{patron_id}
        && _uuid( $safe_loan{portal_request_id} )
        && lc( $safe_loan{portal_request_id} ) eq lc( $expected{portal_request_id} )
        && ( $safe_loan{status} // '' ) eq 'RETURNED'
        && _timestamp( $safe_loan{returned_at} )
        && defined $result->{idempotent_replay}
        && ( $result->{idempotent_replay} == 1 || $result->{idempotent_replay} == 0 )
        && _uuid( $result->{correlation_id} )
        && $result->{correlation_id} eq $expected{correlation_id};

    for my $numeric (
        qw(loan_id request_id patron_id biblio_id renewal_count row_version)
        )
    {
        return $self->_dependency_failure(
            'malformed_service_result',
            'INTERNAL_ERROR'
        ) unless defined $safe_loan{$numeric}
            && !ref( $safe_loan{$numeric} )
            && (
            _positive_decimal( $safe_loan{$numeric} )
            || ( $numeric eq 'renewal_count'
                && $safe_loan{$numeric} =~ /\A[0-9]+\z/ )
            );
        $safe_loan{$numeric} = 0 + $safe_loan{$numeric};
    }
    $safe_loan{portal_request_id} = lc $safe_loan{portal_request_id};

    return {
        ok                => 1,
        loan              => \%safe_loan,
        idempotent_replay => $result->{idempotent_replay} ? 1 : 0,
        correlation_id    => $result->{correlation_id},
        actor_id          => $expected{actor_id},
    };
}

sub _diagnose {
    my ( $self, $name ) = @_;
    eval { $self->{diagnostic}->($name) };
    return;
}

sub _dependency_failure {
    my ( $self, $diagnostic, $code ) = @_;
    $self->_diagnose($diagnostic);
    return _failure($code);
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
