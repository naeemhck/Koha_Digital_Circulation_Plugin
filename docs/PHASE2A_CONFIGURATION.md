# Phase 2A portal service-account configuration

The plugin-owned configuration key is `portal_service_account_ids`. It contains only the exact Koha borrowernumbers permitted to act as the portal OAuth service actor. The accepted format is a comma-delimited list of positive decimal integers, for example `10001,10002`.

Configure the value from the plugin's Configure action in Koha's Manage Plugins interface. For example, `123, 456,123` is stored canonically as `123,456`. Whitespace and empty comma-separated entries are ignored, duplicates are removed, and every non-empty entry must be a complete positive decimal integer. Invalid submissions do not overwrite the last valid value.

The value is persisted with Koha's supported plugin `store_data` API and read with `retrieve_data`. Blank input intentionally stores an empty value and disables portal request creation. Missing, blank, unreadable, or malformed stored configuration authorizes nobody; there is no default authorized actor.

The configured identifiers are Koha borrowernumbers, not OAuth client IDs or credentials. Determine the service actor's borrowernumber from the controlled Koha patron/staff record associated with the OAuth-authenticated service account, then enter only that numeric identifier. Never enter a client secret, bearer token, password, API token, or database credential.

`configure` remains restricted to Koha's Manage Plugins flow and uses a session-bound `Koha::Token` CSRF check for POST submissions. The Circulation navigation continues to call `method=tool`, which remains the separate read-only operational interface. No configuration route exists in OpenAPI.

On controlled Debian/Koha 26.05, verify Manage Plugins authorization, GET-without-write behavior, CSRF rejection, POST save/clear behavior, canonical redisplay, and persistence across worker restarts. Then verify the OAuth-authenticated actor's `koha.user` borrowernumber matches the configured identifier. No live Koha form execution is claimed by Windows dependency-double tests.
