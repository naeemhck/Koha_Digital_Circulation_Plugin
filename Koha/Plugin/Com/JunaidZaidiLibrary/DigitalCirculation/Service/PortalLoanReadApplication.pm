package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReadApplication;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;

my %VALID_STATUS = map { $_ => 1 } qw(
    ACTIVE
    RENEWAL_PENDING
    RETURNED
    EXPIRED
    REVOKED
);

my @PUBLIC_LOAN_FIELDS = qw(
    loan_id request_id portal_request_id patron_id biblio_id status
    started_at due_at returned_at revoked_at expired_at
    renewal_count row_version created_at updated_at
);

sub new {
    my ( $class, %args ) = @_;
    my $loan_repository = $args{loan_repository};
    unless ($loan_repository) {
        require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository;
        my %repo_args;
        my $plugin = $args{plugin};
        if ( blessed($plugin) && $plugin->can('table') ) {
            $repo_args{table_name}         = $plugin->table('loans');
            $repo_args{request_table_name} = $plugin->table('requests');
        }
        $loan_repository =
            Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository
            ->new(%repo_args);
    }
    return bless {
        authorization =>
            $args{authorization}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization
            ->new( plugin => $args{plugin} ),
        loan_repository => $loan_repository,
        dbh             => $args{dbh},
        diagnostic      => $args{diagnostic} || sub { return },
    }, $class;
}

