use Modern::Perl;
use Test::More;
use lib '.';

BEGIN {
    package C4::Context;
    sub dbh { die 'unexpected C4::Context->dbh in portal loan-read application test' }
    $INC{'C4/Context.pm'} = __FILE__;
}

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReadApplication;

{
    package Local::LoanReadAuthorization;
    sub new { bless { response => $_[1], error => $_[2], log => $_[3] }, $_[0] }
    sub authorize_controller {
        my ( $self, $controller ) = @_;
        push @{ $self->{log} }, [ authorization => $controller ];
        die $self->{error} if defined $self->{error};
        return $self->{response};
    }

    package Local::LoanReadRepository;
    sub new { bless { response => $_[1], error => $_[2], log => $_[3] }, $_[0] }
    sub list_for_patron {
        my ( $self, $dbh, %args ) = @_;
        push @{ $self->{log} }, [ repository => { dbh => $dbh, %args } ];
        die $self->{error} if defined $self->{error};
        return $self->{response};
    }

    package Local::LoanReadController;
    sub new { bless {}, $_[0] }
}

my $class =
'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReadApplication';
my $controller = Local::LoanReadController->new;
my $portal_request_id = '3c90bf2e-d3d8-4db2-9f5d-d36f792340cd';

sub loan_row {
    my (%overrides) = @_;
    return {
        loan_id           => 1,
        request_id        => 7,
        joined_request_id => 7,
        portal_request_id => $portal_request_id,
        patron_id         => 50,
        request_patron_id => 50,
        biblio_id         => 1,
        request_biblio_id => 1,
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
        %overrides,
    };
}

sub repo_result {
    my (@loans) = @_;
    return {
        loans    => [@loans],
        total    => scalar @loans,
        page     => 1,
        per_page => 20,
    };
}

sub application {
    my (%args) = @_;
    my $log = $args{log} || [];
    my $authorization =
        $args{authorization}
        || Local::LoanReadAuthorization->new(
            { allowed => 1, actor_id => 53 },
            undef, $log
        );
    my $repository =
        $args{repository}
        || Local::LoanReadRepository->new(
            $args{repo_result} // repo_result( loan_row() ),
            $args{repo_error},
            $log
        );
    my $diagnostics = [];
    return (
        $class->new(
            authorization   => $authorization,
            loan_repository => $repository,
            dbh             => $args{dbh} // 'DBH',
            diagnostic      => sub {
                my ($category) = @_;
                push @{$diagnostics}, $category;
                die 'diagnostic boom' if $args{diagnostic_dies};
            },
        ),
        $log,
        $diagnostics,
    );
}

sub list {
    my ( $app, %overrides ) = @_;
    return $app->list_patron_loans(
        controller => $controller,
        patron_id  => 50,
        page       => 1,
        per_page   => 20,
        %overrides,
    );
}

my ( $app, $log, $diagnostics ) = application();
my $ok = list($app);
ok $ok->{ok}, 'actor 53 allowlisted read succeeds';
is scalar @{ $ok->{loans} }, 1, 'one loan returned';
is $ok->{loans}[0]{portal_request_id}, $portal_request_id,
    'portal_request_id is returned from the joined request';
ok !exists $ok->{loans}[0]{approved_by}, 'approved_by is not exposed';
ok !exists $ok->{loans}[0]{portal_ebook_uuid}, 'portal_ebook_uuid is not emitted';
is_deeply(
    [ sort keys %{ $ok->{loans}[0] } ],
    [
        sort qw(
            loan_id request_id portal_request_id patron_id biblio_id status
            started_at due_at returned_at revoked_at expired_at
            renewal_count row_version created_at updated_at
        )
    ],
    'public loan fields match the approved contract'
);
is_deeply $ok->{pagination},
    { page => 1, per_page => 20, total => 1, total_pages => 1 },
    'pagination defaults and totals are canonical';
