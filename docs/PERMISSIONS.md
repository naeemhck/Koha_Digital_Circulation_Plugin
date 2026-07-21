# Permissions

Koha 26.05 OpenAPI enforces authentication and `circulate => circulate_remaining_permissions` for all business routes and the limited diagnostics. This is the narrowest supported existing circulation permission found; ordinary patrons are denied. The same server-side permission check protects the staff tool. Identity comes only from Koha's authenticated session/OAuth context. Phase 2 must introduce or confirm a least-privilege service-account permission before writes; superlibrarian is not an integration shortcut.
