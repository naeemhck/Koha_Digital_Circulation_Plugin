package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestService;

use Modern::Perl;

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository;

sub new {
    my ( $class, %args ) = @_;
    my $table_resolver = $args{table_resolver} || \&_plugin_table;
    return bless {
        dbh                => $args{dbh},
        request_repository =>
            $args{request_repository}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository->new(
                table_name => $table_resolver->('requests')
            ),
        event_repository =>
            $args{event_repository}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository->new(
                table_name => $table_resolver->('events')
            ),
        clock              => $args{clock} || \&_koha_now,
        json_encoder       => $args{json_encoder} || \&_canonical_json,
        duplicate_detector => $args{duplicate_detector} || \&_is_duplicate_key_error,
        diagnostic         => $args{diagnostic} || sub { return },
    }, $class;
}

sub list {
    return shift->{request_repository}->list(@_);
}

sub get {
    return shift->{request_repository}->get(@_);
}

sub create_portal_request {
    my ( $self, %args ) = @_;
    my $validation = _validate_command( \%args );
    return $validation unless $validation->{ok};

    my $dbh;
    my $dbh_ok = eval {
        $dbh = $self->{dbh} || _koha_dbh();
        1;
    };
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE')
        unless $dbh_ok && $dbh;

    my $request_repository = $self->{request_repository};
    my $event_repository   = $self->{event_repository};
    my $result;
    my $transaction_started = 0;
    my $failure;

    eval {
        $dbh->begin_work;
        $transaction_started = 1;

        $result = $self->_classify_existing( $dbh, \%args );

        unless ($result) {
            my $requested_at = $self->{clock}->();
            die 'CLOCK_UNAVAILABLE'
                unless defined $requested_at
                && !ref($requested_at)
                && $requested_at =~ /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/;

            my $request;
            my $insert_ok = eval {
                $request = $request_repository->insert_pending_request(
                    $dbh,
                    portal_request_id => $args{portal_request_id},
                    idempotency_key   => $args{idempotency_key},
                    source            => 'PORTAL',
                    patron_id         => 0 + $args{patron_id},
                    biblio_id         => 0 + $args{biblio_id},
                    status            => 'PENDING',
                    requested_at      => $requested_at,
                    row_version       => 1,
                );
                1;
            };

            unless ($insert_ok) {
                my $insert_error = $@ || 'REQUEST_INSERT_FAILED';
                if ( $self->{duplicate_detector}->( $insert_error, $dbh ) ) {
                    $result = $self->_classify_existing(
                        $dbh,
                        \%args,
                        for_update => 1
                    );
                    die 'DUPLICATE_REQUEST_UNCLASSIFIED' unless $result;
                }
                else {
                    die $insert_error;
                }
            }

            unless ($result) {
                die 'REQUEST_INSERT_RESULT_INVALID'
                    unless ref($request) eq 'HASH'
                    && _positive_decimal( $request->{request_id} );

                my $payload = {
                    actor_id          => 0 + $args{actor_id},
                    biblio_id         => 0 + $args{biblio_id},
                    new_status        => 'PENDING',
                    portal_request_id => $args{portal_request_id},
                    previous_status   => undef,
                    request_id        => 0 + $request->{request_id},
                    source            => 'PORTAL',
                    subject_patron_id => 0 + $args{patron_id},
                };
                my $payload_json = $self->{json_encoder}->($payload);
                die 'EVENT_PAYLOAD_ENCODING_FAILED'
                    unless defined $payload_json && !ref($payload_json);

                $event_repository->insert_request_created_event(
                    $dbh,
                    event_type       => 'REQUEST_CREATED',
                    aggregate_type   => 'REQUEST',
                    aggregate_id     => 0 + $request->{request_id},
                    request_id       => 0 + $request->{request_id},
                    loan_id          => undef,
                    renewal_id       => undef,
                    patron_id        => 0 + $args{patron_id},
                    biblio_id        => 0 + $args{biblio_id},
                    actor_patron_id  => 0 + $args{actor_id},
                    source           => 'PORTAL',
                    correlation_id   => $args{correlation_id},
                    occurred_at      => $requested_at,
                    payload_json     => $payload_json,
                    delivery_status  => 'NOT_REQUIRED',
                    delivery_attempts => 0,
                );

                $result = {
                    ok                => 1,
                    outcome           => 'CREATED',
                    request           => $request,
                    idempotent_replay => 0,
                    duplicate_pending => 0,
                    correlation_id    => $args{correlation_id},
                };
            }
        }

        $dbh->commit;
        $transaction_started = 0;
        1;
    } or $failure = $@ || 'TRANSACTION_FAILED';

    if ($failure) {
        $self->{last_error} = $failure;
        eval { $dbh->rollback if $transaction_started };
        eval { $self->{diagnostic}->('REQUEST_TRANSACTION_FAILED') };
        return _failure('DIGITAL_CIRCULATION_UNAVAILABLE');
    }

    return $result;
}

