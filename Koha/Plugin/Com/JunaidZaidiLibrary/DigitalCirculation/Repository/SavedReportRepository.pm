package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::SavedReportRepository;

use Modern::Perl;

sub new {
    my ( $class, %args ) = @_;
    return bless { dbh => $args{dbh} }, $class;
}

sub dbh { return shift->{dbh} }

sub begin_work { return shift->dbh->begin_work }
sub commit     { return shift->dbh->commit }
sub rollback   { return shift->dbh->rollback }

sub authorised_value {
    my ( $self, $category, $code ) = @_;
    return $self->dbh->selectrow_hashref(
        'SELECT id, category, authorised_value, lib, lib_opac FROM authorised_values WHERE category = ? AND authorised_value = ?',
        undef, $category, $code
    );
}

sub create_authorised_value {
    my ( $self, %args ) = @_;
    return $self->dbh->do(
        'INSERT INTO authorised_values (category, authorised_value, lib, lib_opac) VALUES (?, ?, ?, ?)',
        undef, @args{qw(category code label parent_code)}
    );
}

sub managed_reports {
    my ( $self, $prefix ) = @_;
    my $sth = $self->dbh->prepare(
        q{SELECT id, borrowernumber, date_created, last_modified, savedsql, report_name, type, notes,
                 cache_expiry, public, report_area, report_group, report_subgroup
          FROM saved_sql
          WHERE notes LIKE ?
          ORDER BY id}
    );
    $sth->execute( $prefix . '%' );
    return $sth->fetchall_arrayref( {} );
}

sub create_report {
    my ( $self, %args ) = @_;
    return $self->dbh->do(
        q{INSERT INTO saved_sql
          (borrowernumber, date_created, last_modified, savedsql, report_name, type, notes,
           cache_expiry, public, report_area, report_group, report_subgroup)
          VALUES (?, UTC_TIMESTAMP(), UTC_TIMESTAMP(), ?, ?, '1', ?, ?, 0, ?, ?, ?)},
        undef,
        @args{qw(borrowernumber sql name notes cache_expiry report_area group_code subgroup_code)}
    );
}

sub update_report {
    my ( $self, %args ) = @_;
    return $self->dbh->do(
        q{UPDATE saved_sql
          SET savedsql = ?, report_name = ?, notes = ?, cache_expiry = ?, public = 0,
              report_area = ?, report_group = ?, report_subgroup = ?, last_modified = UTC_TIMESTAMP()
          WHERE id = ?},
        undef,
        @args{qw(sql name notes cache_expiry report_area group_code subgroup_code id)}
    );
}

1;
