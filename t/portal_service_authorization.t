use Modern::Perl;
use Test::More;
use JSON qw(decode_json);
use lib '.';
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;

{
    package Local::PluginData;
    sub new { bless { value => $_[1], unreadable => $_[2], stored => undef }, $_[0] }
    sub retrieve_data {
        my ( $self, $key ) = @_;
        die 'unreadable plugin data' if $self->{unreadable};
        $self->{read_key} = $key;
        return $self->{value};
    }
    sub store_data {
        my ( $self, $data ) = @_;
        $self->{stored} = { %{$data} };
        $self->{value} = $data->{portal_service_account_ids};
        return 1;
    }
}

{
    package Local::KohaActor;
    sub new { bless { borrowernumber => $_[1] }, $_[0] }
    sub borrowernumber { return $_[0]{borrowernumber} }
}

{
    package Local::MissingIdActor;
    sub new { bless {}, $_[0] }
}

{
    package Local::Controller;
    sub new { bless { actor => $_[1], body => $_[2] }, $_[0] }
    sub stash {
        my ( $self, $key ) = @_;
        die 'unexpected stash key' unless $key eq 'koha.user';
        return $self->{actor};
    }
    sub body { return $_[0]{body} }
}

my $class = 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization';
is $class->config_key, 'portal_service_account_ids', 'stable plugin configuration key';

sub service {
    my ( $raw, %args ) = @_;
    my $plugin = Local::PluginData->new( $raw, $args{unreadable} );
    return ( $class->new( plugin => $plugin ), $plugin );
}

sub controller {
    my ( $actor_id, $body ) = @_;
    my $actor = defined $actor_id ? Local::KohaActor->new($actor_id) : undef;
    return Local::Controller->new( $actor, $body );
}

sub authorize {
    my ( $raw, $actor_id, %args ) = @_;
    my ($service) = service( $raw, %args );
    return $service->authorize_controller( controller( $actor_id, $args{body} ) );
}

for my $case (
    [ undef, 'missing configuration denies' ],
    [ '', 'blank configuration denies' ],
    [ ' , , ', 'empty configuration denies' ],
    [ 'abc,-1,0,1.5,1e3', 'malformed-only configuration denies' ],
    [ '123,abc', 'one malformed entry fails the whole configuration closed' ],
) {
    my $result = authorize( $case->[0], 123 );
    ok !$result->{allowed}, $case->[1];
    is $result->{code}, 'SERVICE_ACCOUNT_NOT_AUTHORIZED', "$case->[1] uses stable code";
}

my $single = authorize( '123', 123 );
ok $single->{allowed}, 'valid single ID authorizes exact actor';
is $single->{actor_id}, 123, 'authorized result contains actor ID';
ok !defined $single->{code}, 'authorized result has no error code';

for my $actor_id ( 123, 456, 789 ) {
    ok authorize( '123,456,789', $actor_id )->{allowed}, "multiple IDs authorize actor $actor_id";
}

my $parsed = $class->_parse_allowlist(' 456, 123,456, ,789 ');
ok $parsed->{valid}, 'whitespace and empty entries are safely handled';
is $parsed->{count}, 3, 'duplicate IDs are normalized';
is $parsed->{canonical}, '123,456,789', 'stored representation is canonical';

ok !authorize( '312', 12 )->{allowed}, 'actor 12 does not match configured 312';
ok !authorize( '1234', 123 )->{allowed}, 'actor 123 does not match configured 1234';
ok !authorize( '12', 312 )->{allowed}, 'configured 12 does not match actor 312';

for my $invalid ( '0', '-123', '1.5', '1e3', '123abc' ) {
    my $invalid_parsed = $class->_parse_allowlist($invalid);
    ok !$invalid_parsed->{valid}, "invalid ID '$invalid' is rejected";
    is $invalid_parsed->{count}, 0, "invalid ID '$invalid' authorizes nobody";
}

