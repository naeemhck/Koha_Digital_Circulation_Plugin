package Local::PluginUpgradeDBH;

use Modern::Perl;
use Storable qw(dclone);

sub new {
    my ( $class, %args ) = @_;
    my @table_names =
        map { "plugin_jzl_ebook_$_" }
        qw(requests loans renewals events schema_versions);
    return bless {
        tables => $args{existing_tables}
            ? { map { $_ => 1 } @table_names }
            : {},
        schema_rows  => dclone( $args{schema_rows} // [] ),
        requests     => dclone( $args{requests} // [] ),
        loans        => dclone( $args{loans} // [] ),
        renewals     => dclone( $args{renewals} // [] ),
        events       => dclone( $args{events} // [] ),
        native_issues => dclone( $args{native_issues} // [] ),
        stamp_error  => $args{stamp_error},
        calls        => [],
    }, $class;
}

sub begin_work {
    my ($self) = @_;
    push @{ $self->{calls} }, 'begin';
    $self->{snapshot} = dclone(
        {
            schema_rows   => $self->{schema_rows},
            requests      => $self->{requests},
            loans         => $self->{loans},
            renewals      => $self->{renewals},
            events        => $self->{events},
            native_issues => $self->{native_issues},
        }
    );
    return 1;
}

sub commit {
    my ($self) = @_;
    push @{ $self->{calls} }, 'commit';
    delete $self->{snapshot};
    return 1;
}

sub rollback {
    my ($self) = @_;
    push @{ $self->{calls} }, 'rollback';
    if ( my $snapshot = delete $self->{snapshot} ) {
        $self->{$_} = $snapshot->{$_}
            for qw(schema_rows requests loans renewals events native_issues);
    }
    return 1;
}

sub do {
    my ( $self, $sql, $attr, @bind ) = @_;
    push @{ $self->{calls} }, $sql;

    if ( $sql =~ /CREATE TABLE IF NOT EXISTS `([^`]+)`/ ) {
        $self->{tables}{$1} = 1;
        return 1;
    }

    if ( $sql =~ /ON DUPLICATE KEY UPDATE/ ) {
        die $self->{stamp_error} if $self->{stamp_error};
        my ( $schema_version, $plugin_version, $migration_name, $checksum ) =
            @bind;
        my ($row) = grep {
            $_->{schema_version} == $schema_version
                || $_->{migration_name} eq $migration_name
        } @{ $self->{schema_rows} };
        if ($row) {
            $row->{plugin_version} = $plugin_version;
            $row->{migration_name} = $migration_name;
            $row->{checksum}       = $checksum;
        }
        else {
            push @{ $self->{schema_rows} },
                {
                schema_version => $schema_version,
                plugin_version => $plugin_version,
                migration_name => $migration_name,
                checksum       => $checksum,
                };
        }
        return 1;
    }

    die "Unexpected SQL: $sql";
}

sub selectrow_array {
    my ( $self, $sql, $attr, @bind ) = @_;
    push @{ $self->{calls} }, $sql;

    return 1 if $sql =~ /GET_LOCK/;
    if ( $sql =~ /RELEASE_LOCK/ ) {
        $self->{released}++;
        return 1;
    }
    if ( $sql =~ /information_schema\.tables/ ) {
        return $self->{tables}{ $bind[0] } ? 1 : 0;
    }
    if ( $sql =~ /schema_versions`\s*$/ ) {
        return scalar @{ $self->{schema_rows} };
    }
    if ( $sql =~ /schema_versions` WHERE schema_version = \? AND plugin_version = \?/ ) {
        return scalar grep {
            $_->{schema_version} == $bind[0]
                && $_->{plugin_version} eq $bind[1]
        } @{ $self->{schema_rows} };
    }

    die "Unexpected SQL: $sql";
}

1;
