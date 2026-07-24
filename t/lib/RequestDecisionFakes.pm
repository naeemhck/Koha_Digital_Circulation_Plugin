package Local::RequestDecisionDBH;

use Modern::Perl;
use Storable qw(dclone);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        requests      => $args{requests} || [],
        events        => $args{events} || [],
        loans         => $args{loans} || [],
        renewals      => $args{renewals} || [],
        commit_error  => $args{commit_error},
        rollback_error => $args{rollback_error},
        calls         => [],
    }, $class;
}

sub begin_work {
    my ($self) = @_;
    push @{ $self->{calls} }, 'begin';
    $self->{snapshot} = dclone(
        {
            requests => $self->{requests},
            events   => $self->{events},
            loans    => $self->{loans},
            renewals => $self->{renewals},
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
        for my $field (qw(requests events loans renewals)) {
            $self->{$field} = $self->{snapshot}->{$field};
        }
        delete $self->{snapshot};
    }
    die $self->{rollback_error} if $self->{rollback_error};
    return 1;
}

package Local::RequestDecisionRequestRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        get_error     => $args{get_error},
        update_error  => $args{update_error},
        update_result => $args{update_result},
        race_row      => $args{race_row},
        calls         => [],
    }, $class;
}

sub get_for_decision {
    my ( $self, $dbh, $request_id ) = @_;
    push @{ $self->{calls} }, [ get_for_decision => $request_id ];
    die $self->{get_error} if $self->{get_error};
    return _copy($_)
        for grep { $_->{request_id} == $request_id } @{ $dbh->{requests} };
    return;
}

sub update_pending_decision {
    my ( $self, $dbh, %args ) = @_;
    push @{ $self->{calls} }, [ update_pending_decision => { %args } ];
    die $self->{update_error} if $self->{update_error};

    if ( $self->{race_row} ) {
        my $winner = delete $self->{race_row};
        for my $index ( 0 .. $#{ $dbh->{requests} } ) {
            next
                unless $dbh->{requests}[$index]{request_id}
                == $args{request_id};
            $dbh->{requests}[$index] = _copy($winner);
            last;
        }
        return 0;
    }
    return $self->{update_result} if defined $self->{update_result};

    for my $request ( @{ $dbh->{requests} } ) {
        next unless $request->{request_id} == $args{request_id};
        next unless $request->{status} eq 'PENDING';
        next
            unless $request->{row_version}
            == $args{expected_row_version};

        $request->{status} = $args{status};
        if ( $args{decision} eq 'APPROVE' ) {
            $request->{approved_at} = $args{decided_at};
            $request->{approved_by} = $args{actor_id};
        }
        else {
            $request->{rejected_at}      = $args{decided_at};
            $request->{rejected_by}      = $args{actor_id};
            $request->{rejection_reason} = $args{reason};
        }
        $request->{updated_at} = $args{decided_at};
        $request->{row_version}++;
        return 1;
    }
    return 0;
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

package Local::RequestDecisionEventRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        insert_error => $args{insert_error},
        calls        => [],
    }, $class;
}

sub insert_request_approved_event {
    my ( $self, $dbh, %args ) = @_;
    return $self->_insert( $dbh, 'REQUEST_APPROVED', %args );
}

sub insert_request_rejected_event {
    my ( $self, $dbh, %args ) = @_;
    return $self->_insert( $dbh, 'REQUEST_REJECTED', %args );
}

sub _insert {
    my ( $self, $dbh, $event_type, %args ) = @_;
    my $event = {
        event_type => $event_type,
        %args,
    };
    push @{ $self->{calls} }, { %{$event} };
    die $self->{insert_error} if $self->{insert_error};
    push @{ $dbh->{events} }, $event;
    return 1;
}

1;
