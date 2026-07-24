use Modern::Perl;
use Test::More;
use JSON qw(decode_json);
use lib '.';

BEGIN {
    package Koha::Token;
    sub new { bless {}, $_[0] }
    $INC{'Koha/Token.pm'} = __FILE__;
}

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization;

{
    package Local::ConfigurationCGI;
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }
    sub request_method { return $_[0]{method} // 'GET' }
    sub cookie { return $_[1] eq 'CGISESSID' ? ( $_[0]{session_id} // 'session-1' ) : undef }
    sub param { return $_[0]{params}{ $_[1] } }

    package Local::ConfigurationToken;
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }
    sub check_csrf {
        my ( $self, $args ) = @_;
        $self->{checked} = { %{$args} };
        die $self->{check_error} if $self->{check_error};
        return $self->{valid};
    }
    sub generate_csrf {
        my ( $self, $args ) = @_;
        $self->{generated} = { %{$args} };
        die $self->{generate_error} if $self->{generate_error};
        return 'generated-csrf-token';
    }

    package Local::ConfigurationTemplate;
    sub new { bless { params => {} }, $_[0] }
    sub param {
        my ( $self, %params ) = @_;
        $self->{params} = { %params };
        return;
    }
    sub output { return 'rendered-configuration' }

    package Local::ConfigurationPlugin;
    our @ISA = ('Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation');
    sub new {
        my ( $class, %args ) = @_;
        $args{template} = Local::ConfigurationTemplate->new;
        return bless \%args, $class;
    }
    sub retrieve_data {
        my ( $self, $key ) = @_;
        push @{ $self->{retrieve_keys} }, $key;
        die $self->{retrieve_error} if $self->{retrieve_error};
        return $self->{stored_value};
    }
    sub store_data {
        my ( $self, $data ) = @_;
        push @{ $self->{store_calls} }, { %{$data} };
        die $self->{store_error} if $self->{store_error};
        $self->{stored_value} = $data->{portal_service_account_ids};
        return 1;
    }
    sub get_template {
        my ( $self, $args ) = @_;
        $self->{template_file} = $args->{file};
        return $self->{template};
    }
    sub output_html {
        my ( $self, $html ) = @_;
        $self->{output} = $html;
        return $html;
    }
    sub _configuration_tokenizer { return shift->{tokenizer} }
}

my $bundle = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation';
my $class =
    'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::PortalServiceAuthorization';

sub run_configuration {
    my (%args) = @_;
    my $tokenizer = Local::ConfigurationToken->new(
        valid          => exists $args{csrf_valid} ? $args{csrf_valid} : 1,
        check_error    => $args{check_error},
        generate_error => $args{generate_error},
    );
    my $cgi = Local::ConfigurationCGI->new(
        method => $args{method} // 'GET',
        params => {
            op => 'cud-save-portal-service-accounts',
            csrf_token => 'submitted-csrf-token',
            portal_service_account_ids => $args{submitted},
            %{ $args{params} || {} },
        },
    );
    my $plugin = Local::ConfigurationPlugin->new(
        cgi            => $cgi,
        tokenizer      => $tokenizer,
        stored_value   => $args{stored_value},
        store_error    => $args{store_error},
        retrieve_error => $args{retrieve_error},
        store_calls    => [],
        retrieve_keys  => [],
    );
    my $output = $plugin->configure;
    return ( $plugin, $tokenizer, $output );
}

open my $main_fh, '<', "$bundle.pm" or die $!;
my $main_source = do { local $/; <$main_fh> };
my ($configure_source) = $main_source =~ /(sub configure \{.*?\n\})/s;
my ($tool_source) = $main_source =~ /(sub tool \{.*?\n\})/s;
ok $configure_source && $tool_source, 'configure and tool are distinct methods';
unlike $configure_source, qr/return\s+\$self->tool/,
    'configure does not redirect to the operational tool';
like $tool_source, qr/get_template\(\s*\{\s*file\s*=>\s*'tool\.tt'/s,
    'tool continues to render the operational template';
like $configure_source, qr/get_template\(\s*\{\s*file\s*=>\s*'configure\.tt'/s,
    'configure renders its dedicated template';

ok -f "$bundle/configure.tt", 'configuration template exists at bundle root';
ok !-f "$bundle/templates/configure.tt",
    'configuration template is absent from obsolete templates directory';

my ( $get_plugin, $get_token, $get_output ) = run_configuration(
    stored_value => '123,456',
);
is scalar @{ $get_plugin->{store_calls} }, 0,
    'GET rendering does not change stored data';
is_deeply $get_plugin->{retrieve_keys}, ['portal_service_account_ids'],
    'GET reads only the fixed allowlist key';
is $get_plugin->{template_file}, 'configure.tt',
    'GET locates root-level configure.tt';
is $get_plugin->{template}{params}{portal_service_account_ids}, '123,456',
    'GET renders the current canonical identifiers';
ok !defined $get_plugin->{template}{params}{message},
    'GET has no false success message';
is $get_output, 'rendered-configuration',
    'configuration output uses the plugin rendering mechanism';
is_deeply $get_token->{generated}, { session_id => 'session-1' },
    'GET generates a session-bound CSRF token';

for my $case (
    [ 'single ID', '123', '123' ],
    [ 'multiple IDs', '123,456,789', '123,456,789' ],
    [ 'whitespace and duplicates', ' 456, 123,456 ', '123,456' ],
) {
    my ( $label, $submitted, $canonical ) = @{$case};
    my ($plugin) = run_configuration(
        method       => 'POST',
        submitted    => $submitted,
        stored_value => '999',
    );
    is scalar @{ $plugin->{store_calls} }, 1, "$label saves once";
    is_deeply(
        $plugin->{store_calls}[0],
        { portal_service_account_ids => $canonical },
        "$label stores only the canonical fixed key"
    );
    is $plugin->{template}{params}{portal_service_account_ids}, $canonical,
        "$label reloads canonical stored data";
    is $plugin->{template}{params}{message},
        'Portal service-account configuration saved.',
        "$label uses stable success feedback";
    ok !defined $plugin->{template}{params}{error},
        "$label renders no error";
}

my ($clear_plugin) = run_configuration(
    method       => 'POST',
    submitted    => '   ',
    stored_value => '123',
);
is_deeply(
    $clear_plugin->{store_calls}[0],
    { portal_service_account_ids => '' },
    'blank submission clears the fixed setting'
);
is $clear_plugin->{template}{params}{portal_service_account_ids}, '',
    'cleared configuration is rendered blank';
is $clear_plugin->{template}{params}{message},
    'Portal service-account access has been disabled.',
    'blank submission uses stable disabled feedback';

for my $case (
    [ zero          => '0' ],
    [ negative      => '-1' ],
    [ decimal       => '1.5' ],
    [ exponent      => '1e3' ],
    [ alphabetic    => 'abc' ],
    [ partial       => '123abc' ],
    [ wrong_delimiter => '123;456' ],
    [ json_array    => '[123,456]' ],
    [ oversized     => '1' x 4097 ],
) {
    my ( $label, $invalid ) = @{$case};
    my ($plugin) = run_configuration(
        method       => 'POST',
        submitted    => $invalid,
        stored_value => '123,456',
    );
    is scalar @{ $plugin->{store_calls} }, 0,
        "$label input is not stored";
    is $plugin->{stored_value}, '123,456',
        "$label input preserves the previous value";
    is $plugin->{template}{params}{portal_service_account_ids}, '123,456',
        "$label input reloads the previous value";
    is $plugin->{template}{params}{error},
        'Enter only positive Koha borrowernumbers separated by commas.',
        "$label input uses stable feedback";
}

my $structure = $class->new(
    plugin => Local::ConfigurationPlugin->new(
        stored_value  => '123',
        store_calls   => [],
        retrieve_keys => [],
    )
)->store_config( [ 123, 456 ] );
ok !$structure->{stored}, 'Perl structure submission is rejected';
is $structure->{code}, 'INVALID_SERVICE_ACCOUNT_ALLOWLIST',
    'Perl structure rejection has the stable validation code';

my ($storage_failure) = run_configuration(
    method       => 'POST',
    submitted    => '456',
    stored_value => '123',
    store_error  => 'DBI password secret at C:\koha\Plugin.pm line 7',
);
is $storage_failure->{stored_value}, '123',
    'storage exception preserves the previous value';
is $storage_failure->{template}{params}{error},
    'The configuration could not be saved safely.',
    'storage exception produces safe feedback';
unlike $storage_failure->{template}{params}{error},
    qr{DBI|password|secret|[A-Za-z]:[\\/]|line \d+}i,
    'storage exception details are not rendered';

my ($retrieval_failure) = run_configuration(
    retrieve_error => 'DBI client_secret Bearer token at /srv/koha/Plugin.pm line 8',
);
is $retrieval_failure->{template}{params}{portal_service_account_ids}, '',
    'retrieval exception renders no unverified identifiers';
is $retrieval_failure->{template}{params}{error},
    'The current configuration could not be loaded safely.',
    'retrieval exception produces safe feedback';
unlike $retrieval_failure->{template}{params}{error},
    qr{DBI|client_secret|Bearer|token|/srv/|line \d+}i,
    'retrieval exception details are not rendered';

my ($structured_retrieval) = run_configuration(
    stored_value => [ 123, 456 ],
);
is $structured_retrieval->{template}{params}{portal_service_account_ids}, '',
    'structured stored data is never rendered';
is $structured_retrieval->{template}{params}{error},
    'The current configuration could not be loaded safely.',
    'structured stored data fails safely';

my ( $csrf_failure, $csrf_token ) = run_configuration(
    method       => 'POST',
    submitted    => '456',
    stored_value => '123',
    csrf_valid   => 0,
);
is scalar @{ $csrf_failure->{store_calls} }, 0,
    'failed CSRF validation cannot change configuration';
is $csrf_failure->{stored_value}, '123',
    'failed CSRF validation preserves the previous value';
is $csrf_failure->{template}{params}{error},
    'The form expired or failed CSRF validation.',
    'failed CSRF validation uses stable feedback';
is_deeply(
    $csrf_token->{checked},
    {
        session_id => 'session-1',
        token      => 'submitted-csrf-token',
    },
    'POST validates the submitted token against the Koha session'
);

my ($wrong_action) = run_configuration(
    method       => 'POST',
    submitted    => '456',
    stored_value => '123',
    params       => { op => 'cud-arbitrary-key' },
);
is scalar @{ $wrong_action->{store_calls} }, 0,
    'unknown configuration action cannot write data';
is $wrong_action->{template}{params}{error},
    'The requested configuration action is invalid.',
    'unknown action fails safely';

open my $template_fh, '<', "$bundle/configure.tt" or die $!;
my $template = do { local $/; <$template_fh> };
my @input_names = $template =~ /<input\b[^>]*\bname="([^"]+)"/gi;
is_deeply(
    [ sort @input_names ],
    [ sort qw(class csrf_token method op portal_service_account_ids) ],
    'form accepts only framework controls and the fixed allowlist field'
);
unlike $template,
    qr/name="[^"]*(?:client_secret|bearer|token(?!")|password|dsn|database)[^"]*"/i,
    'configuration template requests no credential field';
like $template, qr/does not store OAuth credentials/i,
    'template explains that OAuth credentials are not stored';
like $template, qr/Leaving it blank disables portal request creation/i,
    'template explains fail-closed blank behavior';

unlike $configure_source, qr/\b(?:SELECT|INSERT|UPDATE|DELETE)\b/i,
    'configure contains no SQL';
unlike $configure_source, qr/\beval\s+[$"'`]/,
    'configure never evaluates submitted input as code';
unlike $configure_source, qr/(?:decode_json|thaw|Storable|YAML|deserialize)/i,
    'configure performs no unsafe object deserialization';
unlike $configure_source, qr/(?:warn|say|print|log).*(?:portal_service_account_ids|allowlist)/i,
    'configure does not log configuration values';

open my $tool_fh, '<', "$bundle/tool.tt" or die $!;
my $tool = do { local $/; <$tool_fh> };
open my $staff_js_fh, '<', "$bundle/static/js/jzl-digital-circulation.js"
    or die $!;
my $staff_js = do { local $/; <$staff_js_fh> };
like $staff_js, qr/approve\.textContent = 'Approve'/,
    'operational tool provides the Phase 2B Approve control';
like $staff_js, qr/reject\.textContent = 'Reject'/,
    'operational tool provides the Phase 2B Reject control';
like $staff_js, qr/request\.status === 'PENDING'/,
    'operational decision controls are pending-only';
for my $control (qw(Return Revoke Renew Edit Delete Create Issue)) {
    unlike $tool . $staff_js, qr/>\s*\Q$control\E\s*</,
        "operational tool has no unrelated $control control";
}
like $main_source, qr/method=tool/,
    'Circulation navigation continues to open the operational tool';
unlike $tool, qr/portal_service_account_ids/,
    'operational page does not expose the configured allowlist';

open my $api_fh, '<', "$bundle/openapi.json" or die $!;
my $api = decode_json( do { local $/; <$api_fh> } );
my @posts;
for my $path ( sort keys %{$api} ) {
    push @posts, $path if exists $api->{$path}{post};
}
is_deeply \@posts,
    [ '/requests', '/requests/{request_id}/decision' ],
    'configuration adds no route and preserves the two approved POST routes';
is $api->{'/requests'}{post}{operationId}, 'jzlCreateDigitalRequest',
    'POST /requests operation remains unchanged';
is $api->{'/requests'}{post}{'x-mojo-to'},
    'Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#create',
    'POST /requests controller remains unchanged';
open my $api_source_fh, '<', "$bundle/openapi.json" or die $!;
my $api_source = do { local $/; <$api_source_fh> };
unlike $api_source, qr/portal_service_account_ids/,
    'business API does not expose the allowlist key';

done_testing;
