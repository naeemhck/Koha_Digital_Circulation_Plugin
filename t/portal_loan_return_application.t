use Modern::Perl;
use Test::More;
use lib '.', 't/lib';

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReturnApplication;

my $app_class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalLoanReturnApplication';

sub returned_loan {
    return {
        loan_id           => 31,
        request_id        => 91,
        portal_request_id => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0091',
        patron_id         => 157,
        biblio_id         => 13,
        status            => 'RETURNED',
        started_at        => '2026-07-24 16:00:00',
        due_at            => '2026-08-07 16:00:00',
        returned_at       => '2026-07-26 12:00:00',
        revoked_at        => undef,
        expired_at        => undef,
        renewal_count     => 0,
        row_version       => 2,
        created_at        => '2026-07-24 16:00:00',
        updated_at        => '2026-07-26 12:00:00',
    };
}

sub fake_auth {
    my (%args) = @_;
    return bless {
        result => $args{result} // {
            allowed  => 1,
            actor_id => 53,
            code     => undef,
        },
        error => $args{error},
        calls => [],
    }, 'Local::PortalReturnAuth';
}

{
    package Local::PortalReturnAuth;
    sub authorize_controller {
        my ( $self, $controller ) = @_;
        push @{ $self->{calls} }, $controller;
        die $self->{error} if $self->{error};
        return { %{ $self->{result} } };
    }
}

sub fake_service {
    my (%args) = @_;
    return bless {
        result => $args{result} // {
            ok                => 1,
            loan              => returned_loan(),
            idempotent_replay => 0,
            correlation_id    => 'bbbbbbbb-cccc-4ddd-8eee-ffffffff0091',
        },
        error => $args{error},
        calls => [],
    }, 'Local::PortalReturnService';
}

{
    package Local::PortalReturnService;
    sub return_loan {
        my ( $self, %args ) = @_;
        push @{ $self->{calls} }, {%args};
        die $self->{error} if $self->{error};
        return { %{ $self->{result} } };
    }
}

sub app {
    my (%args) = @_;
    return $app_class->new(
        authorization  => $args{authorization}  || fake_auth(),
        return_service => $args{return_service} || fake_service(),
        diagnostic     => $args{diagnostic} || sub { },
    );
}

sub command {
    my (%overrides) = @_;
    return (
        controller           => ( bless {}, 'Fake::Controller' ),
        loan_id              => 31,
        patron_id            => 157,
        portal_request_id    => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0091',
        expected_row_version => 1,
        correlation_id       => 'bbbbbbbb-cccc-4ddd-8eee-ffffffff0091',
        %overrides,
    );
}

{
    my $auth = fake_auth();
    my $svc  = fake_service();
    my $app  = app( authorization => $auth, return_service => $svc );
    my $result = $app->return_loan( command() );
    ok $result->{ok}, 'service actor authorization succeeds through intended contract';
    is $result->{loan}{status}, 'RETURNED', 'normalized RETURNED loan returned';
    is $result->{actor_id}, 53, 'application preserves service actor id';
    is $svc->{calls}[0]{actor_id}, 53, 'service receives allowlisted actor, not patron';
    is $svc->{calls}[0]{patron_id}, 157, 'subject patron is command patron_id';
}

{
    my $app = app(
        authorization => fake_auth(
            result => {
                allowed  => 0,
                actor_id => 99,
                code     => 'SERVICE_ACCOUNT_NOT_AUTHORIZED',
            }
        )
    );
    my $result = $app->return_loan( command() );
    ok !$result->{ok}, 'unauthorized actor fails';
    is $result->{code}, 'SERVICE_ACCOUNT_NOT_AUTHORIZED', 'unauthorized code';
}

{
    my $app = app(
        authorization => fake_auth(
            result => {
                allowed  => 0,
                actor_id => undef,
                code     => 'AUTHENTICATION_REQUIRED',
            }
        )
    );
    my $result = $app->return_loan( command() );
    ok !$result->{ok}, 'unauthenticated actor fails';
    is $result->{code}, 'AUTHENTICATION_REQUIRED', 'auth required code';
}

{
    my $app = app(
        return_service => fake_service(
            result => {
                ok   => 0,
                code => 'VERSION_CONFLICT',
            }
        )
    );
    my $result = $app->return_loan( command() );
    ok !$result->{ok}, 'service version conflict surfaces safely';
    is $result->{code}, 'VERSION_CONFLICT', 'version conflict code preserved';
}

done_testing;
