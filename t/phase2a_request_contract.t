use Modern::Perl;
use Test::More;
use JSON qw(decode_json);
use File::Find;

open my $contract_fh, '<', 't/fixtures/phase2a_request_contract.json' or die $!;
my $contract = decode_json( do { local $/; <$contract_fh> } );

is $contract->{route}, '/api/v1/contrib/jzl-digital-circulation/requests', 'full Phase 2A route';
is $contract->{openapi_path}, '/requests', 'plugin-relative OpenAPI path';
is $contract->{method}, 'POST', 'request creation method';

my $auth = $contract->{authentication};
is $auth->{actor}, 'authenticated_koha_oauth_service_actor', 'OAuth service actor is authenticated';
is $auth->{authorization}, 'exact_plugin_configured_service_account_allowlist', 'service actor uses exact plugin allowlist';
ok !$auth->{browser_direct_allowed}, 'browser cannot call plugin creation route directly';
is $auth->{unauthenticated_status}, 401, 'unauthenticated access is denied';
is $auth->{unauthorized_service_status}, 403, 'non-allowlisted service actor is denied';
ok $auth->{subject_patron_distinct_from_actor}, 'subject patron is distinct from service actor';

is_deeply(
    [ sort keys %{ $contract->{required_headers} } ],
    [ sort qw(Authorization Content-Type Idempotency-Key X-Correlation-ID) ],
    'required service request headers'
);
is_deeply(
    [ sort @{ $contract->{request}{exact_body_fields} } ],
    [ sort qw(portal_request_id patron_id biblio_id) ],
    'request body contains only subject and portal identifiers'
);
is $contract->{request}{controller_forced_fields}{source}, 'PORTAL', 'controller forces PORTAL source';
ok scalar grep( { $_ eq 'source' } @{ $contract->{request}{untrusted_body_fields} } ), 'body source is never trusted';
ok scalar grep( { /actor/ } @{ $contract->{request}{untrusted_body_fields} } ), 'body actor identity is never trusted';

my $creation = $contract->{creation};
is $creation->{status}, 201, 'new request returns HTTP 201';
is $creation->{request_status}, 'PENDING', 'new request is PENDING';
ok !$creation->{idempotent_replay}, 'new request is not a replay';
ok !$creation->{duplicate_pending}, 'new request is not a duplicate pending result';
ok $creation->{stable_correlation_id}, 'creation returns a stable correlation ID';
is_deeply(
    [ sort @{ $creation->{response_fields} } ],
    [ sort qw(request idempotent_replay duplicate_pending correlation_id) ],
    'creation response envelope'
);
is_deeply(
    [ sort @{ $creation->{request_fields} } ],
    [ sort qw(request_id portal_request_id patron_id biblio_id status requested_at row_version) ],
    'creation response request fields'
);

my $replay = $contract->{repeat_behavior}{exact_replay};
is $replay->{status}, 200, 'exact replay returns HTTP 200';
ok $replay->{same_authoritative_request}, 'exact replay returns original request';
ok $replay->{idempotent_replay}, 'exact replay is labelled idempotent';
ok !$replay->{duplicate_pending}, 'exact replay is not labelled duplicate pending';
is $replay->{stored_request_count}, 1, 'exact replay stores one request';
is $replay->{request_created_event_count}, 1, 'exact replay stores one REQUEST_CREATED event';

my $pending = $contract->{repeat_behavior}{existing_pending};
is $pending->{status}, 200, 'existing pending returns HTTP 200';
ok $pending->{same_authoritative_request}, 'existing pending returns authoritative request';
ok !$pending->{idempotent_replay}, 'different key is not an idempotent replay';
ok $pending->{duplicate_pending}, 'existing pending is labelled duplicate pending';
is $pending->{stored_request_count}, 1, 'duplicate pending stores one request';
is $pending->{request_created_event_count}, 1, 'duplicate pending stores one REQUEST_CREATED event';

