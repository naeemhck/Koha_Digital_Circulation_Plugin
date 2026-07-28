use Modern::Perl;
use Test::More;
use Storable qw(dclone);
use lib '.', 't/lib';
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
use PluginUpgradeFakes;

my $plugin =
    bless {}, 'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation';

sub expected_state {
    my ($version) = @_;
    return {
        schema_version => 1,
        plugin_version => $version,
        migration_name => '001_initial_schema',
        checksum       => '69bcf09d56f99afe',
    };
}

sub business_data {
    return (
        requests => [
            {
                request_id => 9,
                status     => 'APPROVED',
                row_version => 2,
            }
        ],
        loans => [
            {
                loan_id      => 3,
                request_id   => 9,
                status       => 'ACTIVE',
                row_version  => 1,
                returned_at  => undef,
                revoked_at   => undef,
                expired_at   => undef,
                renewal_count => 0,
            }
        ],
        events => [
            {
                event_id  => 21,
                event_type => 'LOAN_CREATED',
                loan_id   => 3,
            }
        ],
        native_issues => [],
    );
}

sub run_with_dbh {
    my ( $method, $dbh ) = @_;
    my $result;
    {
        no warnings 'redefine';
        local *C4::Context::dbh = sub { return $dbh };
        $result = $plugin->$method;
    }
    return $result;
}

subtest 'fresh install writes one canonical 0.3.0 schema-1 state' => sub {
    my $dbh = Local::PluginUpgradeDBH->new;
    ok run_with_dbh( 'install', $dbh ), 'fresh install succeeds';
    is scalar @{ $dbh->{schema_rows} }, 1, 'one canonical state row exists';
    is_deeply $dbh->{schema_rows}[0], expected_state('0.3.0'),
        'fresh state records schema 1 and current plugin version';
    is_deeply [ grep { /^(?:begin|commit|rollback)$/ } @{ $dbh->{calls} } ],
        [qw(begin commit)], 'state write and verification commit';
};

subtest '0.2.3 to 0.3.0 upgrade preserves business data' => sub {
    my %business = business_data();
    my $dbh = Local::PluginUpgradeDBH->new(
        existing_tables => 1,
        schema_rows     => [ expected_state('0.2.3') ],
        %business,
    );
    my $before = dclone(
        {
            map { $_ => $dbh->{$_} }
                qw(requests loans renewals events native_issues)
        }
    );
    ok run_with_dbh( 'upgrade', $dbh ), 'prior-version upgrade succeeds';
    is scalar @{ $dbh->{schema_rows} }, 1, 'upgrade creates no duplicate row';
    is_deeply $dbh->{schema_rows}[0], expected_state('0.3.0'),
        'plugin-version stamp advances while schema remains 1';
    is_deeply(
        { map { $_ => $dbh->{$_} } keys %{$before} },
        $before,
        'request, loan, event, renewal, and native issue data are unchanged',
    );
};

subtest '0.3.0 replay is idempotent' => sub {
    my %business = business_data();
    my $dbh = Local::PluginUpgradeDBH->new(
        existing_tables => 1,
        schema_rows     => [ expected_state('0.3.0') ],
        %business,
    );
    my $before = dclone(
        {
            schema_rows => $dbh->{schema_rows},
            map { $_ => $dbh->{$_} }
                qw(requests loans renewals events native_issues)
        }
    );
    ok run_with_dbh( 'upgrade', $dbh ), 'replayed upgrade succeeds';
    is_deeply(
        {
            schema_rows => $dbh->{schema_rows},
            map { $_ => $dbh->{$_} }
                qw(requests loans renewals events native_issues)
        },
        $before,
        'replay leaves canonical state and business data unchanged',
    );
};

subtest 'unsupported schema state fails closed and rolls back stamp' => sub {
    my $invalid = {
        schema_version => 2,
        plugin_version => '0.2.2',
        migration_name => '001_initial_schema',
        checksum       => '69bcf09d56f99afe',
    };
    my $dbh = Local::PluginUpgradeDBH->new(
        existing_tables => 1,
        schema_rows     => [$invalid],
        business_data(),
    );
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= join '', @_ };
        ok !run_with_dbh( 'upgrade', $dbh ), 'unsupported schema fails';
    }
    is_deeply $dbh->{schema_rows}, [$invalid],
        'failed verification rolls back partial version stamp';
    ok grep( $_ eq 'rollback', @{ $dbh->{calls} } ), 'rollback is invoked';
    like $warning, qr/PLUGIN_SCHEMA_UNAVAILABLE/, 'failure is reported safely';
};

subtest 'version-stamp write failure rolls back and never verifies success' => sub {
    my $dbh = Local::PluginUpgradeDBH->new(
        existing_tables => 1,
        schema_rows     => [ expected_state('0.2.2') ],
        stamp_error     => 'simulated version stamp failure',
        business_data(),
    );
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= join '', @_ };
        ok !run_with_dbh( 'upgrade', $dbh ), 'stamp write failure fails upgrade';
    }
    is_deeply $dbh->{schema_rows}, [ expected_state('0.2.2') ],
        'failed write leaves prior stamp intact';
    ok grep( $_ eq 'rollback', @{ $dbh->{calls} } ), 'write failure rolls back';
    ok !grep( /WHERE schema_version = \? AND plugin_version = \?/,
        @{ $dbh->{calls} } ), 'verification is not falsely reached';
    like $warning, qr/PLUGIN_SCHEMA_UNAVAILABLE/, 'failure is reported safely';
};

open my $source_fh, '<',
    'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation.pm'
    or die $!;
my $source = do { local $/; <$source_fh> };
unlike $source, qr/\b(?:AddIssue|AddReturn)\b/,
    'upgrade source contains no native circulation API mutation';
unlike $source, qr/\b(?:INSERT|UPDATE|DELETE)\s+(?:INTO\s+)?`?(?:issues|old_issues)\b/i,
    'upgrade source contains no native issues DML';

done_testing;
