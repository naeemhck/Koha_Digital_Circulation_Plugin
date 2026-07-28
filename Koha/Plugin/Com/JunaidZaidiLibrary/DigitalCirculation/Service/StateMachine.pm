package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StateMachine;
use Modern::Perl;
use Exporter 'import';
our @EXPORT_OK=qw(can_transition assert_transition);
my %RULES=(request=>{PENDING=>{map{$_=>1}qw(APPROVED REJECTED CANCELLED)}},loan=>{ACTIVE=>{map{$_=>1}qw(ACTIVE RETURNED EXPIRED REVOKED)}},renewal=>{PENDING=>{map{$_=>1}qw(APPROVED REJECTED CANCELLED)}});
sub can_transition { my($type,$from,$to)=@_; return !!($RULES{$type} && $RULES{$type}{$from} && $RULES{$type}{$from}{$to}) }
sub assert_transition { die 'INVALID_STATE_TRANSITION' unless can_transition(@_); 1 }
1;