my $conflict = $contract->{repeat_behavior}{idempotency_conflict};
is $conflict->{status}, 409, 'idempotency conflict returns HTTP 409';
is $conflict->{error_code}, 'IDEMPOTENCY_CONFLICT', 'stable idempotency conflict code';
is_deeply(
    [ sort @{ $conflict->{conflicting_fields} } ],
    [ sort qw(patron_id biblio_id portal_request_id) ],
    'all effective-payload idempotency conflicts are covered'
);

is_deeply(
    $contract->{errors},
    {
        INVALID_INPUT                   => 400,
        INVALID_IDEMPOTENCY_KEY         => 400,
        AUTHENTICATION_REQUIRED         => 401,
        SERVICE_ACCOUNT_NOT_AUTHORIZED  => 403,
        PATRON_NOT_FOUND                => 404,
        BIBLIO_NOT_FOUND                => 404,
        CONTENT_NOT_ELIGIBLE            => 409,
        IDEMPOTENCY_CONFLICT            => 409,
        DIGITAL_CIRCULATION_UNAVAILABLE => 503,
        INTERNAL_ERROR                  => 500,
    },
    'stable Phase 2A error status contract'
);
is_deeply $contract->{error_envelope}{top_level_fields}, ['error'], 'error envelope has one top-level field';
is_deeply [ sort @{ $contract->{error_envelope}{error_fields} } ], [qw(code message)], 'safe error fields';
ok $contract->{error_envelope}{message_must_be_safe}, 'error messages must be safe';
is_deeply(
    [ sort @{ $contract->{error_envelope}{forbidden_leakage} } ],
    [ sort( 'SQL', 'DBI stack trace', 'filesystem path', 'password', 'OAuth secret', 'bearer token', 'database DSN' ) ],
    'sensitive implementation details cannot leak'
);
my $sensitive_error_pattern = qr{
    \bSELECT\b|\bINSERT\b|\bUPDATE\b|\bDELETE\b|
    DBI::|\.pm\s+line\s+\d+|
    [A-Za-z]:[\\/]|\A/[\w./-]+|
    password|client_secret|oauth[_ -]?secret|
    bearer\s+[A-Za-z0-9._~+/-]+|
    (?:mysql|mariadb|dbi):[^\s]+
}ix;
for my $unsafe_message (
    'DBI::db failed at Repository.pm line 42',
    'SELECT * FROM borrowers WHERE password = secret',
    'C:\koha\plugins\RequestService.pm failed',
    'Bearer eyJhbGciOiJub25lIn0.payload.signature',
    'DBI:mysql:database=koha_library;host=localhost',
) {
    like $unsafe_message, $sensitive_error_pattern, 'unsafe implementation message is rejected by the contract';
}
unlike 'The request could not be completed.', $sensitive_error_pattern, 'safe generic message is permitted';

is_deeply(
    $contract->{transaction}{ordered_steps},
    [
        qw(
          validate_idempotency_key
          validate_service_actor
          validate_subject_patron
          validate_koha_biblio
          validate_eligible_protected_ebookcontent
          check_existing_idempotency_record
          check_existing_pending_patron_biblio_request
          insert_pending_request
          insert_request_created_audit_event
          commit_request_and_event
        )
    ],
    'future transaction validation and write order'
);
ok $contract->{transaction}{request_and_event_atomic}, 'request and audit event are atomic';
ok $contract->{transaction}{audit_insert_failure_rolls_back_request}, 'audit failure rolls back request';
is $contract->{transaction}{request_created_event_type}, 'REQUEST_CREATED', 'request audit event type';

my $concurrency = $contract->{concurrency};
ok $concurrency->{uses_existing_database_uniqueness_constraints}, 'concurrency relies on database uniqueness';
is $concurrency->{stored_pending_request_count}, 1, 'concurrency stores one pending request';
ok $concurrency->{both_callers_receive_same_authoritative_request}, 'both concurrent callers receive one authoritative request';
is $concurrency->{creation_response_count}, 1, 'exactly one concurrent caller gets creation behavior';
is_deeply [ sort @{ $concurrency->{other_response} } ], [ sort qw(duplicate_pending idempotent_replay) ], 'other caller gets stable repeat behavior';
ok !$concurrency->{raw_duplicate_key_exposed}, 'raw duplicate-key errors are hidden';
is $concurrency->{request_created_event_count}, 1, 'concurrency stores one audit event';
ok !$concurrency->{live_mariadb_verified_on_windows}, 'Windows test does not claim live MariaDB concurrency';
is $concurrency->{verification}, 'deterministic_contract_only', 'concurrency coverage is explicitly a deterministic specification';

