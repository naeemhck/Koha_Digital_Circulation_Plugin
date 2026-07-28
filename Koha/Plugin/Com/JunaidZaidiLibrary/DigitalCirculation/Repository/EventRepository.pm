package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository;

use Modern::Perl;
use parent 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::Base';

use constant TABLE => 'plugin_jzl_ebook_events';

sub new {
    my ( $class, %args ) = @_;
    my $self = $class->SUPER::new('events');
    $self->{table_name} = $args{table_name} // TABLE;
    die 'INVALID_EVENT_TABLE'
        unless $self->{table_name} eq TABLE;
    return $self;
}

sub insert_request_created_event {
    my ( $self, $dbh, %args ) = @_;
    return $self->_insert_request_event( $dbh, %args );
}

sub insert_request_approved_event {
    my ( $self, $dbh, %args ) = @_;
    $args{event_type} = 'REQUEST_APPROVED';
    return $self->_insert_request_event( $dbh, %args );
}

sub insert_request_rejected_event {
    my ( $self, $dbh, %args ) = @_;
    $args{event_type} = 'REQUEST_REJECTED';
    return $self->_insert_request_event( $dbh, %args );
}

sub insert_loan_created_event {
    my ( $self, $dbh, %args ) = @_;
    $args{event_type} = 'LOAN_CREATED';
    return $self->_insert_request_event( $dbh, %args );
}

sub insert_loan_returned_event {
    my ( $self, $dbh, %args ) = @_;
    $args{event_type} = 'LOAN_RETURNED';
    return $self->_insert_request_event( $dbh, %args );
}

sub insert_loan_renewed_event {
    my ( $self, $dbh, %args ) = @_;
    $args{event_type} = 'LOAN_RENEWED';
    return $self->_insert_request_event( $dbh, %args );
}

sub insert_loan_revoked_event {
    my ( $self, $dbh, %args ) = @_;
    $args{event_type} = 'LOAN_REVOKED';
    return $self->_insert_request_event( $dbh, %args );
}

sub insert_loan_expired_event {
    my ( $self, $dbh, %args ) = @_;
    $args{event_type} = 'LOAN_EXPIRED';
    return $self->_insert_request_event( $dbh, %args );
}

sub find_loan_event_by_correlation {
    my ( $self, $dbh, %args ) = @_;
    my $table = $self->{table_name};
    return $dbh->selectrow_hashref(
        qq{
            SELECT event_id, event_type, loan_id, request_id, correlation_id,
                   actor_patron_id, occurred_at, payload_json
              FROM `$table`
             WHERE event_type = ?
               AND correlation_id = ?
               AND loan_id = ?
             LIMIT 1
        },
        undef,
        $args{event_type},
        $args{correlation_id},
        $args{loan_id}
    );
}

sub _insert_request_event {
    my ( $self, $dbh, %args ) = @_;
    my $table = $self->{table_name};
    my $affected = $dbh->do(
        qq{
            INSERT INTO `$table` (
                event_type, aggregate_type, aggregate_id,
                request_id, loan_id, renewal_id,
                patron_id, biblio_id, actor_patron_id,
                source, correlation_id, occurred_at, payload_json,
                delivery_status, delivery_attempts
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        @args{
            qw(
                event_type aggregate_type aggregate_id
                request_id loan_id renewal_id
                patron_id biblio_id actor_patron_id
                source correlation_id occurred_at payload_json
                delivery_status delivery_attempts
            )
        }
    );
    die 'REQUEST_EVENT_INSERT_FAILED'
        unless defined $affected && !ref($affected) && $affected == 1;
    return 1;
}

1;
