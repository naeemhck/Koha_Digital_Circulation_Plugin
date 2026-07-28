package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportProvisioning;

use Modern::Perl;
use Digest::SHA qw(sha256_hex);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        repository  => $args{repository},
        definitions => $args{definitions},
    }, $class;
}

sub _slug_from_notes {
    my ( $self, $notes ) = @_;
    my $prefix = $self->{definitions}->ownership_prefix;
    return unless defined $notes;
    return $1 if $notes =~ /\A\Q$prefix\E\s+([a-z0-9_]+);/;
    return;
}

sub _same_definition {
    my ( $self, $row, $definition ) = @_;
    return 0 unless ($row->{report_name} // '') eq $definition->{name};
    return 0 unless ($row->{savedsql} // '') eq $definition->{sql};
    return 0 unless ($row->{notes} // '') eq $definition->{notes};
    return 0 unless ($row->{report_group} // '') eq $definition->{group_code};
    return 0 unless ($row->{report_subgroup} // '') eq $definition->{subgroup_code};
    return 0 unless ($row->{report_area} // '') eq $definition->{report_area};
    return 0 unless ($row->{public} // 0) == 0;
    return 0 unless ($row->{cache_expiry} // 0) == $definition->{cache_expiry};
    return 1;
}

sub inspect {
    my ($self) = @_;
    my $repository = $self->{repository};
    my $definitions = $self->{definitions};
    my $group = $definitions->group;
    my $subgroup = $definitions->subgroup;
    my $reports = $definitions->reports;
    my $by_slug = { map { $_->{slug} => $_ } @$reports };

    my $group_row = $repository->authorised_value( 'REPORT_GROUP', $group->{code} );
    my $subgroup_row = $repository->authorised_value( 'REPORT_SUBGROUP', $subgroup->{code} );
    my @conflicts;
    push @conflicts, 'REPORT_GROUP_CONFLICT'
        if $group_row && (($group_row->{lib} // '') ne $group->{label});
    push @conflicts, 'REPORT_SUBGROUP_CONFLICT'
        if $subgroup_row
        && ( ($subgroup_row->{lib} // '') ne $subgroup->{label}
            || ($subgroup_row->{lib_opac} // '') ne $subgroup->{parent_code} );

    my %rows;
    for my $row ( @{ $repository->managed_reports( $definitions->ownership_prefix ) } ) {
        my $slug = $self->_slug_from_notes( $row->{notes} );
        push @{ $rows{$slug // '__invalid__'} }, $row;
    }

    my ( @missing, @drifted, @duplicates, @installed, @unknown );
    for my $slug ( sort keys %$by_slug ) {
        my $matches = $rows{$slug} || [];
        if (!@$matches) {
            push @missing, $slug;
        } elsif (@$matches > 1) {
            push @duplicates, $slug;
        } elsif ($self->_same_definition( $matches->[0], $by_slug->{$slug} )) {
            push @installed, $slug;
        } else {
            push @drifted, $slug;
        }
    }
    for my $slug ( sort keys %rows ) {
        push @unknown, $slug unless exists $by_slug->{$slug};
    }

    my $group_conflict = grep { $_ eq 'REPORT_GROUP_CONFLICT' } @conflicts;
    my $subgroup_conflict = grep { $_ eq 'REPORT_SUBGROUP_CONFLICT' } @conflicts;
    return {
        expected_count  => scalar(@$reports),
        installed_count => scalar(@installed),
        missing         => \@missing,
        drifted         => \@drifted,
        duplicates      => \@duplicates,
        unknown_managed => \@unknown,
        conflicts       => \@conflicts,
        group_status    => !$group_row ? 'MISSING' : $group_conflict ? 'CONFLICT' : 'INSTALLED',
        subgroup_status => !$subgroup_row ? 'MISSING' : $subgroup_conflict ? 'CONFLICT' : 'INSTALLED',
        rows_by_slug    => \%rows,
    };
}

sub provision {
    my ( $self, %args ) = @_;
    my $repair = $args{repair} ? 1 : 0;
    my $borrowernumber = $args{borrowernumber};
    my $repository = $self->{repository};
    my $definitions = $self->{definitions};
    my $status = $self->inspect;
    return { ok => 0, code => 'MANAGED_REPORT_CONFLICT', status => $status }
        if @{ $status->{conflicts} } || @{ $status->{duplicates} } || @{ $status->{unknown_managed} };

    my $changed = 0;
    my $transaction_started = 0;
    my $failure;
    eval {
        $repository->begin_work;
        $transaction_started = 1;
        if ( $status->{group_status} eq 'MISSING' ) {
            my $group = $definitions->group;
            $repository->create_authorised_value(
                category => 'REPORT_GROUP', code => $group->{code},
                label => $group->{label}, parent_code => undef
            );
            $changed++;
        }
        if ( $status->{subgroup_status} eq 'MISSING' ) {
            my $subgroup = $definitions->subgroup;
            $repository->create_authorised_value(
                category => 'REPORT_SUBGROUP', code => $subgroup->{code},
                label => $subgroup->{label}, parent_code => $subgroup->{parent_code}
            );
            $changed++;
        }

        my %missing = map { $_ => 1 } @{ $status->{missing} };
        my %drifted = map { $_ => 1 } @{ $status->{drifted} };
        for my $definition ( @{ $definitions->reports } ) {
            if ( $missing{$definition->{slug}} ) {
                $repository->create_report(
                    borrowernumber => $borrowernumber,
                    sql => $definition->{sql}, name => $definition->{name},
                    notes => $definition->{notes}, cache_expiry => $definition->{cache_expiry},
                    report_area => $definition->{report_area}, group_code => $definition->{group_code},
                    subgroup_code => $definition->{subgroup_code},
                );
                $changed++;
            } elsif ( $repair && $drifted{$definition->{slug}} ) {
                my $row = $status->{rows_by_slug}{ $definition->{slug} }->[0];
                $repository->update_report(
                    id => $row->{id}, sql => $definition->{sql}, name => $definition->{name},
                    notes => $definition->{notes}, cache_expiry => $definition->{cache_expiry},
                    report_area => $definition->{report_area}, group_code => $definition->{group_code},
                    subgroup_code => $definition->{subgroup_code},
                );
                $changed++;
            }
        }
        $repository->commit;
        $transaction_started = 0;
        1;
    } or do {
        $failure = $@ || 'report provisioning failed';
        eval { $repository->rollback } if $transaction_started;
    };
    return { ok => 0, code => 'REPORT_PROVISIONING_FAILED' } if $failure;

    my $after = $self->inspect;
    return {
        ok => 1,
        changed => $changed,
        drift_preserved => $repair ? 0 : scalar( @{ $after->{drifted} } ),
        status => $after,
    };
}

1;
