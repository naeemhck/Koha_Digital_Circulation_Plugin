package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::RequestDecisionService;

use Modern::Perl;

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::StateMachine qw(can_transition);

use constant MAX_REASON_LENGTH => 4096;

my @SAFE_REQUEST_FIELDS = qw(
    request_id portal_request_id source patron_id biblio_id status requested_at
    approved_at approved_by rejected_at rejected_by rejection_reason cancelled_at
    created_at updated_at row_version
);

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
        state_machine => $args{state_machine} || \&can_transition,
        clock         => $args{clock} || \&_koha_now,
        json_encoder  => $args{json_encoder} || \&_canonical_json,
        diagnostic    => $args{diagnostic} || sub { return },
    }, $class;
}

sub decide_request {
    my ( $self, %args ) = @_;
    my $validation = $self->validate_command(%args);
    return $validation unless $validation->{ok};

    my $dbh;
    my $dbh_ok = eval {
        $dbh = $self->{dbh} || _koha_dbh();
        1;
    };
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE')
        unless $dbh_ok && $dbh;

    my $decision            = $validation->{decision};
    my $reason              = $validation->{reason};
    my $target_status       = $decision eq 'APPROVE' ? 'APPROVED' : 'REJECTED';
    my $request_repository  = $self->{request_repository};
    my $event_repository    = $self->{event_repository};
    my $transaction_started = 0;
    my ( $result, $classified_failure, $failure );

    eval {
        $dbh->begin_work;
        $transaction_started = 1;

        my $request = $request_repository->get_for_decision(
            $dbh,
            0 + $args{request_id}
        );
        unless ($request) {
            $classified_failure = _failure('REQUEST_NOT_FOUND');
            die "CLASSIFIED_DECISION_FAILURE\n";
        }

        my $current_status = $request->{status};
        unless ( defined $current_status && !ref($current_status) ) {
            $classified_failure = _failure('INVALID_STATE');
            die "CLASSIFIED_DECISION_FAILURE\n";
        }
        if ( $current_status eq 'APPROVED' || $current_status eq 'REJECTED' ) {
            $classified_failure = _failure('REQUEST_ALREADY_DECIDED');
            die "CLASSIFIED_DECISION_FAILURE\n";
        }
        unless ( $current_status eq 'PENDING' ) {
            $classified_failure = _failure('INVALID_STATE');
            die "CLASSIFIED_DECISION_FAILURE\n";
        }

        unless (
            _positive_decimal( $request->{row_version} )
            && 0 + $request->{row_version}
            == 0 + $args{expected_row_version}
            )
        {
            $classified_failure = _failure('VERSION_CONFLICT');
            die "CLASSIFIED_DECISION_FAILURE\n";
        }

        my $transition_allowed = eval {
            _can_transition(
                $self->{state_machine},
                'request',
                $current_status,
                $target_status
            );
        };
        die 'STATE_MACHINE_UNAVAILABLE' if $@;
        unless ($transition_allowed) {
            $classified_failure = _failure('INVALID_STATE');
            die "CLASSIFIED_DECISION_FAILURE\n";
        }

        my $decided_at;
        my $clock_ok = eval {
            $decided_at = $self->{clock}->();
            1;
        };
        die 'CLOCK_UNAVAILABLE'
            unless $clock_ok
            && defined $decided_at
            && !ref($decided_at)
            && $decided_at =~ /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/;

        my $affected = $request_repository->update_pending_decision(
            $dbh,
            request_id          => 0 + $args{request_id},
            expected_row_version => 0 + $args{expected_row_version},
            decision            => $decision,
            status              => $target_status,
            actor_id            => 0 + $args{actor_id},
            decided_at          => $decided_at,
            reason              => $reason,
        );

        unless ( defined $affected && !ref($affected) && $affected == 1 ) {
            if ( defined $affected && !ref($affected) && $affected == 0 ) {
                my $authoritative = $request_repository->get_by_id(
                    $dbh,
                    0 + $args{request_id}
                );
                $classified_failure = _classify_guard_failure(
                    $authoritative,
                    0 + $args{expected_row_version}
                );
                die "CLASSIFIED_DECISION_FAILURE\n";
            }
            die 'GUARDED_REQUEST_UPDATE_FAILED';
        }

        my $updated = $request_repository->get_by_id(
            $dbh,
            0 + $args{request_id}
        );
        die 'UPDATED_REQUEST_UNAVAILABLE'
            unless _valid_updated_request(
            $updated,
            decision             => $decision,
            target_status        => $target_status,
            actor_id             => 0 + $args{actor_id},
            decided_at           => $decided_at,
            reason               => $reason,
            expected_row_version => 0 + $args{expected_row_version},
            );

        my $payload = {
            actor_id          => 0 + $args{actor_id},
            biblio_id         => 0 + $request->{biblio_id},
            new_status        => $target_status,
            portal_request_id => $request->{portal_request_id},
            previous_status   => 'PENDING',
            request_id        => 0 + $args{request_id},
            source            => 'STAFF',
            subject_patron_id => 0 + $request->{patron_id},
        };
        if ( defined $reason ) {
            my $reason_field =
                $decision eq 'REJECT' ? 'rejection_reason' : 'decision_reason';
            $payload->{$reason_field} = $reason;
        }

        my $payload_json;
        my $payload_ok = eval {
            $payload_json = $self->{json_encoder}->($payload);
            1;
        };
        die 'EVENT_PAYLOAD_ENCODING_FAILED'
            unless $payload_ok
            && defined $payload_json
            && !ref($payload_json);

        my %event = (
            aggregate_type    => 'REQUEST',
            aggregate_id      => 0 + $args{request_id},
            request_id        => 0 + $args{request_id},
            loan_id           => undef,
            renewal_id        => undef,
            patron_id         => 0 + $request->{patron_id},
            biblio_id         => 0 + $request->{biblio_id},
            actor_patron_id   => 0 + $args{actor_id},
            source            => 'STAFF',
            correlation_id    => $args{correlation_id},
            occurred_at       => $decided_at,
            payload_json      => $payload_json,
            delivery_status   => 'NOT_REQUIRED',
            delivery_attempts => 0,
        );
        if ( $decision eq 'APPROVE' ) {
            $event_repository->insert_request_approved_event( $dbh, %event );
        }
        else {
            $event_repository->insert_request_rejected_event( $dbh, %event );
        }

        my $safe_request = _safe_request($updated);
        die 'UPDATED_REQUEST_NORMALIZATION_FAILED' unless $safe_request;

        $result = {
            ok                   => 1,
            outcome              => $target_status,
            request              => $safe_request,
            previous_status      => 'PENDING',
            new_status           => $target_status,
            previous_row_version => 0 + $args{expected_row_version},
            row_version          => 0 + $updated->{row_version},
            correlation_id       => $args{correlation_id},
        };

        $dbh->commit;
        $transaction_started = 0;
        1;
    } or $failure = $@ || 'DECISION_TRANSACTION_FAILED';

    if ($failure) {
        eval { $dbh->rollback if $transaction_started };
        return $classified_failure if $classified_failure;
        eval { $self->{diagnostic}->('REQUEST_DECISION_TRANSACTION_FAILED') };
        return _failure(
            $failure =~ /\A(?:CLOCK_UNAVAILABLE|EVENT_PAYLOAD_ENCODING_FAILED|STATE_MACHINE_UNAVAILABLE)/
            ? 'INTERNAL_ERROR'
            : 'DIGITAL_CIRCULATION_UNAVAILABLE'
        );
    }

    return $result;
}