sub _classify_existing {
    my ( $self, $dbh, $args, %options ) = @_;
    my $repository = $self->{request_repository};

    my $by_idempotency = $repository->find_by_idempotency_key(
        $dbh,
        $args->{idempotency_key},
        for_update => $options{for_update}
    );
    if ($by_idempotency) {
        return _failure('IDEMPOTENCY_CONFLICT')
            unless _same_effective_request( $by_idempotency, $args );
        return {
            ok                => 1,
            outcome           => 'IDEMPOTENT_REPLAY',
            request           => $by_idempotency,
            idempotent_replay => 1,
            duplicate_pending => 0,
            correlation_id    => $args->{correlation_id},
        };
    }

    my $pending = $repository->find_pending_by_patron_and_biblio(
        $dbh,
        $args->{patron_id},
        $args->{biblio_id},
        for_update => $options{for_update}
    );
    return unless $pending;
    return {
        ok                => 1,
        outcome           => 'DUPLICATE_PENDING',
        request           => $pending,
        idempotent_replay => 0,
        duplicate_pending => 1,
        correlation_id    => $args->{correlation_id},
    };
}

sub _same_effective_request {
    my ( $request, $args ) = @_;
    return
        ( $request->{portal_request_id} // '' ) eq $args->{portal_request_id}
        && _positive_decimal( $request->{patron_id} )
        && 0 + $request->{patron_id} == 0 + $args->{patron_id}
        && _positive_decimal( $request->{biblio_id} )
        && 0 + $request->{biblio_id} == 0 + $args->{biblio_id}
        && ( $request->{source} // '' ) eq 'PORTAL';
}

sub _validate_command {
    my ($args) = @_;
    for my $field (qw(actor_id patron_id biblio_id)) {
        return _failure('INVALID_INPUT')
            unless _positive_decimal( $args->{$field} );
    }
    return _failure('INVALID_INPUT')
        unless _uuid( $args->{portal_request_id} );
    return _failure('INVALID_IDEMPOTENCY_KEY')
        unless _uuid( $args->{idempotency_key} );
    return _failure('INVALID_INPUT')
        unless _uuid( $args->{correlation_id} );
    return _failure('INVALID_INPUT')
        unless defined $args->{source}
        && !ref( $args->{source} )
        && $args->{source} eq 'PORTAL';
    return { ok => 1 };
}

sub _positive_decimal {
    my ($value) = @_;
    return defined $value && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
}

sub _uuid {
    my ($value) = @_;
    return defined $value
        && !ref($value)
        && $value =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i;
}

sub _koha_dbh {
    require C4::Context;
    return C4::Context->dbh;
}

sub _plugin_table {
    my ($name) = @_;
    require Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    my $plugin =
        bless {},
        'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation';
    return $plugin->table($name);
}

sub _koha_now {
    require Koha::DateUtils;
    return Koha::DateUtils::dt_from_string()->strftime('%Y-%m-%d %H:%M:%S');
}

sub _canonical_json {
    my ($payload) = @_;
    require JSON::PP;
    return JSON::PP->new->canonical(1)->utf8(1)->encode($payload);
}

sub _is_duplicate_key_error {
    my ( $error, $dbh ) = @_;
    my $driver_code = eval { $dbh->err };
    return 1 if defined $driver_code && $driver_code == 1062;
    my $message = defined $error ? "$error" : '';
    return $message =~ /\b(?:duplicate entry|unique constraint failed)\b/i ? 1 : 0;
}

sub _failure {
    my ($code) = @_;
    return {
        ok   => 0,
        code => $code,
    };
}

1;
