package Local::RequestCreationDBH;

use Modern::Perl;
use Storable qw(dclone);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        requests    => $args{requests} || [],
        events      => $args{events} || [],
        commit_error => $args{commit_error},
        calls       => [],
    }, $class;
}

sub begin_work {
    my ($self) = @_;
    push @{ $self->{calls} }, 'begin';
    $self->{snapshot} = dclone(
        {
            requests => $self->{requests},
            events   => $self->{events},
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
        $self->{requests} = $self->{snapshot}->{requests};
        $self->{events}   = $self->{snapshot}->{events};
        delete $self->{snapshot};
    }
    return 1;
}

sub err {
    return $_[0]->{driver_error};
}

package Local::RequestCreationRequestRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        insert_error => $args{insert_error},
        race         => $args{race},
        calls        => [],
    }, $class;
}

sub find_by_idempotency_key {
    my ( $self, $dbh, $key, %options ) = @_;
    push @{ $self->{calls} }, [ find_idempotency => $key, { %options } ];
    return _copy( $_ )
        for grep { $_->{portal_idempotency_key} eq $key } @{ $dbh->{requests} };
    return;
}

sub find_pending_by_patron_and_biblio {
    my ( $self, $dbh, $patron_id, $biblio_id, %options ) = @_;
    push @{ $self->{calls} }, [ find_pending => $patron_id, $biblio_id, { %options } ];
    return _copy( $_ )
        for grep {
               $_->{patron_id} == $patron_id
            && $_->{biblio_id} == $biblio_id
            && $_->{status} eq 'PENDING'
        } @{ $dbh->{requests} };
    return;
}

sub insert_pending_request {
    my ( $self, $dbh, %args ) = @_;
    push @{ $self->{calls} }, [ insert => { %args } ];
    die $self->{insert_error} if $self->{insert_error};
    if ( $self->{race} ) {
        my $race = delete $self->{race};
        push @{ $dbh->{requests} }, _copy($race);
        $dbh->{driver_error} = 1062;
        die 'DBI duplicate entry with private index at C:\koha\Repository.pm line 8';
    }

    my $request = {
        request_id              => scalar( @{ $dbh->{requests} } ) + 1,
        portal_request_id       => $args{portal_request_id},
        portal_idempotency_key  => $args{idempotency_key},
        source                  => $args{source},
        patron_id               => $args{patron_id},
        biblio_id               => $args{biblio_id},
        status                  => $args{status},
        requested_at            => $args{requested_at},
        created_at              => $args{requested_at},
        updated_at              => $args{requested_at},
        row_version             => $args{row_version},
    };
    push @{ $dbh->{requests} }, $request;
    return _copy($request);
}

sub list { return }
sub get  { return }

sub _copy {
    my ($row) = @_;
    return { %{$row} };
}

package Local::RequestCreationEventRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        insert_error => $args{insert_error},
        calls        => [],
    }, $class;
}

sub insert_request_created_event {
    my ( $self, $dbh, %args ) = @_;
    push @{ $self->{calls} }, { %args };
    die $self->{insert_error} if $self->{insert_error};
    push @{ $dbh->{events} }, { %args };
    return 1;
}

1;