my ($unreadable_service) = service( '123', unreadable => 1 );
my $unreadable = $unreadable_service->authorize_controller( controller(123) );
ok !$unreadable->{allowed}, 'unreadable configuration denies';
is $unreadable->{code}, 'SERVICE_ACCOUNT_NOT_AUTHORIZED', 'unreadable configuration uses stable authorization code';

my ($missing_plugin_service) = ( $class->new );
my $missing_plugin = $missing_plugin_service->authorize_controller( controller(123) );
ok !$missing_plugin->{allowed}, 'missing plugin configuration access denies';

my ($auth_service) = service('123');
my $unauthenticated = $auth_service->authorize_controller( controller(undef) );
ok !$unauthenticated->{allowed}, 'unauthenticated context denies';
is $unauthenticated->{code}, 'AUTHENTICATION_REQUIRED', 'unauthenticated context has stable code';
ok !defined $unauthenticated->{actor_id}, 'unauthenticated result has no actor ID';

my $missing_id = $auth_service->authorize_controller( Local::Controller->new( Local::MissingIdActor->new ) );
ok !$missing_id->{allowed}, 'authenticated actor without borrowernumber denies';
is $missing_id->{code}, 'SERVICE_ACCOUNT_NOT_AUTHORIZED', 'missing actor ID has stable authorization code';
is $missing_id->{reason}, 'ACTOR_ID_MISSING', 'missing actor ID is distinguished internally';

my $undefined_id = $auth_service->authorize_controller(
    Local::Controller->new( Local::KohaActor->new(undef) )
);
ok !$undefined_id->{allowed}, 'authenticated actor with undefined borrowernumber denies';
is $undefined_id->{code}, 'SERVICE_ACCOUNT_NOT_AUTHORIZED', 'undefined actor ID has stable authorization code';

my $unlisted = $auth_service->authorize_controller( controller(999) );
ok !$unlisted->{allowed}, 'authenticated unlisted actor denies';
is $unlisted->{actor_id}, 999, 'unlisted result identifies only evaluated actor';
is $unlisted->{code}, 'SERVICE_ACCOUNT_NOT_AUTHORIZED', 'unlisted actor has stable code';

my $body_cannot_authorize = $auth_service->authorize_controller(
    controller( 999, { patron_id => 123, actor_id => 123 } )
);
ok !$body_cannot_authorize->{allowed}, 'request-body patron or actor cannot influence authorization';

for my $result ( $single, $unlisted, $body_cannot_authorize ) {
    ok !exists $result->{allowlist}, 'authorization result does not expose allowlist';
    ok !exists $result->{configured_ids}, 'authorization result does not expose configured IDs';
}

my ( $storage_service, $storage_plugin ) = service(undef);
my $stored = $storage_service->store_config(' 456,123,456 ');
ok $stored->{stored}, 'valid configuration is stored through plugin API';
is $stored->{count}, 2, 'stored result exposes count only';
is $storage_plugin->{stored}{portal_service_account_ids}, '123,456', 'plugin API receives canonical configuration';
ok !exists $stored->{allowlist}, 'storage result does not expose allowlist';

my $rejected_store = $storage_service->store_config('123abc');
ok !$rejected_store->{stored}, 'malformed configuration is not stored';
is $rejected_store->{code}, 'INVALID_SERVICE_ACCOUNT_ALLOWLIST', 'malformed storage has stable code';
is $storage_plugin->{stored}{portal_service_account_ids}, '123,456', 'rejected update does not broaden stored configuration';

open my $main_fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation.pm' or die $!;
my $main = do { local $/; <$main_fh> };
like(
    $main,
    qr/sub _staff_allowed \{.*?C4::Context->userenv.*?haspermission\(.*?circulate_remaining_permissions.*?return \$permission \? 1 : 0;.*?\}/s,
    'existing staff GET/tool permission logic remains unchanged'
);

open my $api_fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json' or die $!;
my $api = decode_json( do { local $/; <$api_fh> } );
ok exists $api->{'/requests'}{post}, 'Phase 2A POST route is exposed';

done_testing;
