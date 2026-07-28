use Modern::Perl;
use Test::More;
use JSON qw(decode_json);

sub text {
    my ($path) = @_;
    local $/;
    open my $fh, '<', $path or die $!;
    return <$fh>;
}

my $base = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation';
my $service = text("$base/Service/LoanLifecycleService.pm");
my $policy = text("$base/Service/LifecyclePolicy.pm");
my $repository = text("$base/Repository/LoanRepository.pm");
my $events = text("$base/Repository/EventRepository.pm");
my $controller = text("$base/Controller/Loans.pm");
my $maintenance = text("$base/Controller/Maintenance.pm");
my $api = decode_json(text("$base/openapi.json"));

for my $setting (qw(renewals_enabled staff_revocations_enabled automatic_expiry_enabled renewal_days maximum_renewals expiry_batch_size)) {
    like $policy, qr/\Q$setting\E/, "policy contains $setting";
}
like $policy, qr/renewals_enabled\s*=>\s*0/, 'renewals default disabled';
like $policy, qr/staff_revocations_enabled\s*=>\s*0/, 'revocations default disabled';
like $policy, qr/automatic_expiry_enabled\s*=>\s*0/, 'expiry default disabled';
like $repository, qr/FOR UPDATE/, 'locked lifecycle read';
like $repository, qr/DATE_ADD\(due_at/, 'renewal extends existing due date';
like $repository, qr/due_at > UTC_TIMESTAMP/, 'past-due renewal guard';
like $service, qr/find_loan_event_by_correlation/, 'correlation replay lookup';
like $service, qr/GET_LOCK\(\?, 0\)/, 'expiry named lock';
for my $event (qw(LOAN_RENEWED LOAN_REVOKED LOAN_EXPIRED)) {
    like $events, qr/\Q$event\E/, "$event repository support";
}
ok exists $api->{'/loans/{loan_id}/renew'}{post}, 'renew route';
ok exists $api->{'/loans/{loan_id}/revoke'}{post}, 'revoke route';
ok exists $api->{'/maintenance/expire-loans'}{post}, 'expiry route';
like $controller, qr/additionalProperties|_parse_lifecycle_request/, 'loan lifecycle bodies are closed in controller';
like $maintenance, qr/!keys\(%\{\$body\}\)/, 'expiry body must be empty';
unlike $service . $repository, qr/\b(?:AddIssue|AddReturn|GetIssue)\b/, 'no native circulation call';
done_testing;