sub list_patron_loans {
    my ( $self, %args ) = @_;

    my $authorization = $self->_authorize( $args{controller} );
    return $authorization unless $authorization->{ok};

    return _failure('INVALID_INPUT')
        unless _positive_decimal( $args{patron_id} );
    my $patron_id = 0 + $args{patron_id};

    my $page = exists $args{page} ? $args{page} : 1;
    $page = 1 unless defined $page && length($page);
    return _failure('INVALID_INPUT') unless _positive_decimal($page);
    $page = 0 + $page;

    my $per_page = exists $args{per_page} ? $args{per_page} : 20;
    $per_page = 20 unless defined $per_page && length($per_page);
    return _failure('INVALID_INPUT')
        unless _positive_decimal($per_page) && $per_page <= 100;
    $per_page = 0 + $per_page;

    my $repository = $self->{loan_repository};
    return $self->_dependency_failure('REPOSITORY_DEPENDENCY_INVALID')
        unless blessed($repository) && $repository->can('list_for_patron');

    my $dbh;
    my $dbh_ok = eval {
        $dbh = $self->{dbh} || _koha_dbh();
        1;
    };
    return $self->_dependency_failure('DATABASE_UNAVAILABLE')
        unless $dbh_ok && $dbh;

    my $result;
    my $read_ok = eval {
        $result = $repository->list_for_patron(
            $dbh,
            patron_id => $patron_id,
            page      => $page,
            per_page  => $per_page,
        );
        1;
    };
    return $self->_dependency_failure('REPOSITORY_READ_FAILED')
        unless $read_ok;

    return $self->_normalize_list_result( $result, $patron_id, $page, $per_page );
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

sub _normalize_list_result {
    my ( $self, $result, $patron_id, $page, $per_page ) = @_;
    return $self->_dependency_failure('REPOSITORY_RESULT_INVALID')
        unless ref($result) eq 'HASH'
        && ref( $result->{loans} ) eq 'ARRAY'
        && defined $result->{total}
        && !ref( $result->{total} )
        && $result->{total} =~ /\A[0-9]+\z/
        && _positive_decimal( $result->{page} )
        && _positive_decimal( $result->{per_page} )
        && 0 + $result->{page} == $page
        && 0 + $result->{per_page} == $per_page;

    my @loans;
    for my $row ( @{ $result->{loans} } ) {
        my $item = $self->_normalize_loan_item( $row, $patron_id );
        return $item unless $item->{ok};
        push @loans, $item->{loan};
    }

    my $total       = 0 + $result->{total};
    my $total_pages = $total == 0 ? 0 : int( ( $total + $per_page - 1 ) / $per_page );
    return {
        ok   => 1,
        loans => \@loans,
        pagination => {
            page        => $page,
            per_page    => $per_page,
            total       => $total,
            total_pages => $total_pages,
        },
    };
}

sub _normalize_loan_item {
    my ( $self, $row, $patron_id ) = @_;
    return $self->_internal_failure('LOAN_ITEM_INVALID')
        unless ref($row) eq 'HASH';

    return $self->_internal_failure('LOAN_ID_INVALID')
        unless _positive_decimal( $row->{loan_id} );
    return $self->_internal_failure('REQUEST_ID_INVALID')
        unless _positive_decimal( $row->{request_id} );
    return $self->_internal_failure('JOINED_REQUEST_MISMATCH')
        unless _positive_decimal( $row->{joined_request_id} )
        && 0 + $row->{joined_request_id} == 0 + $row->{request_id};

    return $self->_internal_failure('PATRON_MISMATCH')
        unless _positive_decimal( $row->{patron_id} )
        && 0 + $row->{patron_id} == $patron_id
        && _positive_decimal( $row->{request_patron_id} )
        && 0 + $row->{request_patron_id} == $patron_id;

    return $self->_internal_failure('BIBLIO_MISMATCH')
        unless _positive_decimal( $row->{biblio_id} )
        && _positive_decimal( $row->{request_biblio_id} )
        && 0 + $row->{biblio_id} == 0 + $row->{request_biblio_id};

    return $self->_internal_failure('PORTAL_REQUEST_ID_INVALID')
        unless _uuid( $row->{portal_request_id} );

    my $status = $row->{status};
    return $self->_internal_failure('STATUS_INVALID')
        unless defined $status
        && !ref($status)
        && $VALID_STATUS{$status};

    return $self->_internal_failure('STARTED_AT_INVALID')
        unless _datetime( $row->{started_at} );
    return $self->_internal_failure('DUE_AT_INVALID')
        unless _datetime( $row->{due_at} );
    return $self->_internal_failure('DUE_NOT_AFTER_STARTED')
        unless _datetime_after( $row->{due_at}, $row->{started_at} );

    for my $field (qw(returned_at revoked_at expired_at)) {
        return $self->_internal_failure( uc($field) . '_INVALID' )
            unless _nullable_datetime( $row->{$field} );
    }

    return $self->_internal_failure('RENEWAL_COUNT_INVALID')
        unless defined $row->{renewal_count}
        && !ref( $row->{renewal_count} )
        && $row->{renewal_count} =~ /\A[0-9]+\z/;

    return $self->_internal_failure('ROW_VERSION_INVALID')
        unless _positive_decimal( $row->{row_version} );

    return $self->_internal_failure('CREATED_AT_INVALID')
        unless _datetime( $row->{created_at} );
    return $self->_internal_failure('UPDATED_AT_INVALID')
        unless _datetime( $row->{updated_at} );

    for my $value ( values %{$row} ) {
        return $self->_internal_failure('UNSAFE_NESTED_VALUE')
            if ref($value);
    }

    my %loan = map { $_ => $row->{$_} } @PUBLIC_LOAN_FIELDS;
    $loan{loan_id}        = 0 + $loan{loan_id};
    $loan{request_id}     = 0 + $loan{request_id};
    $loan{patron_id}      = 0 + $loan{patron_id};
    $loan{biblio_id}      = 0 + $loan{biblio_id};
    $loan{renewal_count}  = 0 + $loan{renewal_count};
    $loan{row_version}    = 0 + $loan{row_version};
    $loan{portal_request_id} = lc $loan{portal_request_id};

    return {
        ok   => 1,
        loan => \%loan,
    };
}

sub _koha_dbh {
    require C4::Context;
    return C4::Context->dbh;
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

sub _datetime {
    my ($value) = @_;
    return defined $value
        && !ref($value)
        && $value =~
/\A\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\z/;
}

sub _nullable_datetime {
    my ($value) = @_;
    return 1 unless defined $value;
    return _datetime($value);
}

sub _datetime_after {
    my ( $later, $earlier ) = @_;
    my $normalize = sub {
        my ($value) = @_;
        $value =~ s/T/ /;
        $value =~ s/(?:Z|[+-]\d{2}:?\d{2})\z//;
        $value =~ s/\.\d+\z//;
        return $value;
    };
    return $normalize->($later) gt $normalize->($earlier);
}

sub _dependency_failure {
    my ( $self, $category ) = @_;
    $self->_diagnose($category);
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE');
}

sub _internal_failure {
    my ( $self, $category ) = @_;
    $self->_diagnose($category);
    return _failure('INTERNAL_ERROR');
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
