package Local::LoanIssuanceDBH;

use Modern::Perl;
use Storable qw(dclone);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        requests       => $args{requests} || [],
        events         => $args{events}   || [],
        loans          => $args{loans}    || [],
        renewals       => $args{renewals} || [],
        next_loan_id   => $args{next_loan_id} // 1,
        commit_error   => $args{commit_error},
        rollback_error => $args{rollback_error},
        calls          => [],
    }, $class;
}

sub begin_work {
    my ($self) = @_;
    push @{ $self->{calls} }, 'begin';
    $self->{snapshot} = dclone(
        {
            requests     => $self->{requests},
            events       => $self->{events},
            loans        => $self->{loans},
            renewals     => $self->{renewals},
            next_loan_id => $self->{next_loan_id},
        }
    );
    return 1;
}

sub commit {
    my ($self) = @_;
    push @{ $self->{calls} }, 'commit';
    die $self->{commit_error} if $self->{commit_error};
    delete $self->{snapshot};
    return 1;
}

sub rollback {
    my ($self) = @_;
    push @{ $self->{calls} }, 'rollback';
    if ( $self->{snapshot} ) {
        for my $field (qw(requests events loans renewals next_loan_id)) {
            $self->{$field} = $self->{snapshot}->{$field};
        }
        delete $self->{snapshot};
    }
    die $self->{rollback_error} if $self->{rollback_error};
    return 1;
}

package Local::LoanIssuanceRequestRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        get_error => $args{get_error},
        calls     => [],
    }, $class;
}

sub get_for_issuance {
    my ( $self, $dbh, $request_id ) = @_;
    push @{ $self->{calls} }, [ get_for_issuance => $request_id ];
    die $self->{get_error} if $self->{get_error};
    return _copy($_)
        for grep { $_->{request_id} == $request_id } @{ $dbh->{requests} };
    return;
}

sub get_by_id {
    my ( $self, $dbh, $request_id ) = @_;
    push @{ $self->{calls} }, [ get_by_id => $request_id ];
    return _copy($_)
        for grep { $_->{request_id} == $request_id } @{ $dbh->{requests} };
    return;
}

sub _copy {
    my ($row) = @_;
    return { %{$row} };
}

package Local::LoanIssuanceLoanRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        insert_error  => $args{insert_error},
        find_error    => $args{find_error},
        race_loan     => $args{race_loan},
        calls         => [],
    }, $class;
}

sub find_by_request_id {
    my ( $self, $dbh, $request_id, %options ) = @_;
    push @{ $self->{calls} },
        [ find_by_request_id => $request_id, $options{for_update} ? 1 : 0 ];
    die $self->{find_error} if $self->{find_error};
    if ( $self->{race_loan} ) {
        my $winner = delete $self->{race_loan};
        push @{ $dbh->{loans} }, _copy($winner);
    }
    return _copy($_)
        for grep { $_->{request_id} == $request_id } @{ $dbh->{loans} };
    return;
}

sub insert_active_loan {
    my ( $self, $dbh, %args ) = @_;
    push @{ $self->{calls} }, [ insert_active_loan => {%args} ];
    die $self->{insert_error} if $self->{insert_error};
    if ( grep { $_->{request_id} == $args{request_id} } @{ $dbh->{loans} } ) {
        die "Duplicate entry for key 'jzl_loan_request_uq'\n";
    }
    my $loan = {
        loan_id       => $dbh->{next_loan_id}++,
        request_id    => $args{request_id},
        patron_id     => $args{patron_id},
        biblio_id     => $args{biblio_id},
        status        => $args{status},
        started_at    => $args{started_at},
        due_at        => $args{due_at},
        returned_at   => undef,
        revoked_at    => undef,
        expired_at    => undef,
        approved_by   => $args{approved_by},
        renewal_count => 0,
        created_at    => $args{started_at},
        updated_at    => $args{started_at},
        row_version   => 1,
    };
    push @{ $dbh->{loans} }, $loan;
    return _copy($loan);
}

sub get_by_id {
    my ( $self, $dbh, $loan_id ) = @_;
    return _copy($_) for grep { $_->{loan_id} == $loan_id } @{ $dbh->{loans} };
    return;
}

sub _copy {
    my ($row) = @_;
    return { %{$row} };
}

package Local::LoanIssuanceEventRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        insert_error => $args{insert_error},
        calls        => [],
    }, $class;
}

sub insert_loan_created_event {
    my ( $self, $dbh, %args ) = @_;
    push @{ $self->{calls} }, [ insert_loan_created_event => {%args} ];
    die $self->{insert_error} if $self->{insert_error};
    push @{ $dbh->{events} },
        {
        event_type => 'LOAN_CREATED',
        %args,
        };
    return 1;
}

package Local::LoanIssuanceEligibility;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        result => $args{result}
            // {
            eligible   => 1,
            biblio_id  => $args{biblio_id} // 1,
            content_id => 9,
            code       => undef,
            },
        error => $args{error},
        calls => [],
    }, $class;
}

sub check_biblio_eligibility {
    my ( $self, %args ) = @_;
    push @{ $self->{calls} }, [%args];
    die $self->{error} if $self->{error};
    my $result = $self->{result};
    if ( ref($result) eq 'CODE' ) {
        return $result->(%args);
    }
    return {%$result};
}

1;