is_deeply [ map { $_->[0] } @{$log} ], [qw(authorization repository)],
    'authorization runs before repository';
is $log->[0][1], $controller, 'trusted controller reaches authorization only';
is_deeply(
    {
        map { $_ => $log->[1][1]{$_} }
            qw(patron_id page per_page)
    },
    { patron_id => 50, page => 1, per_page => 20 },
    'repository receives only validated patron and pagination'
);
ok !exists $log->[1][1]{actor_id}, 'actor identity is not passed to the repository';
ok !exists $log->[1][1]{cookie},   'browser identity is not passed to the repository';

( $app, $log ) = application(
    authorization => Local::LoanReadAuthorization->new(
        { allowed => 0, code => 'AUTHENTICATION_REQUIRED' },
        undef, []
    )
);
my $unauth = list($app);
ok !$unauth->{ok}, 'missing authentication fails';
is $unauth->{code}, 'AUTHENTICATION_REQUIRED',
    'missing authentication uses AUTHENTICATION_REQUIRED';

my $auth_log = [];
( $app, $log ) = application(
    authorization => Local::LoanReadAuthorization->new(
        { allowed => 0, code => 'AUTHENTICATION_REQUIRED' },
        undef, $auth_log
    ),
    repository => Local::LoanReadRepository->new( repo_result(), undef, $auth_log ),
);
$unauth = list($app);
is $unauth->{code}, 'AUTHENTICATION_REQUIRED', 'authn failure code preserved';
is_deeply [ map { $_->[0] } @{$auth_log} ], ['authorization'],
    'repository is not called for AUTHENTICATION_REQUIRED';

my $staff_log = [];
( $app, $log ) = application(
    authorization => Local::LoanReadAuthorization->new(
        {
            allowed  => 0,
            code     => 'SERVICE_ACCOUNT_NOT_AUTHORIZED',
            actor_id => 51
        },
        undef,
        $staff_log
    ),
    repository => Local::LoanReadRepository->new( repo_result(), undef, $staff_log ),
);
my $staff = list($app);
is $staff->{code}, 'SERVICE_ACCOUNT_NOT_AUTHORIZED',
    'actor 51 staff permission does not authorize portal loan read';
is_deeply [ map { $_->[0] } @{$staff_log} ], ['authorization'],
    'repository is not called for actor 51 denial';

my $throw_log = [];
( $app, $log ) = application(
    authorization => Local::LoanReadAuthorization->new(
        undef, 'authorization exploded', $throw_log
    ),
    repository => Local::LoanReadRepository->new( repo_result(), undef, $throw_log ),
);
my $auth_throw = list($app);
is $auth_throw->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'authorization dependency throw is a safe unavailable failure';

for my $bad_patron ( 0, -1, 1.5, '01', '+50', '50a', ' 50', '50 ', '', undef, [], {} ) {
    my $plog = [];
    ( $app, $log ) = application(
        log        => $plog,
        repository => Local::LoanReadRepository->new( repo_result(), undef, $plog ),
    );
    my $result = list( $app, patron_id => $bad_patron );
    is $result->{code}, 'INVALID_INPUT', 'rejects malformed patron_id';
    is_deeply [ map { $_->[0] } @{$plog} ], ['authorization'],
        'malformed patron does not reach repository';
}

( $app, $log ) = application();
my $defaults = $app->list_patron_loans(
    controller => $controller,
    patron_id  => 50,
);
ok $defaults->{ok}, 'omitted pagination uses defaults';
is $defaults->{pagination}{page}, 1, 'default page is 1';
is $defaults->{pagination}{per_page}, 20, 'default per_page is 20';

