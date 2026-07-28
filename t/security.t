use Modern::Perl;
use Test::More;
use File::Find;
use JSON qw(decode_json);

my @files;
find( sub { push @files, $File::Find::name if -f }, 'Koha' );
my $source = join "\n", map {
    my $file = $_;
    local $/;
    open my $handle, '<', $file or die $!;
    <$handle>;
} @files;
unlike $source, qr/BEGIN (?:RSA |OPENSSH )?PRIVATE KEY/i, 'no packaged private key';
unlike(
    $source,
    qr/\b(?:client_secret|access_token|password)\b\s*(?:=>|=)\s*['"](?!\[?REDACTED\]?|placeholder|example)[^'"]+['"]/i,
    'no packaged literal credential'
);
unlike(
    $source,
    qr/Authorization:\s+Bearer\s+(?!\[REDACTED\])[\w.+\/=-]{12,}/i,
    'no packaged bearer token'
);
like $source, qr/client_secret.*?\[REDACTED\]/s, 'client secret errors are redacted';
like $source, qr/Authorization: Bearer \[REDACTED\]/, 'bearer token errors are redacted';
like $source, qr/payload_json/, 'event payload defined';

open my $api_fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json' or die $!;
my $api = decode_json( do { local $/; <$api_fh> } );
my @write_routes;
for my $path ( sort keys %{$api} ) {
    for my $method ( sort keys %{ $api->{$path} } ) {
        push @write_routes, "$method $path" if $method =~ /\A(?:post|put|patch|delete)\z/i;
    }
}
is_deeply(
    \@write_routes,
    [
        'post /loans/{loan_id}/renew',
        'post /loans/{loan_id}/return',
        'post /loans/{loan_id}/revoke',
        'post /maintenance/expire-loans',
        'post /requests',
        'post /requests/{request_id}/decision',
        'post /requests/{request_id}/issue',
    ],
    'only the seven authoritative digital-circulation operations are mutation routes'
);
done_testing;
