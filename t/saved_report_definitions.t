use Modern::Perl;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/..";

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions;

my $catalog = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions->new;
my $reports = $catalog->reports;
is scalar(@$reports), 10, 'ten managed report definitions';
is scalar( keys %{ $catalog->by_slug } ), 10, 'slugs are unique';

for my $report (@$reports) {
    like $report->{notes}, qr/\ADigitalCirculation managed report:/, "$report->{slug} is ownership marked";
    is $report->{group_code}, 'DIGCIRC', "$report->{slug} uses managed group";
    is $report->{subgroup_code}, 'EBOOKS', "$report->{slug} uses managed subgroup";
    is $report->{public}, 0, "$report->{slug} is non-public";
    unlike $report->{sql}, qr/\bissues\b/i, "$report->{slug} does not use native issues";
    unlike $report->{sql}, qr/SELECT\s+\*/i, "$report->{slug} selects explicit columns";
    unlike $report->{sql}, qr/(?:borrowers\.(?:surname|firstname|email|phone)|payload_json\s+AS)/i,
        "$report->{slug} avoids direct patron identity and raw payload output";
    like $report->{sql}, qr/<<Item type\|itemtypes>>/, "$report->{slug} has native item-type parameter";
    like $report->{sql}, qr/EXISTS\s*\(\s*SELECT 1 FROM catalogue_item_types/i,
        "$report->{slug} filters without multiplying lifecycle rows";
}

like $catalog->by_slug->{department_usage}{sql}, qr/pat\.categorycode/, 'department source is borrower category';
like $catalog->by_slug->{audit_trail}{sql}, qr/JSON_EXTRACT/, 'audit details use an allowlisted projection';
for my $report (@$reports) {
    like $report->{sql}, qr/SELECT DISTINCT item_map\.biblionumber, item_map\.item_type/,
        "$report->{slug} de-duplicates multiple item records";
    like $report->{sql}, qr/FROM items item.*item-level_itypes.*FROM biblioitems bi/s,
        "$report->{slug} supports item-level and record-level Koha modes";
}
done_testing;