sub validate_command {
    my ( $self, %args ) = @_;
    return _validate_command( \%args );
}

sub _validate_command {
    my ($args) = @_;
    for my $field (qw(actor_id request_id expected_row_version)) {
        return _failure('INVALID_INPUT')
            unless _positive_decimal( $args->{$field} );
    }

    return _failure('INVALID_DECISION')
        unless defined $args->{decision}
        && !ref( $args->{decision} )
        && ( $args->{decision} eq 'APPROVE' || $args->{decision} eq 'REJECT' );

    return _failure('INVALID_INPUT')
        unless _uuid( $args->{correlation_id} );

    my $reason = $args->{reason};
    return _failure('INVALID_REASON') if defined $reason && ref($reason);
    if ( defined $reason ) {
        return _failure('INVALID_REASON')
            if length($reason) > MAX_REASON_LENGTH
            || $reason =~ /[\x00-\x1f\x7f]/
            || $reason =~ /[<>]/
            || $reason =~ /\b(?:javascript|vbscript)\s*:/i
            || $reason =~ /\bdata\s*:\s*text\/html/i;
        $reason = undef if $reason =~ /\A *\z/;
    }
    return _failure('INVALID_REASON')
        if $args->{decision} eq 'REJECT' && !defined $reason;

    return {
        ok       => 1,
        decision => $args->{decision},
        reason   => $reason,
    };
}

