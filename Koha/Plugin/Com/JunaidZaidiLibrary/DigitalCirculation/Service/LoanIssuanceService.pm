package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanIssuanceService;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::RequestRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility;

use constant ACTIVE_STATUS => 'ACTIVE';

my @SAFE_LOAN_FIELDS = qw(
    loan_id request_id patron_id biblio_id status
    started_at due_at returned_at revoked_at expired_at
    approved_by renewal_count created_at updated_at row_version
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
        loan_repository =>
            $args{loan_repository}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository->new(
                table_name => $table_resolver->('loans')
            ),
        event_repository =>
            $args{event_repository}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository->new(
                table_name => $table_resolver->('events')
            ),
        eligibility =>
            $args{eligibility}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::EbookContentEligibility->new,
        due_date_policy => $args{due_date_policy} || \&_missing_due_date_policy,
        clock           => $args{clock} || \&_koha_now,
        uuid_generator  => $args{uuid_generator} || \&_random_uuid,
        json_encoder    => $args{json_encoder} || \&_canonical_json,
        diagnostic      => $args{diagnostic} || sub { return },
    }, $class;
}

sub issue_loan {
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

    my $request_id          = 0 + $args{request_id};
    my $actor_id            = 0 + $args{actor_id};
    my $correlation_id      = $validation->{correlation_id};
    my $request_repository  = $self->{request_repository};
    my $loan_repository     = $self->{loan_repository};
    my $event_repository    = $self->{event_repository};
    my $transaction_started = 0;
    my ( $result, $classified_failure, $failure );

    eval {
        $dbh->begin_work;
        $transaction_started = 1;

        my $request = $request_repository->get_for_issuance( $dbh, $request_id );
        unless ($request) {
            eval { $self->{diagnostic}->('request_not_found') };
            $classified_failure = _failure('REQUEST_NOT_FOUND');
            die "CLASSIFIED_LOAN_ISSUANCE_FAILURE\n";
        }

        my $status = $request->{status};
        unless ( defined $status && !ref($status) && $status eq 'APPROVED' ) {
            eval { $self->{diagnostic}->('request_not_approved') };
            $classified_failure = _failure('REQUEST_NOT_APPROVED');
            die "CLASSIFIED_LOAN_ISSUANCE_FAILURE\n";
        }

        unless ( _positive_decimal( $request->{patron_id} )
            && _positive_decimal( $request->{biblio_id} ) )
        {
            $classified_failure = _failure('INTERNAL_ERROR');
            die "CLASSIFIED_LOAN_ISSUANCE_FAILURE\n";
        }

        my $existing = $loan_repository->find_by_request_id(
            $dbh,
            $request_id,
            for_update => 1
        );
        if ($existing) {
            eval { $self->{diagnostic}->('duplicate_loan') };
            $classified_failure = _failure('LOAN_ALREADY_EXISTS');
            die "CLASSIFIED_LOAN_ISSUANCE_FAILURE\n";
        }

        my $eligibility_failure =
            $self->_revalidate_protected_content( 0 + $request->{biblio_id} );
        if ($eligibility_failure) {
            eval {
                $self->{diagnostic}->('protected_content_validation_failed');
            };
            $classified_failure = $eligibility_failure;
            die "CLASSIFIED_LOAN_ISSUANCE_FAILURE\n";
        }

        my $started_at;
        my $clock_ok = eval {
            $started_at = $self->{clock}->();
            1;
        };
        die 'CLOCK_UNAVAILABLE'
            unless $clock_ok
            && _timestamp($started_at);

        my $due_at = $self->_resolve_due_at(
            started_at => $started_at,
            request    => $request,
            actor_id   => $actor_id,
        );
        unless ( defined $due_at ) {
            eval { $self->{diagnostic}->('loan_policy_failed') };
            $classified_failure = _failure('INVALID_LOAN_PERIOD');
            die "CLASSIFIED_LOAN_ISSUANCE_FAILURE\n";
        }

        my $loan;
        my $insert_ok = eval {
            $loan = $loan_repository->insert_active_loan(
                $dbh,
                request_id  => $request_id,
                patron_id   => 0 + $request->{patron_id},
                biblio_id   => 0 + $request->{biblio_id},
                status      => ACTIVE_STATUS,
                started_at  => $started_at,
                due_at      => $due_at,
                approved_by => $actor_id,
            );
            1;
        };
        if ( !$insert_ok ) {
            my $error = $@ || 'LOAN_INSERT_FAILED';
            if ( $error =~ /LOAN_ALREADY_EXISTS|jzl_loan_request_uq|Duplicate entry/i )
            {
                eval { $self->{diagnostic}->('duplicate_loan') };
                $classified_failure = _failure('LOAN_ALREADY_EXISTS');
                die "CLASSIFIED_LOAN_ISSUANCE_FAILURE\n";
            }
            die $error;
        }
        die 'LOAN_INSERT_RESULT_INVALID' unless _valid_loan_row(
            $loan,
            request_id  => $request_id,
            patron_id   => 0 + $request->{patron_id},
            biblio_id   => 0 + $request->{biblio_id},
            started_at  => $started_at,
            due_at      => $due_at,
            approved_by => $actor_id,
        );

        my $payload = {
            actor_id          => $actor_id,
            biblio_id         => 0 + $request->{biblio_id},
            due_at            => $due_at,
            loan_id           => 0 + $loan->{loan_id},
            new_status        => ACTIVE_STATUS,
            request_id        => $request_id,
            source            => 'STAFF',
            started_at        => $started_at,
            subject_patron_id => 0 + $request->{patron_id},
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

        $event_repository->insert_loan_created_event(
            $dbh,
            aggregate_type    => 'LOAN',
            aggregate_id      => 0 + $loan->{loan_id},
            request_id        => $request_id,
            loan_id           => 0 + $loan->{loan_id},
            renewal_id        => undef,
            patron_id         => 0 + $request->{patron_id},
            biblio_id         => 0 + $request->{biblio_id},
            actor_patron_id   => $actor_id,
            source            => 'STAFF',
            correlation_id    => $correlation_id,
            occurred_at       => $started_at,
            payload_json      => $payload_json,
            delivery_status   => 'NOT_REQUIRED',
            delivery_attempts => 0,
        );

        my $unchanged = $request_repository->get_by_id( $dbh, $request_id );
        die 'REQUEST_MUTATED_DURING_ISSUANCE'
            unless _request_decision_unchanged( $request, $unchanged );

        my $safe_loan = _safe_loan($loan);
        die 'LOAN_NORMALIZATION_FAILED' unless $safe_loan;

        $result = {
            ok             => 1,
            loan           => $safe_loan,
            correlation_id => $correlation_id,
        };

        $dbh->commit;
        $transaction_started = 0;
        1;
    } or $failure = $@ || 'LOAN_ISSUANCE_TRANSACTION_FAILED';

    if ($failure) {
        eval { $dbh->rollback if $transaction_started };
        return $classified_failure if $classified_failure;
        eval { $self->{diagnostic}->('transaction_failed') };
        return _failure(
            $failure =~ /\A(?:CLOCK_UNAVAILABLE|EVENT_PAYLOAD_ENCODING_FAILED|REQUEST_MUTATED_DURING_ISSUANCE|LOAN_NORMALIZATION_FAILED|LOAN_INSERT_RESULT_INVALID)/
            ? 'INTERNAL_ERROR'
            : 'DIGITAL_CIRCULATION_UNAVAILABLE'
        );
    }

    return $result;
}

sub validate_command {
    my ( $self, %args ) = @_;
    return _failure('INVALID_INPUT')
        unless _positive_decimal( $args{request_id} )
        && _positive_decimal( $args{actor_id} );

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
        ok             => 1,
        correlation_id => $correlation_id,
    };
}

