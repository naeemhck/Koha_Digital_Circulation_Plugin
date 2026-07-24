use Modern::Perl;
use Test::More;
use JSON::PP;

my $path =
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json';
open my $fh, '<', $path or die $!;
my $api = JSON::PP::decode_json( do { local $/; <$fh> } );

my @post_routes =
    sort map { exists $api->{$_}{post} ? $_ : () } keys %{$api};
is_deeply \@post_routes,
    [ '/requests', '/requests/{request_id}/decision' ],
    'exactly the two approved POST routes exist';

my $creation = $api->{'/requests'}{post};
ok $creation, 'portal request-creation route remains';
is $creation->{operationId}, 'jzlCreateDigitalRequest',
    'portal creation operation ID is unchanged';
is $creation->{'x-mojo-to'},
    'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#create',
    'portal creation controller is unchanged';
my %creation_parameters = map {
    ( ( $_->{in} // '' ) . ':' . ( $_->{name} // '' ) ) => $_
} @{ $creation->{parameters} // [] };
is_deeply(
    [
        sort keys %{
            $creation_parameters{'body:body'}{schema}{properties}
        }
    ],
    [ sort qw(portal_request_id patron_id biblio_id) ],
    'portal creation body remains unchanged'
);

my $decision = $api->{'/requests/{request_id}/decision'}{post};
ok $decision, 'staff decision route exists';
is $decision->{operationId}, 'jzlDecideDigitalRequest',
    'staff decision operation ID follows plugin convention';
is $decision->{'x-mojo-to'},
    'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#decide',
    'staff decision route targets narrow controller method';
is_deeply $decision->{'x-koha-authorization'}{permissions},
    { circulate => 'circulate_remaining_permissions' },
    'staff decision route declares established Koha permission';

my %parameters = map {
    ( ( $_->{in} // '' ) . ':' . ( $_->{name} // '' ) ) => $_
} @{ $decision->{parameters} // [] };
is_deeply [ sort keys %parameters ],
    [ sort 'path:request_id', 'header:X-Correlation-ID', 'body:body' ],
    'decision route accepts only path, correlation header, and body';
ok $parameters{'path:request_id'}{required},
    'request ID path parameter is required';
is $parameters{'path:request_id'}{type}, 'integer',
    'request ID path parameter is integer';
is $parameters{'path:request_id'}{minimum}, 1,
    'request ID path parameter is positive';
ok $parameters{'header:X-Correlation-ID'}{required},
    'correlation header is required';
like $parameters{'header:X-Correlation-ID'}{pattern},
    qr/\[1-5\].*\[89abAB\]/,
    'correlation header documents UUID structure';
ok $parameters{'body:body'}{required}, 'decision body is required';

my $body = $parameters{'body:body'}{schema};
is $body->{type}, 'object', 'decision body is an object';
ok !$body->{additionalProperties},
    'decision body rejects additional fields';
is_deeply [ sort @{ $body->{required} } ],
    [ sort qw(expected_row_version decision) ],
    'decision body has exact required fields';
is_deeply [ sort keys %{ $body->{properties} } ],
    [ sort qw(expected_row_version decision reason) ],
    'decision body has exact property allowlist';
is_deeply $body->{properties}{decision}{enum},
    [qw(APPROVE REJECT)],
    'decision command enum is exact';
is $body->{properties}{expected_row_version}{minimum}, 1,
    'expected row version must be positive';
is $body->{properties}{reason}{maxLength}, 4096,
    'reason maximum matches persistence contract';
ok $body->{properties}{reason}{'x-nullable'},
    'approval reason may be null';
for my $forbidden (
    qw(
      actor_id actor_patron_id patron_id biblio_id status approved_by
      rejected_by approved_at rejected_at row_version loan_id renewal_id
      event_type source
    )
    )
{
    ok !exists $body->{properties}{$forbidden},
        "decision body excludes $forbidden";
}

is_deeply [ sort keys %{ $decision->{responses} } ],
    [ sort qw(200 400 401 403 404 409 500 503) ],
    'decision route documents complete response statuses';
my $success = $decision->{responses}{200}{schema};
ok !$success->{additionalProperties},
    'success envelope rejects additional fields';
is_deeply [ sort keys %{ $success->{properties} } ],
    [
        sort qw(
          request previous_status new_status previous_row_version row_version
          correlation_id
        )
    ],
    'success envelope exposes exact public fields';
my $public_request = $success->{properties}{request};
ok !$public_request->{additionalProperties},
    'public staff request rejects additional fields';
is_deeply [ sort keys %{ $public_request->{properties} } ],
    [
        sort qw(
          request_id portal_request_id patron_id biblio_id status requested_at
          approved_at approved_by rejected_at rejected_by rejection_reason
          row_version
        )
    ],
    'public staff request schema has exact field allowlist';
for my $forbidden (
    qw(
      portal_idempotency_key pending_guard payload_json loan_id renewal_id
      source created_at updated_at
    )
    )
{
    ok !exists $public_request->{properties}{$forbidden},
        "public staff request excludes $forbidden";
}

for my $status (qw(400 401 403 404 409 500 503)) {
    my $error = $decision->{responses}{$status}{schema};
    ok !$error->{additionalProperties},
        "$status error envelope is closed";
    is_deeply [ sort keys %{ $error->{properties} } ], ['error'],
        "$status documents standard error envelope";
    is_deeply [ sort keys %{ $error->{properties}{error}{properties} } ],
        [qw(code message)], "$status error exposes only code and message";
}

is_deeply [ sort keys %{ $decision->{'x-jzl-schemas'} } ],
    [qw(DecisionSuccess PublicStaffRequest StaffDecisionCommand StandardError)],
    'route publishes reusable named decision schemas';

my @operation_ids;
for my $route ( keys %{$api} ) {
    for my $method ( keys %{ $api->{$route} } ) {
        next unless $method =~ /\A(?:get|post|put|patch|delete)\z/;
        push @operation_ids, $api->{$route}{$method}{operationId};
    }
}
is scalar @operation_ids,
    scalar keys %{ { map { $_ => 1 } @operation_ids } },
    'all operation IDs remain unique';
ok !exists $api->{'/loans'}{post}
    && !exists $api->{'/renewals'}{post},
    'no loan or renewal write route is introduced';

open my $tool_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/tool.tt'
    or die $!;
my $tool = do { local $/; <$tool_fh> };
open my $staff_js_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/static/js/jzl-digital-circulation.js'
    or die $!;
my $staff_js = do { local $/; <$staff_js_fh> };
like $tool, qr/Phase 2B .* request decisions/,
    'staff tool exposes the Phase 2B request-decision interface';
like $staff_js, qr/approve\.textContent = 'Approve'/,
    'staff tool provides Approve through the packaged script';
like $staff_js, qr/reject\.textContent = 'Reject'/,
    'staff tool provides Reject through the packaged script';
like $staff_js, qr/request\.status === 'PENDING'/,
    'staff decision controls are limited to pending requests';
unlike $tool . $staff_js,
    qr/>\s*(?:Create|Delete|Edit|Issue|Renew|Return|Revoke)\s*</,
    'staff tool provides no unrelated write control';

done_testing;
