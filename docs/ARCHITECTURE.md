# Architecture

Koha plugin routes call read-only controllers, which call allowlisted repositories. Services contain reusable validation and transition policy. Plugin-owned MariaDB tables retain authoritative-domain-shaped requests, loans, renewals, and append-only events, but Phase 1 loads only explicitly guarded test fixtures. The server-rendered staff tool uses the same authenticated read API. No Koha core or portal code is changed.

The API/OpenAPI loader is the native Koha 26.05 plugin route mechanism. Navigation uses the official page-aware `intranet_js` hook only on `circulation-home.pl`; it adds a single “Digital eBook Requests” link to the circulation navigation list. This minimal DOM insertion is the only release-sensitive detail and must be regression-tested after a Koha template update.

Runtime package paths, including the root-level `tool.tt` required by `get_template`, are documented in `PACKAGE_LAYOUT.md`.
