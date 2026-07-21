package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::Validation;
use Modern::Perl;
use Exporter 'import'; use Koha::Patrons; use Koha::Biblios;
our @EXPORT_OK=qw(assert_patron assert_biblio assert_portal_ids assert_source pagination);
sub assert_patron { die 'INVALID_PATRON' unless defined $_[0] && $_[0]=~/\A[1-9]\d*\z/ && Koha::Patrons->find($_[0]); 1 }
sub assert_biblio { die 'INVALID_BIBLIO' unless defined $_[0] && $_[0]=~/\A[1-9]\d*\z/ && Koha::Biblios->find($_[0]); 1 }
sub assert_portal_ids { for(@_){die 'INVALID_PORTAL_IDENTIFIER' unless defined && /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/} 1 }
sub assert_source { die 'INVALID_SOURCE' unless ($_[0]//'') eq 'PORTAL'; 1 }
sub pagination { my($p,$pp)=@_; $p//=1;$pp//=20; die 'INVALID_PAGINATION' unless $p=~/\A\d+\z/&&$p>=1&&$pp=~/\A\d+\z/&&$pp>=1&&$pp<=100; return(0+$p,0+$pp) }
1;