sub _revalidate_protected_content {
    my ( $self, $biblio_id ) = @_;
    my $eligibility = $self->{eligibility};
    return _failure('PROTECTED_CONTENT_UNAVAILABLE')
        unless blessed($eligibility)
        && $eligibility->can('check_biblio_eligibility');

    my $result;
    my $read = eval {
        $result = $eligibility->check_biblio_eligibility(
            biblio_id => $biblio_id
        );
        1;
    };
    return _failure('PROTECTED_CONTENT_UNAVAILABLE') unless $read;
    return _failure('PROTECTED_CONTENT_UNAVAILABLE')
        unless ref($result) eq 'HASH' && exists $result->{eligible};

    if ( $result->{eligible} ) {
        return _failure('INVALID_MAPPING')
            unless _positive_decimal( $result->{biblio_id} )
            && 0 + $result->{biblio_id} == $biblio_id;
        return;
    }

    my $code   = $result->{code}   // '';
    my $reason = $result->{reason} // '';
    return _failure('PROTECTED_CONTENT_UNAVAILABLE')
        if $reason eq 'CONTENT_LOOKUP_UNAVAILABLE'
        || $reason eq 'MISSING_PROTECTED_CONTENT'
        || $code eq 'BIBLIO_NOT_FOUND';
    return _failure('INVALID_MAPPING')
        if $reason eq 'INVALID_CONTENT_MAPPING'
        || $reason eq 'CONTENT_DISABLED'
        || $code eq 'CONTENT_NOT_ELIGIBLE';
    return _failure('PROTECTED_CONTENT_UNAVAILABLE');
}

