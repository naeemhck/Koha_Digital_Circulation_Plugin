use Modern::Perl;
use Test::More;
use lib '.';
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;

{
    package Local::MigrationDBH;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            tables => { map { $_ => 1 } qw(plugin_jzl_ebook_requests plugin_jzl_ebook_loans plugin_jzl_ebook_renewals) },
            skip   => $args{skip},
            calls  => [],
            schema_rows => [],
        }, $class;
    }
    sub do {
        my ( $self, $sql, $attr, @bind ) = @_;
        push @{ $self->{calls} }, $sql;
        if ( $sql =~ /CREATE TABLE IF NOT EXISTS `([^`]+)`/ ) {
            $self->{tables}{$1} = 1 unless ( $self->{skip} // '' ) eq $1;
        }
        if ( $sql =~ /ON DUPLICATE KEY UPDATE/ ) {
            $self->{schema_rows} = [
                {
                    schema_version => $bind[0],
                    plugin_version => $bind[1],
                }
            ];
        }
        return 1;
    }
    sub begin_work {
        my ($self) = @_;
        $self->{snapshot} = [ map { +{%$_} } @{ $self->{schema_rows} } ];
        return 1;
    }
    sub commit { delete $_[0]{snapshot}; return 1 }
    sub rollback {
        my ($self) = @_;
        $self->{schema_rows} = delete $self->{snapshot}
            if $self->{snapshot};
        return 1;
    }
    sub selectrow_array {
        my ( $self, $sql, $attr, @bind ) = @_;
        push @{ $self->{calls} }, $sql;
        return 1 if $sql =~ /GET_LOCK/;
        if ( $sql =~ /RELEASE_LOCK/ ) { $self->{released}++; return 1 }
        return $self->{tables}{ $bind[0] } ? 1 : 0 if $sql =~ /information_schema\.tables/;
        return scalar @{ $self->{schema_rows} }
            if $sql =~ /schema_versions`\s*$/;
        return scalar grep {
            $_->{schema_version} == $bind[0]
                && $_->{plugin_version} eq $bind[1]
        } @{ $self->{schema_rows} }
            if $sql =~ /schema_version = \? AND plugin_version = \?/;
        die "Unexpected SQL: $sql";
    }
}

my $plugin = bless {}, 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation';
my $retry_dbh = Local::MigrationDBH->new;
{
    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $retry_dbh };
    local *Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::_saved_report_provisioning = sub {
        return bless {}, 'Local::MigrationReportProvisioning';
    };
    ok $plugin->install, 'retry succeeds with first three tables already present';
}
ok $retry_dbh->{tables}{plugin_jzl_ebook_events}, 'retry creates events table';
ok $retry_dbh->{tables}{plugin_jzl_ebook_schema_versions}, 'retry creates schema-version table';
is_deeply $retry_dbh->{schema_rows},
    [ { schema_version => 1, plugin_version => '0.4.0' } ],
    'retry records canonical schema 1 and current plugin version';
ok $retry_dbh->{released}, 'retry releases migration lock';
ok !grep( /DROP TABLE/i, @{ $retry_dbh->{calls} } ), 'retry is non-destructive';

my $missing_dbh = Local::MigrationDBH->new( skip => 'plugin_jzl_ebook_events' );
my $warning = '';
{
    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $missing_dbh };
    local *Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::_saved_report_provisioning = sub {
        return bless {}, 'Local::MigrationReportProvisioning';
    };
    local $SIG{__WARN__} = sub { $warning .= join '', @_ };
    ok !$plugin->install, 'install cannot succeed with events table missing';
}
like $warning, qr/PLUGIN_SCHEMA_UNAVAILABLE: migration failed: Expected table plugin_jzl_ebook_events is missing/, 'safe error identifies missing table';
ok $missing_dbh->{released}, 'failure path releases migration lock';
{
    package Local::MigrationReportProvisioning;
    sub provision { return { ok => 1, changed => 0 } }
}
package main;
done_testing;
