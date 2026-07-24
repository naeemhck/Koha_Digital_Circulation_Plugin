package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::ConfiguredLoanPeriodPolicy;

use Modern::Perl;
use Scalar::Util qw(blessed);

use constant CONFIG_KEY => 'default_loan_duration_days';
use constant MIN_DAYS   => 1;
use constant MAX_DAYS   => 365;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        plugin      => $args{plugin},
        diagnostic  => $args{diagnostic} || sub { return },
        config_reader => $args{config_reader},
        date_adder  => $args{date_adder} || \&_add_calendar_days,
    }, $class;
}

sub config_key {
    return CONFIG_KEY;
}

sub min_days {
    return MIN_DAYS;
}

sub max_days {
    return MAX_DAYS;
}

sub resolve_due_at {
    my ( $self, %ctx ) = @_;

    unless ( _timestamp( $ctx{started_at} ) ) {
        $self->_diagnose('loan_due_date_calculation_failed');
        return _failure();
    }

    my $days = $self->_configured_days;
    return _failure() unless defined $days;

    my $due_at;
    my $ok = eval {
        $due_at = $self->{date_adder}->( $ctx{started_at}, $days );
        1;
    };
    unless ( $ok && _timestamp($due_at) && $due_at gt $ctx{started_at} ) {
        $self->_diagnose('loan_due_date_calculation_failed');
        return _failure();
    }

    return {
        ok     => 1,
        due_at => $due_at,
    };
}

sub load_config {
    my ($self) = @_;
    my $raw = $self->_read_raw;
    return {
        loaded   => 0,
        code     => 'LOAN_DURATION_CONFIGURATION_UNAVAILABLE',
    } unless defined $raw->{ok};

    return {
        loaded   => 1,
        value    => '',
        disabled => 1,
        code     => undef,
    } if $raw->{ok} && !defined $raw->{value};

    return {
        loaded => 0,
        code   => 'LOAN_DURATION_CONFIGURATION_UNAVAILABLE',
    } unless $raw->{ok};

    my $value = $raw->{value};
    return {
        loaded   => 1,
        value    => '',
        disabled => 1,
        code     => undef,
    } unless defined $value;
    return {
        loaded => 0,
        code   => 'LOAN_DURATION_CONFIGURATION_UNAVAILABLE',
    } if ref $value;

    return {
        loaded   => 1,
        value    => '',
        disabled => 1,
        code     => undef,
    } unless $value =~ /\S/;

    my $parsed = _parse_days($value);
    return {
        loaded => 0,
        code   => 'LOAN_DURATION_CONFIGURATION_UNAVAILABLE',
    } unless defined $parsed;

    return {
        loaded   => 1,
        value    => "$parsed",
        disabled => 0,
        code     => undef,
    };
}

sub store_config {
    my ( $self, $raw ) = @_;
    return {
        stored   => 0,
        disabled => 0,
        code     => 'INVALID_LOAN_DURATION',
    } unless defined $raw && !ref($raw);

    my $trimmed = $raw;
    $trimmed =~ s/\A\s+|\s+\z//g;
    if ( !length $trimmed ) {
        return $self->_store_canonical( '', 1 );
    }

    my $parsed = _parse_days($trimmed);
    return {
        stored   => 0,
        disabled => 0,
        code     => 'INVALID_LOAN_DURATION',
    } unless defined $parsed;

    return $self->_store_canonical( "$parsed", 0 );
}

sub _configured_days {
    my ($self) = @_;
    my $raw = $self->_read_raw;
    unless ( $raw->{ok} ) {
        $self->_diagnose('loan_policy_configuration_error');
        return;
    }
    unless ( defined $raw->{value} && !ref( $raw->{value} ) && $raw->{value} =~ /\S/ )
    {
        $self->_diagnose('loan_duration_missing');
        return;
    }

    my $parsed = _parse_days( $raw->{value} );
    unless (defined $parsed) {
        if ( defined $raw->{value}
            && !ref( $raw->{value} )
            && $raw->{value} =~ /\A\s*[1-9][0-9]*\s*\z/
            && 0 + $raw->{value} > MAX_DAYS )
        {
            $self->_diagnose('loan_duration_out_of_range');
        }
        else {
            $self->_diagnose('loan_duration_invalid');
        }
        return;
    }
    return $parsed;
}

sub _read_raw {
    my ($self) = @_;
    if ( ref( $self->{config_reader} ) eq 'CODE' ) {
        my $value;
        my $ok = eval {
            $value = $self->{config_reader}->();
            1;
        };
        return { ok => 0 } unless $ok;
        return { ok => 1, value => $value };
    }

    my $plugin = $self->{plugin};
    return { ok => 0 }
        unless blessed($plugin) && $plugin->can('retrieve_data');

    my $value;
    my $ok = eval {
        $value = $plugin->retrieve_data(CONFIG_KEY);
        1;
    };
    return { ok => 0 } unless $ok;
    return { ok => 1, value => $value };
}

sub _store_canonical {
    my ( $self, $canonical, $disabled ) = @_;
    my $plugin = $self->{plugin};
    return {
        stored   => 0,
        disabled => 0,
        code     => 'LOAN_DURATION_CONFIGURATION_UNAVAILABLE',
    } unless blessed($plugin) && $plugin->can('store_data');

    my $stored = eval {
        $plugin->store_data( { CONFIG_KEY() => $canonical } );
        1;
    };
    return {
        stored   => 0,
        disabled => 0,
        code     => 'LOAN_DURATION_CONFIGURATION_UNAVAILABLE',
    } unless $stored;

    return {
        stored   => 1,
        disabled => $disabled ? 1 : 0,
        code     => undef,
    };
}

sub _parse_days {
    my ($raw) = @_;
    return unless defined $raw && !ref($raw);
    return unless $raw =~ /\A[1-9][0-9]*\z/;
    my $days = 0 + $raw;
    return unless $days >= MIN_DAYS && $days <= MAX_DAYS;
    return $days;
}

sub _add_calendar_days {
    my ( $started_at, $days ) = @_;
    return unless _timestamp($started_at);
    return unless defined $days && $days =~ /\A[1-9][0-9]*\z/;

    my ( $date, $time ) = split / /, $started_at, 2;
    my ( $year, $month, $day ) = split /-/, $date;
    my ( $hour, $min, $sec ) = split /:/, $time;

    require Time::Local;
    my $epoch = eval {
        Time::Local::timegm_modern( 0, 0, 12, $day, $month - 1, $year );
    };
    return unless defined $epoch;
    $epoch += ( 0 + $days ) * 86400;
    my ( undef, undef, undef, $new_day, $new_month, $new_year ) =
        ( gmtime($epoch) )[ 0 .. 5 ];
    return sprintf(
        '%04d-%02d-%02d %02d:%02d:%02d',
        $new_year + 1900,
        $new_month + 1,
        $new_day,
        $hour, $min, $sec
    );
}

sub _timestamp {
    my ($value) = @_;
    return defined $value
        && !ref($value)
        && $value =~ /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/;
}

sub _diagnose {
    my ( $self, $category ) = @_;
    eval { $self->{diagnostic}->($category) };
    return;
}

sub _failure {
    return {
        ok   => 0,
        code => 'INVALID_LOAN_PERIOD',
    };
}

1;
