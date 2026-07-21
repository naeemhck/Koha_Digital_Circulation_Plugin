package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use C4::Auth qw(haspermission);
use C4::Context;
use Koha;
use Mojo::JSON qw(decode_json);

our $VERSION = '0.1.0';
our $SCHEMA_VERSION = 1;
our $TESTED_KOHA_VERSION = '26.05.01.000';
our $metadata = {
    name            => 'Junaid Zaidi Library Digital eBook Circulation',
    author          => 'Junaid Zaidi Library, COMSATS University Islamabad',
    description     => 'Koha-authoritative request, approval, renewal, return, expiry, revocation, and access-state management for protected institutional eBooks.',
    date_authored   => '2026-07-21',
    date_updated    => '2026-07-21',
    minimum_version => '26.05.00.000',
    version         => $VERSION,
    class           => __PACKAGE__,
    copyright       => 'Copyright 2026 COMSATS University Islamabad',
    license         => 'GPL-3.0-or-later',
};

sub new { my ($class,$args)=@_; $args //= {}; $args->{metadata}=$metadata; return $class->SUPER::new($args) }
sub api_namespace { 'jzl-digital-circulation' }
sub api_routes { my ($self)=@_; decode_json($self->mbf_read('openapi.json')) }
sub schema_version { $SCHEMA_VERSION }
sub table { my ($self,$name)=@_; die 'Unknown table' unless $name =~ /\A(?:requests|loans|renewals|events|schema_versions)\z/; return "plugin_jzl_ebook_$name" }

sub _migration_001 {
    my ($self,$dbh)=@_;
    my $r=$self->table('requests'); my $l=$self->table('loans');
    my $n=$self->table('renewals'); my $e=$self->table('events'); my $v=$self->table('schema_versions');
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS `$r` (
      request_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, portal_request_id VARCHAR(128) NOT NULL,
      portal_idempotency_key VARCHAR(128) NOT NULL, source VARCHAR(16) NOT NULL DEFAULT 'PORTAL',
      patron_id INT NOT NULL, biblio_id INT NOT NULL, status VARCHAR(16) NOT NULL DEFAULT 'PENDING',
      requested_at DATETIME NOT NULL, approved_at DATETIME NULL, approved_by INT NULL,
      rejected_at DATETIME NULL, rejected_by INT NULL, rejection_reason TEXT NULL, cancelled_at DATETIME NULL,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      row_version INT UNSIGNED NOT NULL DEFAULT 1,
      pending_guard VARCHAR(80) AS (CASE WHEN status='PENDING' THEN CONCAT(patron_id,':',biblio_id) ELSE NULL END) STORED,
      PRIMARY KEY(request_id), UNIQUE KEY jzl_req_portal_uq(portal_request_id), UNIQUE KEY jzl_req_idem_uq(portal_idempotency_key),
      UNIQUE KEY jzl_req_pending_uq(pending_guard), KEY jzl_req_status_idx(status), KEY jzl_req_patron_idx(patron_id),
      KEY jzl_req_biblio_idx(biblio_id), KEY jzl_req_requested_idx(requested_at), KEY jzl_req_patron_biblio_status_idx(patron_id,biblio_id,status),
      CONSTRAINT jzl_req_status_ck CHECK(status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
      CONSTRAINT jzl_req_source_ck CHECK(source='PORTAL'),
      CONSTRAINT jzl_req_decision_ck CHECK((status='APPROVED' AND approved_at IS NOT NULL AND approved_by IS NOT NULL AND rejected_at IS NULL AND rejected_by IS NULL AND cancelled_at IS NULL) OR (status='REJECTED' AND rejected_at IS NOT NULL AND rejected_by IS NOT NULL AND approved_at IS NULL AND approved_by IS NULL AND cancelled_at IS NULL) OR (status='CANCELLED' AND cancelled_at IS NOT NULL AND approved_at IS NULL AND rejected_at IS NULL) OR (status='PENDING' AND approved_at IS NULL AND rejected_at IS NULL AND cancelled_at IS NULL)),
      CONSTRAINT jzl_req_rowver_ck CHECK(row_version > 0)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS `$l` (
      loan_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, request_id BIGINT UNSIGNED NOT NULL, patron_id INT NOT NULL, biblio_id INT NOT NULL,
      status VARCHAR(24) NOT NULL, started_at DATETIME NOT NULL, due_at DATETIME NOT NULL, returned_at DATETIME NULL,
      revoked_at DATETIME NULL, expired_at DATETIME NULL, approved_by INT NOT NULL, renewal_count INT UNSIGNED NOT NULL DEFAULT 0,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      row_version INT UNSIGNED NOT NULL DEFAULT 1, PRIMARY KEY(loan_id), UNIQUE KEY jzl_loan_request_uq(request_id),
      KEY jzl_loan_patron_idx(patron_id), KEY jzl_loan_biblio_idx(biblio_id), KEY jzl_loan_status_idx(status), KEY jzl_loan_due_idx(due_at),
      KEY jzl_loan_patron_biblio_status_idx(patron_id,biblio_id,status),
      CONSTRAINT jzl_loan_request_fk FOREIGN KEY(request_id) REFERENCES `$r`(request_id) ON DELETE RESTRICT,
      CONSTRAINT jzl_loan_status_ck CHECK(status IN ('ACTIVE','RENEWAL_PENDING','RETURNED','EXPIRED','REVOKED')),
      CONSTRAINT jzl_loan_due_ck CHECK(due_at > started_at), CONSTRAINT jzl_loan_rowver_ck CHECK(row_version > 0),
      CONSTRAINT jzl_loan_terminal_ck CHECK((status='RETURNED' AND returned_at IS NOT NULL AND revoked_at IS NULL AND expired_at IS NULL) OR (status='REVOKED' AND revoked_at IS NOT NULL AND returned_at IS NULL AND expired_at IS NULL) OR (status='EXPIRED' AND expired_at IS NOT NULL AND returned_at IS NULL AND revoked_at IS NULL) OR (status IN ('ACTIVE','RENEWAL_PENDING') AND returned_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL))
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS `$n` (
      renewal_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, loan_id BIGINT UNSIGNED NOT NULL, status VARCHAR(16) NOT NULL,
      requested_at DATETIME NOT NULL, decided_at DATETIME NULL, decided_by INT NULL, previous_due_at DATETIME NOT NULL,
      proposed_due_at DATETIME NOT NULL, approved_due_at DATETIME NULL, rejection_reason TEXT NULL,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      row_version INT UNSIGNED NOT NULL DEFAULT 1,
      pending_guard BIGINT UNSIGNED AS (CASE WHEN status='PENDING' THEN loan_id ELSE NULL END) STORED,
      PRIMARY KEY(renewal_id), UNIQUE KEY jzl_renew_pending_uq(pending_guard), KEY jzl_renew_loan_idx(loan_id),
      KEY jzl_renew_status_idx(status), KEY jzl_renew_requested_idx(requested_at),
      CONSTRAINT jzl_renew_loan_fk FOREIGN KEY(loan_id) REFERENCES `$l`(loan_id) ON DELETE RESTRICT,
      CONSTRAINT jzl_renew_status_ck CHECK(status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
      CONSTRAINT jzl_renew_due_ck CHECK(proposed_due_at > previous_due_at), CONSTRAINT jzl_renew_rowver_ck CHECK(row_version > 0),
      CONSTRAINT jzl_renew_decision_ck CHECK((status='PENDING' AND decided_at IS NULL AND decided_by IS NULL AND approved_due_at IS NULL) OR (status='APPROVED' AND decided_at IS NOT NULL AND decided_by IS NOT NULL AND approved_due_at IS NOT NULL) OR (status IN ('REJECTED','CANCELLED') AND decided_at IS NOT NULL AND approved_due_at IS NULL))
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS `$e` (
      event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, event_type VARCHAR(64) NOT NULL, aggregate_type VARCHAR(32) NOT NULL,
      aggregate_id BIGINT UNSIGNED NOT NULL, request_id BIGINT UNSIGNED NULL, loan_id BIGINT UNSIGNED NULL, renewal_id BIGINT UNSIGNED NULL,
      patron_id INT NOT NULL, biblio_id INT NOT NULL, actor_patron_id INT NULL, source VARCHAR(24) NOT NULL,
      correlation_id VARCHAR(128) NOT NULL, occurred_at DATETIME NOT NULL, payload_json JSON NOT NULL,
      delivery_status VARCHAR(24) NOT NULL DEFAULT 'NOT_REQUIRED', delivery_attempts INT UNSIGNED NOT NULL DEFAULT 0,
      next_delivery_at DATETIME NULL, delivered_at DATETIME NULL, last_error_code VARCHAR(64) NULL,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(event_id), UNIQUE KEY jzl_event_corr_uq(correlation_id,event_type),
      KEY jzl_event_type_idx(event_type), KEY jzl_event_aggregate_idx(aggregate_type,aggregate_id), KEY jzl_event_request_idx(request_id),
      KEY jzl_event_loan_idx(loan_id), KEY jzl_event_occurred_idx(occurred_at), KEY jzl_event_delivery_idx(delivery_status,next_delivery_at),
      CONSTRAINT jzl_event_delivery_ck CHECK(delivery_status IN ('NOT_REQUIRED','PENDING','DELIVERED','FAILED')),
      CONSTRAINT jzl_event_request_fk FOREIGN KEY(request_id) REFERENCES `$r`(request_id) ON DELETE RESTRICT,
      CONSTRAINT jzl_event_loan_fk FOREIGN KEY(loan_id) REFERENCES `$l`(loan_id) ON DELETE RESTRICT,
      CONSTRAINT jzl_event_renew_fk FOREIGN KEY(renewal_id) REFERENCES `$n`(renewal_id) ON DELETE RESTRICT)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS `$v` (schema_version INT UNSIGNED NOT NULL, plugin_version VARCHAR(32) NOT NULL,
      applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, migration_name VARCHAR(128) NOT NULL, checksum CHAR(64) NULL,
      PRIMARY KEY(schema_version), UNIQUE KEY jzl_schema_migration_uq(migration_name)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    $dbh->do("INSERT IGNORE INTO `$v`(schema_version,plugin_version,migration_name,checksum) VALUES (1,?,?,?)",undef,$VERSION,'001_initial_schema','69bcf09d56f99afe');
}

sub install { my ($self)=@_; my $dbh=C4::Context->dbh; eval { $dbh->do("SELECT GET_LOCK('jzl_digital_circulation_schema',30)"); $self->_migration_001($dbh); 1 } or do { my $e=$@; eval{$dbh->do("SELECT RELEASE_LOCK('jzl_digital_circulation_schema')")}; warn "PLUGIN_SCHEMA_UNAVAILABLE: migration failed"; return 0 }; $dbh->do("SELECT RELEASE_LOCK('jzl_digital_circulation_schema')"); return 1 }
sub upgrade { shift->install }
sub uninstall { 1 }
sub configure { shift->tool }

sub _staff_allowed { my $u=C4::Context->userenv || {}; return 0 unless $u->{id}; my $p=haspermission($u->{id},{circulate=>'circulate_remaining_permissions'}); return $p ? 1 : 0 }
sub tool { my ($self)=@_; my $t=$self->get_template({file=>'tool.tt'}); $t->param(authorized=>_staff_allowed(),plugin_version=>$VERSION,schema_version=>$SCHEMA_VERSION,tested_koha=>$TESTED_KOHA_VERSION); $self->output_html($t->output) }
sub intranet_head { return '<link rel="stylesheet" href="/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation.css">' }
sub intranet_js { my ($self,$args)=@_; return '' unless ($args->{page}//'') =~ m{circulation-home\.pl\z}; my $url='/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3ACom%3A%3AJunaidZaidiLibrary%3A%3ADigitalCirculation&method=tool'; return qq{<script src="/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation.js" data-jzl-url="$url"></script>} }

1;
