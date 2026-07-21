-- IRREVERSIBLE. Run only after verified backup, retention approval, and plugin disablement.
START TRANSACTION;
DROP TABLE IF EXISTS plugin_jzl_ebook_events;
DROP TABLE IF EXISTS plugin_jzl_ebook_renewals;
DROP TABLE IF EXISTS plugin_jzl_ebook_loans;
DROP TABLE IF EXISTS plugin_jzl_ebook_requests;
DROP TABLE IF EXISTS plugin_jzl_ebook_schema_versions;
COMMIT;
