use Modern::Perl;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/..";

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportProvisioning;

{ package Local::ReportRepo;
  sub new { bless { av => {}, rows => [], committed => 0, rolled_back => 0 }, shift }
  sub authorised_value { my ($s,$c,$v)=@_; $s->{av}{"$c/$v"} }
  sub create_authorised_value { my ($s,%a)=@_; $s->{av}{"$a{category}/$a{code}"}={lib=>$a{label},lib_opac=>$a{parent_code}}; 1 }
  sub managed_reports { $_[0]{rows} }
  sub begin_work { 1 }
  sub commit { $_[0]{committed}++; 1 }
  sub rollback { $_[0]{rolled_back}++; 1 }
  sub create_report {
      my ($s,%a)=@_;
      push @{$s->{rows}}, { id=>1+@{$s->{rows}}, report_name=>$a{name}, savedsql=>$a{sql},
        notes=>$a{notes}, cache_expiry=>$a{cache_expiry}, public=>0, report_area=>$a{report_area},
        report_group=>$a{group_code}, report_subgroup=>$a{subgroup_code} };
      1;
  }
  sub update_report {
      my ($s,%a)=@_; my ($r)=grep { $_->{id}==$a{id} } @{$s->{rows}};
      @{$r}{qw(savedsql report_name notes cache_expiry report_area report_group report_subgroup)}
        = @a{qw(sql name notes cache_expiry report_area group_code subgroup_code)};
      $r->{public}=0; 1;
  }
}

my $repo = Local::ReportRepo->new;
my $defs = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions->new;
my $service = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportProvisioning->new(
    repository=>$repo, definitions=>$defs
);
my $first = $service->provision(borrowernumber=>51);
ok $first->{ok}, 'initial provision succeeds';
is $first->{changed}, 12, 'group, subgroup, and ten reports created';
my $second = $service->provision(borrowernumber=>51);
ok $second->{ok}, 'repeat provision succeeds';
is $second->{changed}, 0, 'repeat provision is idempotent';

$repo->{rows}[0]{report_name} = 'Local customization';
my $preserve = $service->provision(borrowernumber=>51);
is $preserve->{changed}, 0, 'normal provision preserves drift';
is $preserve->{drift_preserved}, 1, 'drift is reported';
my $repair = $service->provision(repair=>1, borrowernumber=>51);
is $repair->{changed}, 1, 'explicit repair restores drift';

push @{$repo->{rows}}, {%{$repo->{rows}[0]}, id=>99};
my $blocked = $service->provision(repair=>1, borrowernumber=>51);
is $blocked->{code}, 'MANAGED_REPORT_CONFLICT', 'duplicate ownership blocks repair';
done_testing;
