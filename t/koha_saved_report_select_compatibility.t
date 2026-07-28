use Modern::Perl;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/..";

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions;

# Faithful to Koha::Report::is_sql_valid on the deployed Koha 26.05 host.
sub koha_select_compatible {
    my ($sql) = @_;
    return 0 if !defined $sql;
    return 0 if $sql =~ /;?\W?(?:UPDATE|DELETE|DROP|INSERT|SHOW|CREATE)\W/i;
    return 0 unless $sql =~ /^\s*SELECT\b\s*/i;
    return 0 if $sql =~ /;\s*\S/;
    return 1;
}

ok koha_select_compatible('SELECT 1'), 'SELECT passes';
ok koha_select_compatible(" \nselect 1"), 'leading whitespace and lowercase select pass';
ok !koha_select_compatible('WITH x AS (SELECT 1) SELECT * FROM x'), 'leading WITH fails';
ok !koha_select_compatible('-- comment\nSELECT 1'), 'leading comment fails';
ok !koha_select_compatible('(SELECT 1)'), 'leading parenthesis fails';
ok !koha_select_compatible("\x{FEFF}SELECT 1"), 'BOM fails';
ok !koha_select_compatible('SELECT 1; SELECT 2'), 'multiple statements fail';
ok !koha_select_compatible('UPDATE borrowers SET branchcode = 1'), 'write verb fails';

my $reports = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions->new->reports;
is scalar(@$reports), 10, 'all ten managed reports are covered';
for my $report (@$reports) {
    ok koha_select_compatible($report->{sql}), "$report->{slug} passes Koha SELECT validation";
    like $report->{sql}, qr/\ASELECT\b/, "$report->{slug} first token is SELECT";
    unlike $report->{sql}, qr/\A\s*WITH\b/i, "$report->{slug} has no leading CTE";
    like $report->{sql}, qr/<<Item type\|itemtypes>>/, "$report->{slug} preserves native Item Type parameter";
}

done_testing;