my $phase1 = $contract->{phase1_protections};
ok $phase1->{existing_get_routes_remain}, 'existing GET routes remain required';
ok $phase1->{existing_get_authorization_unchanged}, 'existing GET authorization remains unchanged';
ok $phase1->{staff_ui_read_only}, 'staff interface remains read only';
is_deeply $phase1->{allowed_write_routes}, ['POST /requests'], 'only request creation is permitted';
is_deeply(
    [ sort @{ $phase1->{forbidden_write_domains} } ],
    [ sort qw(loans renewals access_entitlements librarian_decisions) ],
    'Phase 2A cannot mutate later-phase domains'
);
is_deeply(
    [ sort @{ $phase1->{forbidden_native_koha_tables} } ],
    [ sort qw(issues old_issues reserves items) ],
    'native Koha circulation tables remain outside digital writes'
);
ok $phase1->{uninstall_data_preserving}, 'uninstall remains data preserving';

open my $tool_fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/tool.tt' or die $!;
my $tool = do { local $/; <$tool_fh> };
for my $control ( @{ $phase1->{forbidden_staff_controls} } ) {
    unlike $tool, qr/>\s*\Q$control\E\s*</, "staff UI has no $control control";
}

my @production_files;
find( sub { push @production_files, $File::Find::name if -f && /\.(?:pm|json)\z/ }, 'Koha' );
my $production_source = join "\n", map {
    open my $fh, '<', $_ or die $!;
    local $/;
    <$fh>;
} @production_files;
unlike(
    $production_source,
    qr/\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|REPLACE\s+INTO)\s+`?(?:issues|old_issues|reserves|items)`?\b/i,
    'production code does not write native Koha circulation tables'
);

open my $api_fh, '<', 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json' or die $!;
my $api = decode_json( do { local $/; <$api_fh> } );
for my $path (
    qw(
      /health /version /requests /requests/{request_id}
      /loans /loans/{loan_id} /renewals /renewals/{renewal_id}
      /events /events/{event_id}
    )
) {
    ok exists $api->{$path}{get}, "existing GET $path remains";
    ok $api->{$path}{get}{'x-koha-authorization'}, "existing GET authorization remains for $path";
}

my @write_routes;
for my $path ( sort keys %{$api} ) {
    for my $method ( sort keys %{ $api->{$path} } ) {
        push @write_routes, "$method $path" if $method =~ /\A(?:post|put|patch|delete)\z/i;
    }
}
is_deeply(
    \@write_routes,
    [
        'post /requests',
        'post /requests/{request_id}/decision',
    ],
    'production preserves request creation and adds only the staff decision write route'
);

my $post = $api->{'/requests'}{post};
ok $post, 'POST /requests is defined';
ok $post->{'x-koha-authorization'}, 'POST declares Koha authentication';
is $post->{'x-mojo-to'}, 'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#create', 'POST controller agreement';
my %parameters = map { ( $_->{in} . ':' . $_->{name} ) => $_ } @{ $post->{parameters} // [] };
ok $parameters{'header:Idempotency-Key'}{required}, 'Idempotency-Key is required';
ok $parameters{'header:X-Correlation-ID'}{required}, 'X-Correlation-ID is required';
ok $parameters{'body:body'}{required}, 'JSON body is required';
my $properties = $parameters{'body:body'}{schema}{properties} // {};
is_deeply [ sort keys %{$properties} ], [ sort qw(portal_request_id patron_id biblio_id) ], 'POST body does not accept actor or source';
my $responses = $post->{responses} // {};
ok exists $responses->{201} && exists $responses->{200}, 'POST declares creation and repeat success';
ok exists $responses->{400} && exists $responses->{401} && exists $responses->{403}
    && exists $responses->{404} && exists $responses->{409}
    && exists $responses->{500} && exists $responses->{503},
    'POST declares stable error statuses';

done_testing;
