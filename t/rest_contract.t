use Modern::Perl;
use Test::More;
use JSON qw(decode_json);

local $/;
open my $fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json' or die $!;
my $api = decode_json(<$fh>);

for my $path (
    qw(
      /health /version /requests /requests/{request_id}
      /loans /loans/{loan_id} /renewals /renewals/{renewal_id}
      /events /events/{event_id}
    )
) {
    ok exists $api->{$path}{get}, "GET $path";
    my @expected_methods = ('get');
    push @expected_methods, 'post' if $path eq '/requests' && exists $api->{$path}{post};
    is_deeply [ sort keys %{ $api->{$path} } ], [ sort @expected_methods ], "allowed methods $path";
    ok $api->{$path}{get}{'x-koha-authorization'}, "authorization $path";
}
ok exists $api->{'/requests/{request_id}/decision'}{post},
    'POST /requests/{request_id}/decision';
is_deeply(
    [ sort keys %{ $api->{'/requests/{request_id}/decision'} } ],
    ['post'],
    'decision route exposes only POST'
);
ok $api->{'/requests/{request_id}/decision'}{post}{'x-koha-authorization'},
    'decision route declares authorization';
done_testing;
