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