sub _resolve_due_at {
    my ( $self, %ctx ) = @_;
    my $policy = $self->{due_date_policy};
    return unless ref($policy) eq 'CODE' || ( blessed($policy) && $policy->can('resolve_due_at') );

    my $policy_result;
    my $ok = eval {
        if ( ref($policy) eq 'CODE' ) {
            $policy_result = $policy->(%ctx);
        }
        else {
            $policy_result = $policy->resolve_due_at(%ctx);
        }
        1;
    };
    return unless $ok && ref($policy_result) eq 'HASH';
    return if exists $policy_result->{ok} && !$policy_result->{ok};

    my $due_at = $policy_result->{due_at};
    if ( !defined $due_at && exists $policy_result->{duration_seconds} ) {
        my $seconds = $policy_result->{duration_seconds};
        return
            unless defined $seconds
            && !ref($seconds)
            && $seconds =~ /\A[1-9][0-9]*\z/;
        $due_at = _add_seconds( $ctx{started_at}, 0 + $seconds );
        return unless defined $due_at;
    }

    return unless _timestamp($due_at);
    return unless $due_at gt $ctx{started_at};
    return $due_at;
}

sub _valid_loan_row {
    my ( $loan, %expected ) = @_;
    return unless ref($loan) eq 'HASH';
    return unless _positive_decimal( $loan->{loan_id} );
    return unless ( $loan->{status} // '' ) eq ACTIVE_STATUS;
    return unless _positive_decimal( $loan->{request_id} )
        && 0 + $loan->{request_id} == $expected{request_id};
    return unless _positive_decimal( $loan->{patron_id} )
        && 0 + $loan->{patron_id} == $expected{patron_id};
    return unless _positive_decimal( $loan->{biblio_id} )
        && 0 + $loan->{biblio_id} == $expected{biblio_id};
    return unless ( $loan->{started_at} // '' ) eq $expected{started_at};
    return unless ( $loan->{due_at} // '' ) eq $expected{due_at};
    return unless _positive_decimal( $loan->{approved_by} )
        && 0 + $loan->{approved_by} == $expected{approved_by};
    return unless !defined $loan->{returned_at}
        && !defined $loan->{revoked_at}
        && !defined $loan->{expired_at};
    return unless _positive_decimal( $loan->{row_version} )
        && 0 + $loan->{row_version} == 1;
    return 1;
}

sub _request_decision_unchanged {
    my ( $before, $after ) = @_;
    return unless ref($before) eq 'HASH' && ref($after) eq 'HASH';
    for my $field (
        qw(
        request_id status patron_id biblio_id row_version
        approved_at approved_by rejected_at rejected_by rejection_reason
        cancelled_at portal_request_id
        )
        )
    {
        my $left  = $before->{$field};
        my $right = $after->{$field};
        if ( !defined $left && !defined $right ) {
            next;
        }
        return unless defined $left && defined $right && !ref($left) && !ref($right);
        return unless "$left" eq "$right";
    }
    return 1;
}

sub _safe_loan {
    my ($loan) = @_;
    return unless ref($loan) eq 'HASH';
    for my $required (
        qw(loan_id request_id patron_id biblio_id status started_at due_at approved_by row_version)
        )
    {
        return unless exists $loan->{$required};
    }
    return unless ( $loan->{status} // '' ) eq ACTIVE_STATUS;
    my $safe = { map { $_ => $loan->{$_} } @SAFE_LOAN_FIELDS };
    for my $numeric (
        qw(loan_id request_id patron_id biblio_id approved_by renewal_count row_version)
        )
    {
        next unless defined $safe->{$numeric};
        return unless _positive_decimal( $safe->{$numeric} )
            || ( $numeric eq 'renewal_count' && defined $safe->{$numeric} && $safe->{$numeric} =~ /\A[0-9]+\z/ );
        $safe->{$numeric} = 0 + $safe->{$numeric};
    }
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

sub _add_seconds {
    my ( $started_at, $seconds ) = @_;
    return unless _timestamp($started_at);
    return unless defined $seconds && $seconds =~ /\A[1-9][0-9]*\z/;
    require Time::Local;
    my ( $date, $time ) = split / /, $started_at, 2;
    my ( $year, $month, $day ) = split /-/, $date;
    my ( $hour, $min, $sec ) = split /:/, $time;
    my $epoch = eval {
        Time::Local::timegm_modern( $sec, $min, $hour, $day, $month - 1, $year );
    };
    return unless defined $epoch;
    $epoch += 0 + $seconds;
    my ( $s, $mi, $h, $d, $mo, $y ) = ( gmtime($epoch) )[ 0 .. 5 ];
    return sprintf(
        '%04d-%02d-%02d %02d:%02d:%02d',
        $y + 1900, $mo + 1, $d, $h, $mi, $s
    );
}

sub _missing_due_date_policy {
    return { ok => 0, code => 'INVALID_LOAN_PERIOD' };
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
    my $dt = Koha::DateUtils::dt_from_string();
    $dt->set_time_zone('UTC');
    return $dt->strftime('%Y-%m-%d %H:%M:%S');
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