sub _classify_guard_failure {
    my ( $request, $expected_row_version ) = @_;
    return _failure('REQUEST_NOT_FOUND') unless $request;
    my $status = $request->{status};
    return _failure('REQUEST_ALREADY_DECIDED')
        if defined $status
        && !ref($status)
        && ( $status eq 'APPROVED' || $status eq 'REJECTED' );
    return _failure('VERSION_CONFLICT')
        if _positive_decimal( $request->{row_version} )
        && 0 + $request->{row_version} != $expected_row_version;
    return _failure('INVALID_STATE')
        unless defined $status && !ref($status) && $status eq 'PENDING';
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE');
}

sub _valid_updated_request {
    my ( $request, %expected ) = @_;
    return unless ref($request) eq 'HASH';
    return unless _positive_decimal( $request->{request_id} );
    return unless ( $request->{status} // '' ) eq $expected{target_status};
    return unless _positive_decimal( $request->{row_version} );
    return
        unless 0 + $request->{row_version}
        == $expected{expected_row_version} + 1;

    if ( $expected{decision} eq 'APPROVE' ) {
        return
            ( $request->{approved_at} // '' ) eq $expected{decided_at}
            && _positive_decimal( $request->{approved_by} )
            && 0 + $request->{approved_by} == $expected{actor_id}
            && !defined $request->{rejected_at}
            && !defined $request->{rejected_by};
    }

    return
        ( $request->{rejected_at} // '' ) eq $expected{decided_at}
        && _positive_decimal( $request->{rejected_by} )
        && 0 + $request->{rejected_by} == $expected{actor_id}
        && ( $request->{rejection_reason} // '' ) eq $expected{reason}
        && !defined $request->{approved_at}
        && !defined $request->{approved_by};
}

sub _safe_request {
    my ($request) = @_;
    return unless ref($request) eq 'HASH';
    for my $required (
        qw(
        request_id portal_request_id source patron_id biblio_id status requested_at
        row_version
        )
        )
    {
        return unless exists $request->{$required};
    }
    return unless _positive_decimal( $request->{request_id} );
    return unless _uuid( $request->{portal_request_id} );
    return unless ( $request->{source} // '' ) eq 'PORTAL';
    return unless _positive_decimal( $request->{patron_id} );
    return unless _positive_decimal( $request->{biblio_id} );
    return
        unless ( $request->{status} // '' )
        =~ /\A(?:APPROVED|REJECTED)\z/;
    return unless _positive_decimal( $request->{row_version} );

    my $safe = { map { $_ => $request->{$_} } @SAFE_REQUEST_FIELDS };
    for my $numeric (qw(request_id patron_id biblio_id row_version)) {
        $safe->{$numeric} = 0 + $safe->{$numeric};
    }
    for my $actor (qw(approved_by rejected_by)) {
        next unless defined $safe->{$actor};
        return unless _positive_decimal( $safe->{$actor} );
        $safe->{$actor} = 0 + $safe->{$actor};
    }
    return $safe;
}

sub _can_transition {
    my ( $state_machine, @transition ) = @_;
    return $state_machine->(@transition)
        if ref($state_machine) eq 'CODE';
    return $state_machine->can_transition(@transition)
        if ref($state_machine) && $state_machine->can('can_transition');
    die 'STATE_MACHINE_UNAVAILABLE';
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

sub _failure {
    my ($code) = @_;
    return {
        ok   => 0,
        code => $code,
    };
}

1;
