package LoanLifecycleFakes;

use Modern::Perl;

sub policy {
    my ( $class, %settings ) = @_;
    return bless {
        settings => {
            renewals_enabled => 0,
            staff_revocations_enabled => 0,
            automatic_expiry_enabled => 0,
            renewal_days => 14,
            maximum_renewals => 2,
            expiry_batch_size => 100,
            %settings,
        },
    }, 'LoanLifecycleFakes::Policy';
}

package LoanLifecycleFakes::Policy;
sub load_config { return { loaded => 1, settings => { %{ shift->{settings} } } } }

1;
