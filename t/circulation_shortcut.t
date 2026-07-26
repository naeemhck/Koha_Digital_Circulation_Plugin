use Modern::Perl;
use Test::More;

my $bundle = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation';

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return scalar <$fh>;
}

my $main = slurp("$bundle.pm");
my $js   = slurp("$bundle/static/js/jzl-digital-circulation.js");

like $main, qr/sub intranet_head/, 'intranet_head hook remains defined';
like $main, qr/sub intranet_js/,   'intranet_js hook remains defined';
like $main, qr/circulation-home\.pl\\z/,
    'shortcut script is limited to circulation-home.pl';
like $main,
    qr{/cgi-bin/koha/plugins/run\.pl\?class=Koha%3A%3APlugin%3A%3ACom%3A%3AJunaidZaidiLibrary%3A%3ADigitalCirculation&method=tool},
    'hook embeds the canonical plugin tool URL';
like $main, qr{data-jzl-url="\$url"},
    'hook passes the tool URL through data-jzl-url';
like $main,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-js},
    'hook preserves the existing asset script URL';
like $main,
    qr{/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-css},
    'intranet_head CSS asset URL is preserved';

unlike $main, qr{https?://}, 'hook URL has no hard-coded protocol/host';
unlike $main, qr{192\.168\.}, 'hook URL has no hard-coded LAN host';
unlike $main, qr{:\d{2,5}},   'hook URL has no hard-coded port';

like $js, qr/textContent = 'Digital Circulation'/,
    'shortcut label is Digital Circulation';
like $js, qr/jzl-digital-circulation-shortcut/,
    'stable shortcut ID is present';
like $js, qr/getElementById\('jzl-digital-circulation-shortcut'\)/,
    'duplicate-insertion guard checks the stable ID';
like $js,
    qr/\.circulation-actions ul\.buttons-list,#circ-menu ul,nav\[aria-label="Circulation"\] ul/,
    'shortcut targets the Circulation menu selectors';
like $js, qr/dataset\.jzlUrl/,
    'shortcut reads the root-relative tool URL from data-jzl-url';
like $js, qr{href = toolUrl},
    'shortcut href uses the provided tool URL only';

unlike $js, qr{https?://}, 'shortcut script has no hard-coded host URL';
unlike $js, qr{192\.168\.}, 'shortcut script has no hard-coded LAN host';
unlike $js, qr/\bAuthorization\b|\bBearer\b|\bclient_secret\b|\baccess_token\b|\bOAuth\b/i,
    'shortcut script contains no OAuth or credential values';
unlike $js, qr{/cgi-bin/koha/circ/circulation\.pl|/cgi-bin/koha/circ/returns\.pl},
    'shortcut does not target native circulation routes';
unlike $main . $js, qr{\bAddIssue\b|\bAddReturn\b|\bGetIssue\b},
    'shortcut path does not call native circulation APIs';

# Navigation-only: the data-jzl-url branch returns before staff write helpers run.
my ($nav_branch) = $js =~ /(if \(toolUrl\) \{.*?\n    \})/s;
ok defined $nav_branch && length($nav_branch), 'navigation branch is extractable';
unlike $nav_branch, qr{API_BASE|DECISION_PATH|ISSUE_PATH|fetch\s*\(},
    'shortcut branch performs no REST business writes';
unlike $nav_branch, qr{approve|reject|submitIssuance|/return},
    'shortcut branch does not invoke request, approval, issuance, or return flows';

# Existing staff-tool controls remain intact outside the navigation branch.
like $js, qr/approve\.textContent = 'Approve'/, 'existing Approve control preserved';
like $js, qr/issue\.textContent = 'Issue Loan'/, 'existing Issue Loan control preserved';

done_testing;
