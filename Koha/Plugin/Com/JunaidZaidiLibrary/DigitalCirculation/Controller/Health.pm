package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Health;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(true false);
use C4::Context;
use Koha;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LifecyclePolicy;

sub _lifecycle {
    my $plugin = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    my $result = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LifecyclePolicy->new(
        plugin => $plugin
    )->load_config;
    my $settings = $result->{settings}
        || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LifecyclePolicy->defaults;
    return {
        configuration_available => $result->{loaded} ? true : false,
        renewals_enabled => $settings->{renewals_enabled} ? true : false,
        staff_revocations_enabled => $settings->{staff_revocations_enabled} ? true : false,
        automatic_expiry_enabled => $settings->{automatic_expiry_enabled} ? true : false,
        renewal_days => 0 + $settings->{renewal_days},
        maximum_renewals => 0 + $settings->{maximum_renewals},
        expiry_batch_size => 0 + $settings->{expiry_batch_size},
    };
}

sub health {
    my ($c) = @_;
    my $db = eval { C4::Context->dbh->selectrow_array('SELECT 1') };
    return $c->render(
        status => $db ? 200 : 503,
        json => {
            loaded => true,
            plugin_version => '0.4.4',
            schema_version => 1,
            database => $db ? 'available' : 'unavailable',
            koha_compatible => Koha->VERSION =~ /\A26\.05\./ ? true : false,
            read_only => false,
            current_utc => scalar(gmtime()) . 'Z',
            lifecycle => _lifecycle(),
        }
    );
}

sub version {
    my ($c) = @_;
    return $c->render(json => {
        plugin_version => '0.4.4',
        tested_koha_version => '26.05.01.000',
        minimum_koha_version => '26.05.00.000',
        schema_version => 1,
        api_version => 'v1',
        phase => '5',
        read_only => false,
        lifecycle => _lifecycle(),
    });
}

1;
