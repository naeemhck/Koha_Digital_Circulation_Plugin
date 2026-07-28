package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LifecyclePolicy;

use Modern::Perl;
use Scalar::Util qw(blessed);

my %DEFAULT = (
    renewals_enabled         => 0,
    staff_revocations_enabled => 0,
    automatic_expiry_enabled => 0,
    renewal_days             => 14,
    maximum_renewals         => 2,
    expiry_batch_size        => 100,
);

sub new {
    my ( $class, %args ) = @_;
    return bless { plugin => $args{plugin} }, $class;
}

sub defaults {
    return { %DEFAULT };
}

sub load_config {
    my ($self) = @_;
    my $plugin = $self->{plugin};
    return { loaded => 0, settings => { %DEFAULT } }
        unless blessed($plugin) && $plugin->can('retrieve_data');

    my %settings;
    for my $key ( keys %DEFAULT ) {
        my $value;
        my $ok = eval {
            $value = $plugin->retrieve_data($key);
            1;
        };
        return { loaded => 0, settings => { %DEFAULT } } unless $ok;
        if ( $key =~ /_enabled\z/ ) {
            $settings{$key} =
                !defined($value) || $value eq '' ? $DEFAULT{$key}
                : $value eq '1'                 ? 1
                : $value eq '0'                 ? 0
                :                                0;
        }
        else {
            my ( $min, $max ) =
                $key eq 'maximum_renewals'  ? ( 0, 100 )
                : $key eq 'expiry_batch_size' ? ( 1, 500 )
                :                              ( 1, 365 );
            $settings{$key} =
                defined($value)
                && !ref($value)
                && $value =~ /\A[0-9]+\z/
                && $value >= $min
                && $value <= $max
                ? 0 + $value
                : $DEFAULT{$key};
        }
    }
    return { loaded => 1, settings => \%settings };
}

sub store_config {
    my ( $self, %input ) = @_;
    my $plugin = $self->{plugin};
    return { stored => 0, code => 'CONFIGURATION_UNAVAILABLE' }
        unless blessed($plugin) && $plugin->can('store_data');

    my %canonical;
    for my $key (qw(renewals_enabled staff_revocations_enabled automatic_expiry_enabled)) {
        my $value = $input{$key};
        return { stored => 0, code => 'INVALID_LIFECYCLE_CONFIGURATION' }
            unless defined($value) && !ref($value) && $value =~ /\A(?:0|1)\z/;
        $canonical{$key} = $value;
    }
    for my $spec (
        [ renewal_days      => 1, 365 ],
        [ maximum_renewals  => 0, 100 ],
        [ expiry_batch_size => 1, 500 ],
      )
    {
        my ( $key, $min, $max ) = @{$spec};
        my $value = $input{$key};
        return { stored => 0, code => 'INVALID_LIFECYCLE_CONFIGURATION' }
            unless defined($value)
            && !ref($value)
            && $value =~ /\A[0-9]+\z/
            && $value >= $min
            && $value <= $max;
        $canonical{$key} = "$value";
    }

    my $ok = eval {
        $plugin->store_data( \%canonical );
        1;
    };
    return $ok
        ? { stored => 1, settings => { map { $_ => 0 + $canonical{$_} } keys %canonical } }
        : { stored => 0, code => 'CONFIGURATION_UNAVAILABLE' };
}

1;
