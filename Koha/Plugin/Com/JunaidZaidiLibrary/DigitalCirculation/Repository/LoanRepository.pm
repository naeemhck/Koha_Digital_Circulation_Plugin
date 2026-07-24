package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository;

use Modern::Perl;
use parent 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::Base';

use constant TABLE => 'plugin_jzl_ebook_loans';

my @LOAN_FIELDS = qw(
    loan_id request_id patron_id biblio_id status
    started_at due_at returned_at revoked_at expired_at
    approved_by renewal_count created_at updated_at row_version
);

sub new {
    my ( $class, %args ) = @_;
    my $self = $class->SUPER::new('loans');
    $self->{table_name} = $args{table_name} // TABLE;
    die 'INVALID_LOAN_TABLE'
        unless $self->{table_name} eq TABLE;
    return $self;
}

sub find_by_request_id {
    my ( $self, $dbh, $request_id, %options ) = @_;
    return $self->_select_one(
        $dbh,
        'request_id = ?',
        { for_update => $options{for_update} },
        $request_id
    );
}

sub get_by_id {
    my ( $self, $dbh, $loan_id, %options ) = @_;
    return $self->_select_one(
        $dbh,
        'loan_id = ?',
        { for_update => $options{for_update} },
        $loan_id
    );
}

sub insert_active_loan {
    my ( $self, $dbh, %args ) = @_;
    my $table = $self->{table_name};
    my $affected = eval {
        $dbh->do(
            qq{
                INSERT INTO `$table` (
                    request_id, patron_id, biblio_id, status,
                    started_at, due_at, returned_at, revoked_at, expired_at,
                    approved_by, renewal_count, row_version
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, 0, 1)
            },
            undef,
            @args{
                qw(
                    request_id patron_id biblio_id status
                    started_at due_at approved_by
                )
            }
        );
    };
    if ($@) {
        my $error = $@;
        die 'LOAN_ALREADY_EXISTS'
            if $error =~ /jzl_loan_request_uq|Duplicate entry/i;
        die $error;
    }
    die 'LOAN_INSERT_FAILED'
        unless defined $affected && !ref($affected) && $affected == 1;

    my $loan_id = $dbh->last_insert_id( undef, undef, $table, 'loan_id' );
    die 'LOAN_INSERT_ID_UNAVAILABLE'
        unless defined $loan_id && $loan_id =~ /\A[1-9][0-9]*\z/;
    return $self->get_by_id( $dbh, $loan_id );
}

sub _select_one {
    my ( $self, $dbh, $where, $options, @bind ) = @_;
    my $table  = $self->{table_name};
    my $fields = join ', ', @LOAN_FIELDS;
    my $lock   = $options->{for_update} ? ' FOR UPDATE' : '';
    my $row    = $dbh->selectrow_hashref(
        "SELECT $fields FROM `$table` WHERE $where$lock",
        undef,
        @bind
    );
    return unless $row;
    return { map { $_ => $row->{$_} } @LOAN_FIELDS };
}

1;
