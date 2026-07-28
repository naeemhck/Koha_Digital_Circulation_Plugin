use Modern::Perl;
use Test::More;
use lib '.';
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StateMachine qw(can_transition);

for (qw(APPROVED REJECTED CANCELLED)) {
    ok can_transition('request', 'PENDING', $_), "request PENDING -> $_";
}
for (qw(REJECTED APPROVED)) {
    ok !can_transition('request', 'APPROVED', $_), "forbidden approved -> $_";
}
for (qw(ACTIVE RETURNED EXPIRED REVOKED)) {
    ok can_transition('loan', 'ACTIVE', $_), "loan ACTIVE -> $_";
}
for my $terminal (qw(RETURNED EXPIRED REVOKED)) {
    for my $target (qw(ACTIVE RETURNED EXPIRED REVOKED)) {
        ok !can_transition('loan', $terminal, $target), "terminal $terminal cannot become $target";
    }
}
for (qw(APPROVED REJECTED CANCELLED)) {
    ok can_transition('renewal', 'PENDING', $_), "renewal PENDING -> $_";
}
done_testing;
