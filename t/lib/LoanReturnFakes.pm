package Local::LoanReturnDBH;

use Modern::Perl;
use Storable qw(dclone);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        requests       => $args{requests} || [],
        events         => $args{events}   || [],
        loans          => $args{loans}    || [],
        renewals       => $args{renewals} || [],
        native_issues  => $args{native_issues} || [],
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
            requests      => $self->{requests},
            events        => $self->{events},
            loans         => $self->{loans},
            renewals      => $self->{renewals},
            native_issues => $self->{native_issues},
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
        for my $field (qw(requests events loans renewals native_issues)) {
            $self->{$field} = $self->{snapshot}->{$field};
        }
        delete $self->{snapshot};
    }
    die $self->{rollback_error} if $self->{rollback_error};
    return 1;
}

package Local::LoanReturnLoanRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        get_error    => $args{get_error},
        update_error => $args{update_error},
        race_return  => $args{race_return},
        calls        => [],
    }, $class;
}

sub get_for_return {
    my ( $self, $dbh, $loan_id, %options ) = @_;
    push @{ $self->{calls} },
        [ get_for_return => $loan_id, $options{for_update} ? 1 : 0 ];
    die $self->{get_error} if $self->{get_error};
    my ($loan) = grep { $_->{loan_id} == $loan_id } @{ $dbh->{loans} };
    return unless $loan;
    my ($request) =
        grep { $_->{request_id} == $loan->{request_id} } @{ $dbh->{requests} };
    return unless $request;
    return {
        %{$loan},
        portal_request_id  => $request->{portal_request_id},
        joined_request_id  => $request->{request_id},
        request_patron_id  => $request->{patron_id},
        request_biblio_id  => $request->{biblio_id},
    };
}

sub update_active_return {
    my ( $self, $dbh, %args ) = @_;
    push @{ $self->{calls} }, [ update_active_return => {%args} ];
    die $self->{update_error} if $self->{update_error};
    if ( $self->{race_return} ) {
        my $winner = delete $self->{race_return};
        for my $loan ( @{ $dbh->{loans} } ) {
            next unless $loan->{loan_id} == $args{loan_id};
            $loan->{status}      = 'RETURNED';
            $loan->{returned_at} = $winner->{returned_at};
            $loan->{row_version} = $winner->{row_version};
            $loan->{updated_at}  = $winner->{returned_at};
            last;
        }
        return 0;
    }
    for my $loan ( @{ $dbh->{loans} } ) {
        next unless $loan->{loan_id} == $args{loan_id};
        return 0 unless ( $loan->{status} // '' ) eq 'ACTIVE';
        return 0 unless 0 + $loan->{row_version} == 0 + $args{expected_row_version};
        return 0 if defined $loan->{returned_at};
        $loan->{status}      = 'RETURNED';
        $loan->{returned_at} = $args{returned_at};
        $loan->{row_version} = 0 + $loan->{row_version} + 1;
        $loan->{updated_at}  = $args{returned_at};
        return 1;
    }
    return 0;
}

package Local::LoanReturnEventRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        insert_error => $args{insert_error},
        calls        => [],
    }, $class;
}

sub insert_loan_returned_event {
    my ( $self, $dbh, %args ) = @_;
    push @{ $self->{calls} }, [ insert_loan_returned_event => {%args} ];
    die $self->{insert_error} if $self->{insert_error};
    push @{ $dbh->{events} },
        {
        event_type => 'LOAN_RETURNED',
        %args,
        };
    return 1;
}

1;
