use Modern::Perl;
use Test::More;
use lib '.';

BEGIN {
    package C4::Context;
    sub dbh { die 'unexpected C4::Context->dbh in repository unit test' }
    $INC{'C4/Context.pm'} = __FILE__;
}

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository;

{
    package Local::FakeDbh;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            count   => $args{count} // 0,
            rows    => $args{rows} // [],
            calls   => [],
            error   => $args{error},
        }, $class;
    }
    sub selectrow_array {
        my ( $self, $sql, undef, @bind ) = @_;
        push @{ $self->{calls} }, { op => 'count', sql => $sql, bind => [@bind] };
        die $self->{error} if defined $self->{error} && $self->{error} eq 'count';
        return $self->{count};
    }
    sub selectall_arrayref {
        my ( $self, $sql, $attrs, @bind ) = @_;
        push @{ $self->{calls} },
            { op => 'list', sql => $sql, attrs => $attrs, bind => [@bind] };
        die $self->{error} if defined $self->{error} && $self->{error} eq 'list';
        return [ map { {%$_} } @{ $self->{rows} } ];
    }
}

my $repo =
    Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository
    ->new;
my $portal_request_id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

sub row {
    my (%overrides) = @_;
    return {
        loan_id           => 1,
        request_id        => 7,
        portal_request_id => $portal_request_id,
        patron_id         => 50,
        biblio_id         => 1,
        status            => 'ACTIVE',
        started_at        => '2026-07-24 17:27:14',
        due_at            => '2026-08-07 17:27:14',
        returned_at       => undef,
        revoked_at        => undef,
        expired_at        => undef,
        renewal_count     => 0,
        row_version       => 1,
        created_at        => '2026-07-24 17:27:14',
        updated_at        => '2026-07-24 17:27:14',
        joined_request_id => 7,
        request_patron_id => 50,
        request_biblio_id => 1,
        %overrides,
    };
}

my $dbh = Local::FakeDbh->new(
    count => 1,
    rows  => [ row() ],
);
my $result = $repo->list_for_patron(
    $dbh,
    patron_id => 50,
    page      => 1,
    per_page  => 20,
);
is $result->{total}, 1, 'count total is returned';
is scalar @{ $result->{loans} }, 1, 'one page row returned';
is $result->{loans}[0]{portal_request_id}, $portal_request_id,
    'request join supplies portal_request_id';
is scalar @{ $dbh->{calls} }, 2, 'exactly one count and one list query';
like $dbh->{calls}[0]{sql}, qr/SELECT COUNT\(\*\)/i, 'count query used';
like $dbh->{calls}[1]{sql}, qr/INNER JOIN/i,         'list joins requests';
like $dbh->{calls}[1]{sql}, qr/plugin_jzl_ebook_requests/,
    'joins request table';
like $dbh->{calls}[1]{sql}, qr/ORDER BY l\.created_at DESC, l\.loan_id DESC/i,
    'deterministic ordering';
unlike $dbh->{calls}[1]{sql}, qr/borrowers/i, 'no borrower join';
unlike $dbh->{calls}[1]{sql}, qr/FOR UPDATE/i, 'no locking clause';
unlike $dbh->{calls}[0]{sql} . $dbh->{calls}[1]{sql},
    qr/\b(INSERT|UPDATE|DELETE)\b/i, 'no write statements';
is_deeply $dbh->{calls}[0]{bind}, [50], 'count binds patron only';
is_deeply $dbh->{calls}[1]{bind}, [ 50, 20, 0 ],
    'list binds patron, limit, offset';

$dbh = Local::FakeDbh->new( count => 0, rows => [] );
$result = $repo->list_for_patron( $dbh, patron_id => 50 );
is_deeply $result->{loans}, [], 'empty result';
is $result->{total}, 0, 'empty total';

$dbh = Local::FakeDbh->new(
    count => 3,
    rows  => [ row( loan_id => 3 ), row( loan_id => 2 ), row( loan_id => 1 ) ],
);
$result = $repo->list_for_patron(
    $dbh,
    patron_id => 50,
    page      => 2,
    per_page  => 1,
);
is_deeply $dbh->{calls}[1]{bind}, [ 50, 1, 1 ],
    'page 2 per_page 1 uses offset 1';
is $result->{page}, 2, 'page echoed';
is $result->{per_page}, 1, 'per_page echoed';

for my $bad (
    { patron_id => 0 },
    { patron_id => '01' },
    { page      => 0 },
    { per_page  => 101 },
    { per_page  => 0 },
  )
{
    my $ok = eval {
        $repo->list_for_patron( Local::FakeDbh->new, patron_id => 50, %{$bad} );
        1;
    };
    ok !$ok, 'rejects bad pagination/patron input';
}

done_testing;
