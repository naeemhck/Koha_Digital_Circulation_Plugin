# Data model

Schema version 1 owns `plugin_jzl_ebook_requests`, `plugin_jzl_ebook_loans`, `plugin_jzl_ebook_renewals`, `plugin_jzl_ebook_events`, and `plugin_jzl_ebook_schema_versions`. Status, source, timestamp consistency, due ordering, and positive row-version checks are database constraints. Generated nullable unique guards enforce one pending patron/biblio request and one pending renewal per loan. Unique request references/idempotency keys and unique loan request IDs provide idempotency foundations. Request-to-loan-to-renewal/event foreign keys use `ON DELETE RESTRICT`; patrons and biblios are validated by services without hard foreign keys so historical institutional records do not block normal Koha record lifecycle.

Events are append-only by application policy. List output deliberately omits `payload_json`. No credentials, tokens, cookies, protected URLs, reader tokens, or unnecessary personal data belong in events.
