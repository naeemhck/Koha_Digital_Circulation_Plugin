package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanReturnService;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository;

use constant ACTIVE_STATUS   => 'ACTIVE';
use constant RETURNED_STATUS => 'RETURNED';

my @SAFE_LOAN_FIELDS = qw(
    loan_id request_id portal_request_id patron_id biblio_id status
    started_at due_at returned_at revoked_at expired_at
    renewal_count row_version created_at updated_at
);

sub new {
    my ( $class, %args ) = @_;
    my $table_resolver = $args{table_resolver} || \&_plugin_table;
    return bless {
        dbh => $args{dbh},
        loan_repository =>
            $args{loan_repository}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository->new(
                table_name         => $table_resolver->('loans'),
                request_table_name => $table_resolver->('requests'),
            ),
        event_repository =>
            $args{event_repository}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository->new(
                table_name => $table_resolver->('events')
            ),
        clock          => $args{clock}          || \&_koha_now,
        uuid_generator => $args{uuid_generator} || \&_random_uuid,
        json_encoder   => $args{json_encoder}   || \&_canonical_json,
        diagnostic     => $args{diagnostic}     || sub { return },
    }, $class;
}

sub return_loan {
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

    my $loan_id              = 0 + $args{loan_id};
    my $patron_id            = 0 + $args{patron_id};
    my $portal_request_id    = $validation->{portal_request_id};
    my $expected_row_version = 0 + $args{expected_row_version};
    my $actor_id             = 0 + $args{actor_id};
    my $correlation_id       = $validation->{correlation_id};
    my $loan_repository      = $self->{loan_repository};
    my $event_repository     = $self->{event_repository};
    my $transaction_started  = 0;
    my ( $result, $classified_failure, $failure );

    eval {
        $dbh->begin_work;
        $transaction_started = 1;

        my $loan = $loan_repository->get_for_return(
            $dbh,
            $loan_id,
            for_update => 1
        );
        unless ($loan) {
            eval { $self->{diagnostic}->('loan_not_found') };
            $classified_failure = _failure('LOAN_NOT_FOUND');
            die "CLASSIFIED_LOAN_RETURN_FAILURE\n";
        }

        my $correlation_failure = _correlation_failure(
            $loan,
            patron_id         => $patron_id,
            portal_request_id => $portal_request_id,
        );
        if ($correlation_failure) {
            eval { $self->{diagnostic}->('loan_correlation_mismatch') };
            $classified_failure = $correlation_failure;
            die "CLASSIFIED_LOAN_RETURN_FAILURE\n";
        }

        my $status = $loan->{status} // '';
        if ( $status eq RETURNED_STATUS ) {
            my $safe = _safe_loan($loan);
            die 'LOAN_NORMALIZATION_FAILED' unless $safe;
            $result = {
                ok                => 1,
                loan              => $safe,
                correlation_id    => $correlation_id,
                idempotent_replay => 1,
            };
            $dbh->commit;
            $transaction_started = 0;
            return 1;
        }

        if ( $status eq 'REVOKED' || $status eq 'EXPIRED' ) {
            eval { $self->{diagnostic}->('loan_not_returnable') };
            $classified_failure = _failure('LOAN_NOT_RETURNABLE');
            die "CLASSIFIED_LOAN_RETURN_FAILURE\n";
        }

        unless ( $status eq ACTIVE_STATUS ) {
            eval { $self->{diagnostic}->('loan_not_returnable') };
            $classified_failure = _failure('LOAN_NOT_RETURNABLE');
            die "CLASSIFIED_LOAN_RETURN_FAILURE\n";
        }

        unless ( _positive_decimal( $loan->{row_version} )
            && 0 + $loan->{row_version} == $expected_row_version )
        {
            eval { $self->{diagnostic}->('version_conflict') };
            $classified_failure = _failure('VERSION_CONFLICT');
            die "CLASSIFIED_LOAN_RETURN_FAILURE\n";
        }

        my $returned_at;
        my $clock_ok = eval {
            $returned_at = $self->{clock}->();
            1;
        };
        die 'CLOCK_UNAVAILABLE'
            unless $clock_ok
            && _timestamp($returned_at);

        my $updated = $loan_repository->update_active_return(
            $dbh,
            loan_id              => $loan_id,
            expected_row_version => $expected_row_version,
            returned_at          => $returned_at,
        );
        unless ($updated) {
            my $again = $loan_repository->get_for_return(
                $dbh,
                $loan_id,
                for_update => 1
            );
            if ( $again
                && ( $again->{status} // '' ) eq RETURNED_STATUS
                && !_correlation_failure(
                    $again,
                    patron_id         => $patron_id,
                    portal_request_id => $portal_request_id,
                )
              )
            {
                my $safe = _safe_loan($again);
                die 'LOAN_NORMALIZATION_FAILED' unless $safe;
                $result = {
                    ok                => 1,
                    loan              => $safe,
                    correlation_id    => $correlation_id,
                    idempotent_replay => 1,
                };
                $dbh->commit;
                $transaction_started = 0;
                return 1;
            }
            eval { $self->{diagnostic}->('version_conflict') };
            $classified_failure = _failure('VERSION_CONFLICT');
            die "CLASSIFIED_LOAN_RETURN_FAILURE\n";
        }

        my $fresh = $loan_repository->get_for_return( $dbh, $loan_id );
        die 'LOAN_RETURN_RESULT_INVALID'
            unless _valid_returned_loan(
            $fresh,
            loan_id           => $loan_id,
            request_id        => 0 + $loan->{request_id},
            portal_request_id => $portal_request_id,
            patron_id         => $patron_id,
            biblio_id         => 0 + $loan->{biblio_id},
            started_at        => $loan->{started_at},
            due_at            => $loan->{due_at},
            returned_at       => $returned_at,
            prior_row_version => $expected_row_version,
            renewal_count     => $loan->{renewal_count},
            );

        my $payload = {
            actor_id             => $actor_id,
            biblio_id            => 0 + $fresh->{biblio_id},
            loan_id              => $loan_id,
            new_status           => RETURNED_STATUS,
            previous_status      => ACTIVE_STATUS,
            portal_request_id    => $portal_request_id,
            request_id           => 0 + $fresh->{request_id},
            returned_at          => $returned_at,
            source               => 'PORTAL',
            subject_patron_id    => $patron_id,
            expected_row_version => $expected_row_version,
            origin               => 'portal_patron_return',
        };
        my $payload_json;
        my $payload_ok = eval {
            $payload_json = $self->{json_encoder}->($payload);
            1;
        };
        die 'EVENT_PAYLOAD_ENCODING_FAILED'
            unless $payload_ok
            && defined $payload_json
            && !ref($payload_json);

        $event_repository->insert_loan_returned_event(
            $dbh,
            aggregate_type    => 'LOAN',
            aggregate_id      => $loan_id,
            request_id        => 0 + $fresh->{request_id},
            loan_id           => $loan_id,
            renewal_id        => undef,
            patron_id         => $patron_id,
            biblio_id         => 0 + $fresh->{biblio_id},
            actor_patron_id   => $actor_id,
            source            => 'PORTAL',
            correlation_id    => $correlation_id,
            occurred_at       => $returned_at,
            payload_json      => $payload_json,
            delivery_status   => 'NOT_REQUIRED',
            delivery_attempts => 0,
        );

        my $safe_loan = _safe_loan($fresh);
        die 'LOAN_NORMALIZATION_FAILED' unless $safe_loan;

        $result = {
            ok                => 1,
            loan              => $safe_loan,
            correlation_id    => $correlation_id,
            idempotent_replay => 0,
        };

        $dbh->commit;
        $transaction_started = 0;
        1;
    } or $failure = $@ || 'LOAN_RETURN_TRANSACTION_FAILED';

    if ($failure) {
        eval { $dbh->rollback if $transaction_started };
        return $classified_failure if $classified_failure;
        eval { $self->{diagnostic}->('transaction_failed') };
        return _failure(
            $failure =~ /\A(?:CLOCK_UNAVAILABLE|EVENT_PAYLOAD_ENCODING_FAILED|LOAN_NORMALIZATION_FAILED|LOAN_RETURN_RESULT_INVALID)/
            ? 'INTERNAL_ERROR'
            : 'DIGITAL_CIRCULATION_UNAVAILABLE'
        );
    }

    return $result;
}

sub validate_command {
    my ( $self, %args ) = @_;
    return _failure('INVALID_INPUT')
        unless _positive_decimal( $args{loan_id} )
        && _positive_decimal( $args{patron_id} )
        && _positive_decimal( $args{expected_row_version} )
        && _positive_decimal( $args{actor_id} )
        && _uuid( $args{portal_request_id} );

    my $correlation_id = $args{correlation_id};
    if ( defined $correlation_id ) {
        return _failure('INVALID_INPUT') unless _uuid($correlation_id);
    }
    else {
        my $generated;
        my $ok = eval {
            $generated = $self->{uuid_generator}->();
            1;
        };
        return _failure('INTERNAL_ERROR')
            unless $ok && _uuid($generated);
        $correlation_id = $generated;
    }

    return {
        ok                => 1,
        portal_request_id => lc $args{portal_request_id},
        correlation_id    => $correlation_id,
    };
}

sub _correlation_failure {
    my ( $loan, %expected ) = @_;
    return _failure('LOAN_CORRELATION_MISMATCH')
        unless ref($loan) eq 'HASH';
    return _failure('LOAN_CORRELATION_MISMATCH')
        unless _positive_decimal( $loan->{request_id} )
        && _positive_decimal( $loan->{joined_request_id} )
        && 0 + $loan->{request_id} == 0 + $loan->{joined_request_id};
    return _failure('LOAN_CORRELATION_MISMATCH')
        unless _uuid( $loan->{portal_request_id} )
        && lc( $loan->{portal_request_id} ) eq lc( $expected{portal_request_id} );
    return _failure('LOAN_CORRELATION_MISMATCH')
        unless _positive_decimal( $loan->{patron_id} )
        && 0 + $loan->{patron_id} == $expected{patron_id};
    return _failure('LOAN_CORRELATION_MISMATCH')
        unless _positive_decimal( $loan->{request_patron_id} )
        && 0 + $loan->{request_patron_id} == $expected{patron_id};
    return _failure('LOAN_CORRELATION_MISMATCH')
        unless _positive_decimal( $loan->{biblio_id} )
        && _positive_decimal( $loan->{request_biblio_id} )
        && 0 + $loan->{biblio_id} == 0 + $loan->{request_biblio_id};
    return;
}

sub _valid_returned_loan {
    my ( $loan, %expected ) = @_;
    return unless ref($loan) eq 'HASH';
    return unless ( $loan->{status} // '' ) eq RETURNED_STATUS;
    return unless _positive_decimal( $loan->{loan_id} )
        && 0 + $loan->{loan_id} == $expected{loan_id};
    return unless _positive_decimal( $loan->{request_id} )
        && 0 + $loan->{request_id} == $expected{request_id};
    return unless _uuid( $loan->{portal_request_id} )
        && lc( $loan->{portal_request_id} ) eq lc( $expected{portal_request_id} );
    return unless _positive_decimal( $loan->{patron_id} )
        && 0 + $loan->{patron_id} == $expected{patron_id};
    return unless _positive_decimal( $loan->{biblio_id} )
        && 0 + $loan->{biblio_id} == $expected{biblio_id};
    return unless ( $loan->{started_at} // '' ) eq $expected{started_at};
    return unless ( $loan->{due_at} // '' ) eq $expected{due_at};
    return unless ( $loan->{returned_at} // '' ) eq $expected{returned_at};
    return unless !defined $loan->{revoked_at} && !defined $loan->{expired_at};
    return unless _positive_decimal( $loan->{row_version} )
        && 0 + $loan->{row_version} == $expected{prior_row_version} + 1;
    return unless defined $loan->{renewal_count}
        && !ref( $loan->{renewal_count} )
        && $loan->{renewal_count} =~ /\A[0-9]+\z/
        && 0 + $loan->{renewal_count} == 0 + $expected{renewal_count};
    return 1;
}

sub _safe_loan {
    my ($loan) = @_;
    return unless ref($loan) eq 'HASH';
    for my $required (
        qw(
        loan_id request_id portal_request_id patron_id biblio_id status
        started_at due_at row_version renewal_count created_at updated_at
        )
        )
    {
        return unless exists $loan->{$required};
    }
    my $safe = { map { $_ => $loan->{$_} } @SAFE_LOAN_FIELDS };
    for my $numeric (
        qw(loan_id request_id patron_id biblio_id renewal_count row_version)
        )
    {
        next unless defined $safe->{$numeric};
        return unless _positive_decimal( $safe->{$numeric} )
            || ( $numeric eq 'renewal_count'
            && defined $safe->{$numeric}
            && $safe->{$numeric} =~ /\A[0-9]+\z/ );
        $safe->{$numeric} = 0 + $safe->{$numeric};
    }
    $safe->{portal_request_id} = lc $safe->{portal_request_id}
        if _uuid( $safe->{portal_request_id} );
    return $safe;
}

sub _positive_decimal {
    my ($value) = @_;
    return defined $value && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
}

sub _timestamp {
    my ($value) = @_;
    return defined $value
        && !ref($value)
        && $value =~ /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/;
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

sub _random_uuid {
    my @bytes = map { int( rand(256) ) } 1 .. 16;
    $bytes[6] = ( $bytes[6] & 0x0f ) | 0x40;
    $bytes[8] = ( $bytes[8] & 0x3f ) | 0x80;
    return sprintf(
        '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x',
        @bytes
    );
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
