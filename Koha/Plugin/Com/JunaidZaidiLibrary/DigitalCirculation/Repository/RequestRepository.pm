package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository;

use Modern::Perl;
use parent 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::Base';

use constant TABLE => 'plugin_jzl_ebook_requests';

my @REQUEST_FIELDS = qw(
    request_id portal_request_id portal_idempotency_key source patron_id biblio_id
    status requested_at approved_at approved_by rejected_at rejected_by
    rejection_reason cancelled_at created_at updated_at row_version
);

sub new {
    my ( $class, %args ) = @_;
    my $self = $class->SUPER::new('requests');
    $self->{table_name} = $args{table_name} // TABLE;
    die 'INVALID_REQUEST_TABLE'
        unless $self->{table_name} eq TABLE;
    return $self;
}

sub find_by_idempotency_key {
    my ( $self, $dbh, $idempotency_key, %options ) = @_;
    return $self->_select_one(
        $dbh,
        'portal_idempotency_key = ?',
        { for_update => $options{for_update} },
        $idempotency_key
    );
}

sub find_pending_by_patron_and_biblio {
    my ( $self, $dbh, $patron_id, $biblio_id, %options ) = @_;
    return $self->_select_one(
        $dbh,
        q{patron_id = ? AND biblio_id = ? AND status = 'PENDING'},
        { for_update => $options{for_update} },
        $patron_id,
        $biblio_id
    );
}

sub get_by_id {
    my ( $self, $dbh, $request_id, %options ) = @_;
    return $self->_select_one(
        $dbh,
        'request_id = ?',
        { for_update => $options{for_update} },
        $request_id
    );
}

sub get_for_decision {
    my ( $self, $dbh, $request_id ) = @_;
    return $self->get_by_id( $dbh, $request_id, for_update => 1 );
}

sub get_for_issuance {
    my ( $self, $dbh, $request_id ) = @_;
    return $self->get_by_id( $dbh, $request_id, for_update => 1 );
}

sub update_pending_decision {
    my ( $self, $dbh, %args ) = @_;
    my $table = $self->{table_name};
    my $affected;

    if ( ( $args{decision} // '' ) eq 'APPROVE' ) {
        $affected = $dbh->do(
            qq{
                UPDATE `$table`
                SET status = ?,
                    approved_at = ?,
                    approved_by = ?,
                    row_version = row_version + 1
                WHERE request_id = ?
                  AND status = 'PENDING'
                  AND row_version = ?
            },
            undef,
            @args{
                qw(
                    status decided_at actor_id request_id expected_row_version
                )
            }
        );
    }
    elsif ( ( $args{decision} // '' ) eq 'REJECT' ) {
        $affected = $dbh->do(
            qq{
                UPDATE `$table`
                SET status = ?,
                    rejected_at = ?,
                    rejected_by = ?,
                    rejection_reason = ?,
                    row_version = row_version + 1
                WHERE request_id = ?
                  AND status = 'PENDING'
                  AND row_version = ?
            },
            undef,
            @args{
                qw(
                    status decided_at actor_id reason request_id
                    expected_row_version
                )
            }
        );
    }
    else {
        die 'INVALID_DECISION';
    }

    die 'REQUEST_DECISION_UPDATE_FAILED' unless defined $affected;
    return 0 + $affected;
}

sub insert_pending_request {
    my ( $self, $dbh, %args ) = @_;
    my $table = $self->{table_name};
    $dbh->do(
        qq{
            INSERT INTO `$table` (
                portal_request_id, portal_idempotency_key, source,
                patron_id, biblio_id, status, requested_at, row_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        @args{
            qw(
                portal_request_id idempotency_key source patron_id biblio_id
                status requested_at row_version
            )
        }
    );

    my $request_id = $dbh->last_insert_id( undef, undef, $table, 'request_id' );
    die 'REQUEST_INSERT_ID_UNAVAILABLE'
        unless defined $request_id && $request_id =~ /\A[1-9][0-9]*\z/;
    return $self->get_by_id( $dbh, $request_id );
}

sub _select_one {
    my ( $self, $dbh, $where, $options, @bind ) = @_;
    my $table  = $self->{table_name};
    my $fields = join ', ', @REQUEST_FIELDS;
    my $lock   = $options->{for_update} ? ' FOR UPDATE' : '';
    my $row    = $dbh->selectrow_hashref(
        "SELECT $fields FROM `$table` WHERE $where$lock",
        undef,
        @bind
    );
    return unless $row;
    return { map { $_ => $row->{$_} } @REQUEST_FIELDS };
}

1;
