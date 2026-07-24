use Modern::Perl;
use Test::More;
use JSON::PP;

my $bundle =
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation';

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

my $base       = slurp("$bundle/Repository/Base.pm");
my $loan_repo  = slurp("$bundle/Repository/LoanRepository.pm");
my $requests   = slurp("$bundle/Controller/Requests.pm");
my $openapi    = JSON::PP->new->decode( slurp("$bundle/openapi.json") );
my $js         = slurp("$bundle/static/js/jzl-digital-circulation.js");

like $base,
    qr/LEFT JOIN plugin_jzl_ebook_loans l ON l\.request_id=r\.request_id/,
    'request read model left-joins loans by request_id';
like $base,
    qr/l\.loan_id AS loan_id,l\.status AS loan_status,l\.started_at AS loan_started_at,l\.due_at AS loan_due_at,l\.row_version AS loan_row_version/,
    'request read model selects only the safe loan summary aliases';
unlike $base,
    qr/plugin_jzl_ebook_loans l[\s\S]{0,200}(?:content_path|approved_by|renewal_count|returned_at|revoked_at|expired_at|created_at|updated_at)/,
    'request loan summary omits full loan-row internals';

my ($requests_spec) = $base =~ /requests=>\{(.*?)\}(?:,\n|\z)/s;
ok defined $requests_spec, 'requests repository spec is extractable';
like $requests_spec, qr/filters=>\{status=>'r\.status'/,
    'request status filters remain unchanged';
like $requests_spec, qr/patron_id=>'r\.patron_id'/,
    'request patron filters remain unchanged';
like $requests_spec, qr/biblio_id=>'r\.biblio_id'/,
    'request biblio filters remain unchanged';
like $base, qr/LIMIT \? OFFSET \?/,
    'request listing pagination remains unchanged';

unlike $requests, qr/find_by_request_id/,
    'request controller list/get does not N+1 through LoanRepository';
unlike $base, qr/for my.*find_by_request_id|foreach.*loan/,
    'repository list path has no per-row loan lookup loop';
like $loan_repo, qr/sub find_by_request_id/,
    'LoanRepository single-request lookup remains available for writes';

like $js, qr/PUBLIC_LOAN_SUMMARY_FIELDS/,
    'staff UI allowlists loan summary fields';
like $js, qr/'loan_id'/,
    'staff UI recognizes loan_id';
like $js, qr/'loan_status'/,
    'staff UI recognizes loan_status';
like $js, qr/'loan_started_at'/,
    'staff UI recognizes loan_started_at';
like $js, qr/'loan_due_at'/,
    'staff UI recognizes loan_due_at';
like $js, qr/'loan_row_version'/,
    'staff UI recognizes loan_row_version';
like $js, qr/loanPresence\(request\) === 'absent'/,
    'APPROVED without loan is treated as issuable only when summary is absent';
like $js, qr/loanPresence\(request\) === 'present'/,
    'ACTIVE loan summary suppresses Issue Loan';
like $js, qr/loanPresence\(request\) === 'ambiguous'/,
    'malformed loan summary fails closed';

my @posts =
    sort map { exists $openapi->{$_}{post} ? $_ : () } keys %{$openapi};
is_deeply \@posts,
    [
        '/requests',
        '/requests/{request_id}/decision',
        '/requests/{request_id}/issue',
    ],
    'loan summary reuses existing GET routes and does not add a POST route';
ok exists $openapi->{'/requests'}{get},
    'staff request listing GET route remains';
ok exists $openapi->{'/requests/{request_id}'}{get},
    'staff request detail GET route remains';
unlike slurp("$bundle/openapi.json"),
    qr{"/(?:access|reader|loans/issue)"},
    'no reader or access route was added for loan visibility';

like $requests, qr/sub decide\b/,
    'request decision responses remain on the decide action';
like $requests, qr/\@PUBLIC_STAFF_DECISION_FIELDS/,
    'decision response allowlist remains separate from loan summary';
unlike $requests, qr/sub decide \{[\s\S]*?loan_status/,
    'decision write responses are not required to embed loan summary fields';

done_testing;
