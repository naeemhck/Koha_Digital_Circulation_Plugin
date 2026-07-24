package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository;

use Modern::Perl;
use parent 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::Base';

use constant TABLE         => 'plugin_jzl_ebook_loans';
use constant REQUEST_TABLE => 'plugin_jzl_ebook_requests';

my @LOAN_FIELDS = qw(
    loan_id request_id patron_id biblio_id status
    started_at due_at returned_at revoked_at expired_at
    approved_by renewal_count created_at updated_at row_version
);

my @PORTAL_LIST_FIELDS = qw(
    loan_id request_id portal_request_id patron_id biblio_id status
    started_at due_at returned_at revoked_at expired_at
    renewal_count row_version created_at updated_at
    request_patron_id request_biblio_id joined_request_id
);

sub new {
    my ( $class, %args ) = @_;
    my $self = $class->SUPER::new('loans');
    $self->{table_name} = $args{table_name} // TABLE;
    die 'INVALID_LOAN_TABLE'
        unless $self->{table_name} eq TABLE;
    $self->{request_table_name} = $args{request_table_name} // REQUEST_TABLE;
    die 'INVALID_REQUEST_TABLE'
        unless $self->{request_table_name} eq REQUEST_TABLE;
    return $self;
}

sub list_for_patron {
    my ( $self, $dbh, %args ) = @_;
    die 'INVALID_DBH' unless $dbh;

    my $patron_id = $args{patron_id};
    die 'INVALID_PATRON_ID'
        unless defined $patron_id
        && !ref($patron_id)
        && $patron_id =~ /\A[1-9][0-9]*\z/;

    my $page = $args{page} // 1;
    my $per_page = $args{per_page} // 20;
    die 'INVALID_PAGINATION'
        unless defined $page
        && !ref($page)
        && $page =~ /\A[1-9][0-9]*\z/
        && defined $per_page
        && !ref($per_page)
        && $per_page =~ /\A[1-9][0-9]*\z/
        && $per_page <= 100;

    $page     = 0 + $page;
    $per_page = 0 + $per_page;
    $patron_id = 0 + $patron_id;

    my $loans_table    = $self->{table_name};
    my $requests_table = $self->{request_table_name};
    my $offset         = ( $page - 1 ) * $per_page;

    my ($total) = $dbh->selectrow_array(
        qq{
            SELECT COUNT(*)
              FROM `$loans_table` l
              INNER JOIN `$requests_table` r
                ON r.request_id = l.request_id
             WHERE l.patron_id = ?
        },
        undef,
        $patron_id
    );
    die 'LOAN_LIST_COUNT_FAILED' unless defined $total && $total =~ /\A[0-9]+\z/;
    $total = 0 + $total;

    my $rows = $dbh->selectall_arrayref(
        qq{
            SELECT
                l.loan_id,
                l.request_id,
                r.portal_request_id AS portal_request_id,
                l.patron_id,
                l.biblio_id,
                l.status,
                l.started_at,
                l.due_at,
                l.returned_at,
                l.revoked_at,
                l.expired_at,
                l.renewal_count,
                l.row_version,
                l.created_at,
                l.updated_at,
                r.request_id AS joined_request_id,
                r.patron_id AS request_patron_id,
                r.biblio_id AS request_biblio_id
              FROM `$loans_table` l
              INNER JOIN `$requests_table` r
                ON r.request_id = l.request_id
             WHERE l.patron_id = ?
             ORDER BY l.created_at DESC, l.loan_id DESC
             LIMIT ? OFFSET ?
        },
        { Slice => {} },
        $patron_id,
        $per_page,
        $offset
    );
    die 'LOAN_LIST_FAILED' unless ref($rows) eq 'ARRAY';

    my @loans;
    for my $row ( @{$rows} ) {
        push @loans, { map { $_ => $row->{$_} } @PORTAL_LIST_FIELDS };
    }

    return {
        loans    => \@loans,
        total    => $total,
        page     => $page,
        per_page => $per_page,
    };
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
