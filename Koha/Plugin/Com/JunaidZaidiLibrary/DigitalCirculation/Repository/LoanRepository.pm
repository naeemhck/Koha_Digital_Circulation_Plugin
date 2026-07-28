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

sub get_for_return {
    my ( $self, $dbh, $loan_id, %options ) = @_;
    die 'INVALID_DBH' unless $dbh;
    die 'INVALID_LOAN_ID'
        unless defined $loan_id
        && !ref($loan_id)
        && $loan_id =~ /\A[1-9][0-9]*\z/;

    my $loans_table    = $self->{table_name};
    my $requests_table = $self->{request_table_name};
    my $lock           = $options{for_update} ? ' FOR UPDATE' : '';
    my $row            = $dbh->selectrow_hashref(
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
                l.approved_by,
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
             WHERE l.loan_id = ?
             $lock
        },
        undef,
        0 + $loan_id
    );
    return unless $row;
    return {
        map { $_ => $row->{$_} }
          (
            @LOAN_FIELDS,
            qw(
              portal_request_id
              joined_request_id
              request_patron_id
              request_biblio_id
            )
          )
    };
}

sub get_for_lifecycle {
    my ( $self, @args ) = @_;
    return $self->get_for_return(@args);
}

sub database_utc {
    my ( $self, $dbh ) = @_;
    return $dbh->selectrow_array(
        q{SELECT DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%d %H:%i:%s')}
    );
}

sub update_active_renewal {
    my ( $self, $dbh, %args ) = @_;
    my $days = $args{renewal_days};
    die 'INVALID_RENEWAL_DAYS'
        unless defined($days) && !ref($days) && $days =~ /\A[1-9][0-9]*\z/ && $days <= 365;
    my $table = $self->{table_name};
    my $affected = $dbh->do(
        qq{
            UPDATE `$table`
               SET due_at = DATE_ADD(due_at, INTERVAL $days DAY),
                   renewal_count = renewal_count + 1,
                   row_version = row_version + 1,
                   updated_at = UTC_TIMESTAMP()
             WHERE loan_id = ?
               AND status = 'ACTIVE'
               AND row_version = ?
               AND due_at > UTC_TIMESTAMP()
               AND renewal_count < ?
               AND returned_at IS NULL
               AND revoked_at IS NULL
               AND expired_at IS NULL
        },
        undef,
        0 + $args{loan_id},
        0 + $args{expected_row_version},
        0 + $args{maximum_renewals},
    );
    return defined($affected) && !ref($affected) && $affected == 1 ? 1 : 0;
}

sub update_active_revocation {
    my ( $self, $dbh, %args ) = @_;
    my $table = $self->{table_name};
    my $affected = $dbh->do(
        qq{
            UPDATE `$table`
               SET status = 'REVOKED',
                   revoked_at = UTC_TIMESTAMP(),
                   row_version = row_version + 1,
                   updated_at = UTC_TIMESTAMP()
             WHERE loan_id = ?
               AND status = 'ACTIVE'
               AND row_version = ?
               AND returned_at IS NULL
               AND revoked_at IS NULL
               AND expired_at IS NULL
        },
        undef,
        0 + $args{loan_id},
        0 + $args{expected_row_version},
    );
    return defined($affected) && !ref($affected) && $affected == 1 ? 1 : 0;
}

sub list_due_for_expiry {
    my ( $self, $dbh, %args ) = @_;
    my $limit = $args{limit};
    die 'INVALID_EXPIRY_LIMIT'
        unless defined($limit) && !ref($limit) && $limit =~ /\A[1-9][0-9]*\z/ && $limit <= 500;
    my $table = $self->{table_name};
    return $dbh->selectall_arrayref(
        qq{
            SELECT loan_id
              FROM `$table`
             WHERE status = 'ACTIVE'
               AND due_at <= UTC_TIMESTAMP()
               AND returned_at IS NULL
               AND revoked_at IS NULL
               AND expired_at IS NULL
             ORDER BY due_at ASC, loan_id ASC
             LIMIT $limit
             FOR UPDATE
        },
        { Slice => {} },
    );
}

sub update_active_expiry {
    my ( $self, $dbh, %args ) = @_;
    my $table = $self->{table_name};
    my $affected = $dbh->do(
        qq{
            UPDATE `$table`
               SET status = 'EXPIRED',
                   expired_at = UTC_TIMESTAMP(),
                   row_version = row_version + 1,
                   updated_at = UTC_TIMESTAMP()
             WHERE loan_id = ?
               AND status = 'ACTIVE'
               AND row_version = ?
               AND due_at <= UTC_TIMESTAMP()
               AND returned_at IS NULL
               AND revoked_at IS NULL
               AND expired_at IS NULL
        },
        undef,
        0 + $args{loan_id},
        0 + $args{expected_row_version},
    );
    return defined($affected) && !ref($affected) && $affected == 1 ? 1 : 0;
}

sub update_active_return {
    my ( $self, $dbh, %args ) = @_;
    my $table = $self->{table_name};
    my $loan_id              = $args{loan_id};
    my $expected_row_version = $args{expected_row_version};
    my $returned_at          = $args{returned_at};
    die 'INVALID_RETURN_UPDATE'
        unless defined $loan_id
        && !ref($loan_id)
        && $loan_id =~ /\A[1-9][0-9]*\z/
        && defined $expected_row_version
        && !ref($expected_row_version)
        && $expected_row_version =~ /\A[1-9][0-9]*\z/
        && defined $returned_at
        && !ref($returned_at)
        && $returned_at =~ /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/;

    my $affected = $dbh->do(
        qq{
            UPDATE `$table`
               SET status = 'RETURNED',
                   returned_at = ?,
                   row_version = row_version + 1,
                   updated_at = ?
             WHERE loan_id = ?
               AND status = 'ACTIVE'
               AND row_version = ?
               AND returned_at IS NULL
               AND revoked_at IS NULL
               AND expired_at IS NULL
        },
        undef,
        $returned_at,
        $returned_at,
        0 + $loan_id,
        0 + $expected_row_version
    );
    return 0 unless defined $affected && !ref($affected) && $affected == 1;
    return 1;
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
