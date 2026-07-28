#!/usr/bin/perl
use Modern::Perl;
use FindBin qw($Bin);
use lib "$Bin/..";
use C4::Context;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions;

my $dbh = C4::Context->dbh;
my $catalog = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions->new;
for my $definition ( @{ $catalog->reports } ) {
    my $sql = $definition->{sql};
    $sql =~ s/<<Start date\|date>>/'2000-01-01'/g;
    $sql =~ s/<<End date\|date>>/'2099-12-31'/g;
    $sql =~ s/<<[^>]+>>/''/g;
    my $rows = $dbh->selectall_arrayref( "EXPLAIN $sql" );
    die "$definition->{slug}: EXPLAIN returned no plan\n" unless @$rows;
    say "ok - $definition->{slug} (" . scalar(@$rows) . ' plan rows)';
}
