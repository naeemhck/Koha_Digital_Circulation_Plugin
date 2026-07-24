use Modern::Perl;
use Test::More;

my $path = 'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation.pm';
open my $fh, '<', $path or die $!;
my $source = do { local $/; <$fh> };
my @create = $source =~ /(CREATE TABLE IF NOT EXISTS `\$[rlnve]` \(.*?\) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci)/sg;
is scalar @create, 5, 'exactly five CREATE TABLE statements';
for my $index ( 0 .. $#create ) {
    is $create[$index] =~ tr/(//, $create[$index] =~ tr/)//, 'CREATE TABLE ' . ( $index + 1 ) . ' has balanced parentheses';
}
unlike $create[3], qr/ON DELETE RESTRICT\s*\)\s*\) ENGINE/s, 'events table has no redundant closing parenthesis';
for my $table (qw(requests loans renewals events schema_versions)) {
    like $source, qr/table\('\Q$table\E'\)/, "expected table $table";
}
like $source, qr/INSERT IGNORE INTO `\$v`/, 'schema version insertion is retry-safe';
is scalar( () = $source =~ /CREATE TABLE IF NOT EXISTS/g ), 5, 'all tables are retry-safe';
like $source, qr/\$self->_migration_001\(\$dbh\);\s*\$self->_verify_schema\(\$dbh\);/s, 'schema is verified before install succeeds';
like $source, qr/Schema version 1 was not recorded/, 'schema version 1 is verified';
like $source, qr/SELECT GET_LOCK\(\?, 30\)/, 'GET_LOCK is parameterized';
like $source, qr/lock_acquired == 1/, 'GET_LOCK success is checked';
like $source, qr/SELECT RELEASE_LOCK\(\?\)/, 'RELEASE_LOCK is attempted';
like $source, qr/pending_guard VARCHAR\(80\).*?status = 'PENDING'.*?ELSE NULL.*?STORED/s, 'request uniqueness applies only while pending';
like $source, qr/UNIQUE KEY jzl_req_pending_uq \(pending_guard\)/, 'request pending guard is unique';
unlike $source, qr/UNIQUE[^\n]*patron_id[^\n]*biblio_id[^\n]*status/i, 'historical request statuses are not globally unique';
like $source, qr/pending_guard BIGINT UNSIGNED.*?status = 'PENDING'.*?ELSE NULL.*?STORED/s, 'renewal uniqueness applies only while pending';
like $source, qr/sub uninstall \{.*?return 1;.*?\}/s, 'uninstall preserves data';
unlike $source, qr/sub uninstall \{.*?DROP TABLE.*?\}/s, 'uninstall does not drop tables';
done_testing;