for my $case (
    [ page     => 0 ],
    [ page     => '01' ],
    [ page     => 1.2 ],
    [ per_page => 0 ],
    [ per_page => 101 ],
    [ per_page => '20a' ],
  )
{
    my ( $field, $value ) = @{$case};
    my $rlog = [];
    ( $app, $log ) = application(
        log        => $rlog,
        repository => Local::LoanReadRepository->new( repo_result(), undef, $rlog ),
    );
    my $result = list( $app, $field => $value );
    is $result->{code}, 'INVALID_INPUT', "rejects malformed $field=$value";
    is_deeply [ map { $_->[0] } @{$rlog} ], ['authorization'],
        "malformed $field does not reach repository";
}

( $app, $log ) = application(
    repo_result => { loans => [], total => 0, page => 1, per_page => 20 }
);
my $empty = list( $app, patron_id => 999 );
ok $empty->{ok}, 'empty list succeeds';
is_deeply $empty->{loans}, [], 'empty loans array';
is $empty->{pagination}{total_pages}, 0, 'empty list has zero total_pages';

for my $status (qw(ACTIVE RENEWAL_PENDING RETURNED EXPIRED REVOKED)) {
    ( $app, $log ) = application(
        repo_result => repo_result(
            loan_row(
                status      => $status,
                returned_at => $status eq 'RETURNED' ? '2026-08-01 10:00:00' : undef,
                revoked_at  => $status eq 'REVOKED'  ? '2026-08-01 10:00:00' : undef,
                expired_at  => $status eq 'EXPIRED'  ? '2026-08-01 10:00:00' : undef,
            )
        )
    );
    my $result = list($app);
    ok $result->{ok}, "status $status normalizes";
    is $result->{loans}[0]{status}, $status, "status $status preserved";
}

( $app, $log, $diagnostics ) = application(
    repo_result => repo_result( loan_row( portal_request_id => 'not-a-uuid' ) )
);
my $bad_uuid = list($app);
is $bad_uuid->{code}, 'INTERNAL_ERROR',
    'malformed portal_request_id fails closed';
ok grep( { $_ eq 'PORTAL_REQUEST_ID_INVALID' } @{$diagnostics} ),
    'malformed portal_request_id emits safe diagnostic category';

( $app, $log, $diagnostics ) = application(
    repo_result => repo_result( loan_row( request_patron_id => 51 ) )
);
is list($app)->{code}, 'INTERNAL_ERROR',
    'loan/request patron mismatch fails closed';

( $app, $log, $diagnostics ) = application(
    repo_result => repo_result( loan_row( request_biblio_id => 9 ) )
);
is list($app)->{code}, 'INTERNAL_ERROR',
    'loan/request biblio mismatch fails closed';

( $app, $log, $diagnostics ) = application(
    repo_result => repo_result( loan_row( patron_id => 51 ) )
);
is list($app)->{code}, 'INTERNAL_ERROR',
    'mismatched loan patron_id fails closed';

( $app, $log, $diagnostics ) = application(
    repo_result => repo_result( loan_row( status => 'OPEN' ) )
);
is list($app)->{code}, 'INTERNAL_ERROR', 'unsupported status fails closed';

( $app, $log, $diagnostics ) = application(
    repo_result => repo_result(
        loan_row(
            started_at => '2026-08-07 17:27:14',
            due_at     => '2026-07-24 17:27:14',
        )
    )
);
is list($app)->{code}, 'INTERNAL_ERROR',
    'due_at not later than started_at fails closed';

( $app, $log, $diagnostics ) = application(
    repo_result => repo_result( loan_row( nested => { bad => 1 } ) )
);
is list($app)->{code}, 'INTERNAL_ERROR', 'unsafe nested values fail closed';

( $app, $log ) = application( repo_error => 'db down' );
is list($app)->{code}, 'DIGITAL_CIRCULATION_UNAVAILABLE',
    'repository exception maps to unavailable';

( $app, $log, $diagnostics ) = application( diagnostic_dies => 1 );
my $diag_safe = list($app);
ok $diag_safe->{ok}, 'diagnostic callback failure does not alter success';

done_testing;
