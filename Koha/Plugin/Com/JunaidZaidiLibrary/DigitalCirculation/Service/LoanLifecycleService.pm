package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::LoanLifecycleService;

use Modern::Perl;
use Scalar::Util qw(blessed);

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository;
use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository;

my @SAFE_LOAN_FIELDS = qw(
    loan_id request_id portal_request_id patron_id biblio_id status
    started_at due_at returned_at revoked_at expired_at renewal_count
    row_version created_at updated_at
);

sub new {
    my ( $class, %args ) = @_;
    my $resolver = $args{table_resolver} || \&_plugin_table;
    return bless {
        dbh => $args{dbh},
        loan_repository => $args{loan_repository}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::LoanRepository->new(
                table_name => $resolver->('loans'),
                request_table_name => $resolver->('requests'),
            ),
        event_repository => $args{event_repository}
            || Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Repository::EventRepository->new(
                table_name => $resolver->('events'),
            ),
        policy       => $args{policy},
        json_encoder => $args{json_encoder} || \&_canonical_json,
    }, $class;
}

sub renew {
    my ( $self, %args ) = @_;
    return _failure('INVALID_INPUT')
        unless _positive($args{loan_id})
        && _positive($args{patron_id})
        && _uuid($args{portal_request_id})
        && _positive($args{expected_row_version})
        && _positive($args{actor_id})
        && _uuid($args{correlation_id});
    my $settings = $self->_settings;
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE') unless $settings;
    return _failure('RENEWALS_DISABLED') unless $settings->{renewals_enabled};

    return $self->_transaction(sub {
        my ($dbh) = @_;
        my $loan = $self->{loan_repository}->get_for_lifecycle(
            $dbh, $args{loan_id}, for_update => 1
        );
        return _failure('LOAN_NOT_FOUND') unless $loan;
        return _failure('LOAN_CORRELATION_MISMATCH')
            unless _correlated($loan, %args);

        my $event = $self->{event_repository}->find_loan_event_by_correlation(
            $dbh,
            event_type     => 'LOAN_RENEWED',
            correlation_id => $args{correlation_id},
            loan_id        => 0 + $args{loan_id},
        );
        return _success($loan, $args{correlation_id}, 1) if $event;

        return _failure('LOAN_NOT_RENEWABLE')
            unless ($loan->{status} // '') eq 'ACTIVE';
        return _failure('VERSION_CONFLICT')
            unless _positive($loan->{row_version})
            && $loan->{row_version} == $args{expected_row_version};
        return _failure('MAXIMUM_RENEWALS_REACHED')
            unless defined($loan->{renewal_count})
            && $loan->{renewal_count} =~ /\A[0-9]+\z/
            && $loan->{renewal_count} < $settings->{maximum_renewals};

        my $now = $self->{loan_repository}->database_utc($dbh);
        die 'DATABASE_CLOCK_UNAVAILABLE' unless _timestamp($now);
        return _failure('LOAN_PAST_DUE')
            unless _timestamp($loan->{due_at}) && $loan->{due_at} gt $now;

        my $previous_due_at = $loan->{due_at};
        my $previous_count  = 0 + $loan->{renewal_count};
        my $updated = $self->{loan_repository}->update_active_renewal(
            $dbh,
            loan_id              => 0 + $args{loan_id},
            expected_row_version => 0 + $args{expected_row_version},
            renewal_days         => $settings->{renewal_days},
            maximum_renewals     => $settings->{maximum_renewals},
        );
        return _failure('VERSION_CONFLICT') unless $updated;

        my $fresh = $self->{loan_repository}->get_for_lifecycle($dbh, $args{loan_id});
        die 'RENEWAL_RESULT_INVALID'
            unless $fresh
            && ($fresh->{status} // '') eq 'ACTIVE'
            && $fresh->{row_version} == $args{expected_row_version} + 1
            && $fresh->{renewal_count} == $previous_count + 1
            && $fresh->{due_at} gt $previous_due_at;
        $self->_insert_event(
            $dbh, 'renewed', $fresh, %args,
            source => 'PORTAL',
            payload => {
                previous_due_at      => $previous_due_at,
                new_due_at           => $fresh->{due_at},
                previous_renewal_count => $previous_count,
                renewal_count        => 0 + $fresh->{renewal_count},
                previous_status      => 'ACTIVE',
                new_status           => 'ACTIVE',
            },
        );
        return _success($fresh, $args{correlation_id}, 0);
    });
}

sub revoke {
    my ( $self, %args ) = @_;
    return _failure('INVALID_INPUT')
        unless _positive($args{loan_id})
        && _positive($args{expected_row_version})
        && _positive($args{actor_id})
        && _uuid($args{correlation_id})
        && _reason($args{reason});
    my $reason = $args{reason};
    $reason =~ s/\A\s+|\s+\z//g;
    my $settings = $self->_settings;
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE') unless $settings;
    return _failure('STAFF_REVOCATIONS_DISABLED')
        unless $settings->{staff_revocations_enabled};

    return $self->_transaction(sub {
        my ($dbh) = @_;
        my $loan = $self->{loan_repository}->get_for_lifecycle(
            $dbh, $args{loan_id}, for_update => 1
        );
        return _failure('LOAN_NOT_FOUND') unless $loan;
        my $event = $self->{event_repository}->find_loan_event_by_correlation(
            $dbh,
            event_type     => 'LOAN_REVOKED',
            correlation_id => $args{correlation_id},
            loan_id        => 0 + $args{loan_id},
        );
        return _success($loan, $args{correlation_id}, 1)
            if $event && ($loan->{status} // '') eq 'REVOKED';
        return _failure('LOAN_NOT_REVOCABLE')
            unless ($loan->{status} // '') eq 'ACTIVE';
        return _failure('VERSION_CONFLICT')
            unless _positive($loan->{row_version})
            && $loan->{row_version} == $args{expected_row_version};

        my $updated = $self->{loan_repository}->update_active_revocation(
            $dbh,
            loan_id              => 0 + $args{loan_id},
            expected_row_version => 0 + $args{expected_row_version},
        );
        return _failure('VERSION_CONFLICT') unless $updated;
        my $fresh = $self->{loan_repository}->get_for_lifecycle($dbh, $args{loan_id});
        die 'REVOCATION_RESULT_INVALID'
            unless $fresh
            && ($fresh->{status} // '') eq 'REVOKED'
            && _timestamp($fresh->{revoked_at})
            && !defined($fresh->{returned_at})
            && !defined($fresh->{expired_at})
            && $fresh->{row_version} == $args{expected_row_version} + 1;
        $self->_insert_event(
            $dbh, 'revoked', $fresh, %args,
            source => 'STAFF',
            payload => {
                previous_status => 'ACTIVE',
                new_status      => 'REVOKED',
                revoked_at      => $fresh->{revoked_at},
                reason          => $reason,
            },
        );
        return _success($fresh, $args{correlation_id}, 0);
    });
}

sub expire_due {
    my ( $self, %args ) = @_;
    return _failure('INVALID_INPUT')
        unless _positive($args{actor_id}) && _uuid($args{correlation_id});
    my $settings = $self->_settings;
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE') unless $settings;
    return _failure('AUTOMATIC_EXPIRY_DISABLED')
        unless $settings->{automatic_expiry_enabled};
    my $dbh = eval { $self->{dbh} || _koha_dbh() };
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE') unless $dbh;

    my $lock_name = 'jzl_digital_circulation_expiry';
    my $acquired = eval {
        $dbh->selectrow_array('SELECT GET_LOCK(?, 0)', undef, $lock_name);
    };
    return _failure('EXPIRY_SWEEP_BUSY') unless defined($acquired) && $acquired == 1;

    my $result;
    my $ok = eval {
        $result = $self->_transaction(sub {
            my ($tx) = @_;
            my $rows = $self->{loan_repository}->list_due_for_expiry(
                $tx, limit => $settings->{expiry_batch_size}
            );
            my @changed;
            my $skipped = 0;
            for my $candidate ( @{$rows} ) {
                my $loan = $self->{loan_repository}->get_for_lifecycle(
                    $tx, $candidate->{loan_id}, for_update => 1
                );
                unless ($loan && ($loan->{status} // '') eq 'ACTIVE') {
                    $skipped++;
                    next;
                }
                my $updated = $self->{loan_repository}->update_active_expiry(
                    $tx,
                    loan_id              => $loan->{loan_id},
                    expected_row_version => $loan->{row_version},
                );
                unless ($updated) {
                    $skipped++;
                    next;
                }
                my $fresh = $self->{loan_repository}->get_for_lifecycle(
                    $tx, $loan->{loan_id}
                );
                die 'EXPIRY_RESULT_INVALID'
                    unless $fresh
                    && ($fresh->{status} // '') eq 'EXPIRED'
                    && _timestamp($fresh->{expired_at})
                    && !defined($fresh->{returned_at})
                    && !defined($fresh->{revoked_at});
                my $event_correlation = $args{correlation_id} . ':' . $fresh->{loan_id};
                $self->_insert_event(
                    $tx, 'expired', $fresh,
                    actor_id       => $args{actor_id},
                    correlation_id => $event_correlation,
                    source         => 'SYSTEM',
                    payload        => {
                        previous_status => 'ACTIVE',
                        new_status      => 'EXPIRED',
                        expired_at      => $fresh->{expired_at},
                        sweep_correlation_id => $args{correlation_id},
                    },
                );
                push @changed, _safe_loan($fresh);
            }
            return {
                ok             => 1,
                scanned_count  => scalar(@{$rows}),
                expired_count  => scalar(@changed),
                skipped_count  => $skipped,
                loans          => \@changed,
                correlation_id => $args{correlation_id},
            };
        });
        1;
    };
    my $release_ok = eval {
        $dbh->selectrow_array('SELECT RELEASE_LOCK(?)', undef, $lock_name);
        1;
    };
    return _failure('INTERNAL_ERROR') unless $ok && $release_ok;
    return $result;
}

sub _settings {
    my ($self) = @_;
    my $policy = $self->{policy};
    return unless blessed($policy) && $policy->can('load_config');
    my $loaded = eval { $policy->load_config };
    return unless ref($loaded) eq 'HASH'
        && $loaded->{loaded}
        && ref($loaded->{settings}) eq 'HASH';
    return $loaded->{settings};
}

sub _transaction {
    my ( $self, $code ) = @_;
    my $dbh = eval { $self->{dbh} || _koha_dbh() };
    return _failure('DIGITAL_CIRCULATION_UNAVAILABLE') unless $dbh;
    my ( $result, $started );
    my $ok = eval {
        $dbh->begin_work;
        $started = 1;
        $result = $code->($dbh);
        if ( ref($result) eq 'HASH' && !$result->{ok} ) {
            $dbh->rollback;
        }
        else {
            $dbh->commit;
        }
        $started = 0;
        1;
    };
    unless ($ok) {
        eval { $dbh->rollback } if $started;
        return _failure('INTERNAL_ERROR');
    }
    return $result;
}

sub _insert_event {
    my ( $self, $dbh, $kind, $loan, %args ) = @_;
    my $payload_json = $self->{json_encoder}->({
        %{ $args{payload} || {} },
        loan_id           => 0 + $loan->{loan_id},
        request_id        => 0 + $loan->{request_id},
        biblio_id         => 0 + $loan->{biblio_id},
        subject_patron_id => 0 + $loan->{patron_id},
        actor_id          => 0 + $args{actor_id},
        source            => $args{source},
    });
    my $method = "insert_loan_${kind}_event";
    $self->{event_repository}->$method(
        $dbh,
        aggregate_type  => 'LOAN',
        aggregate_id    => 0 + $loan->{loan_id},
        request_id      => 0 + $loan->{request_id},
        loan_id         => 0 + $loan->{loan_id},
        renewal_id      => undef,
        patron_id       => 0 + $loan->{patron_id},
        biblio_id       => 0 + $loan->{biblio_id},
        actor_patron_id => 0 + $args{actor_id},
        source           => $args{source},
        correlation_id   => $args{correlation_id},
        occurred_at      => $loan->{updated_at},
        payload_json     => $payload_json,
        delivery_status  => 'NOT_REQUIRED',
        delivery_attempts => 0,
    );
}

sub _correlated {
    my ( $loan, %args ) = @_;
    return _positive($loan->{request_id})
        && _positive($loan->{joined_request_id})
        && $loan->{request_id} == $loan->{joined_request_id}
        && _positive($loan->{patron_id})
        && _positive($loan->{request_patron_id})
        && $loan->{patron_id} == $args{patron_id}
        && $loan->{request_patron_id} == $args{patron_id}
        && _positive($loan->{biblio_id})
        && _positive($loan->{request_biblio_id})
        && $loan->{biblio_id} == $loan->{request_biblio_id}
        && _uuid($loan->{portal_request_id})
        && lc($loan->{portal_request_id}) eq lc($args{portal_request_id});
}

sub _safe_loan {
    my ($loan) = @_;
    return { map { $_ => $loan->{$_} } @SAFE_LOAN_FIELDS };
}

sub _success {
    my ( $loan, $correlation_id, $replay ) = @_;
    return {
        ok                => 1,
        loan              => _safe_loan($loan),
        correlation_id    => $correlation_id,
        idempotent_replay => $replay ? 1 : 0,
    };
}

sub _failure {
    return { ok => 0, code => shift };
}

sub _positive {
    my ($value) = @_;
    return defined($value) && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
}

sub _uuid {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && $value =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i;
}

sub _timestamp {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && $value =~ /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/;
}

sub _reason {
    my ($value) = @_;
    return unless defined($value) && !ref($value) && $value !~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
    $value =~ s/\A\s+|\s+\z//g;
    return length($value) >= 3 && length($value) <= 500;
}

sub _canonical_json {
    my ($value) = @_;
    require Cpanel::JSON::XS;
    return Cpanel::JSON::XS->new->canonical(1)->utf8(1)->encode($value);
}

sub _koha_dbh {
    require C4::Context;
    return C4::Context->dbh;
}

sub _plugin_table {
    my ($name) = @_;
    return "plugin_jzl_ebook_$name";
}

1;
