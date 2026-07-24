# Phase 2A controlled deployment and verification

This procedure applies to `JunaidZaidiLibrary-DigitalCirculation-v0.2.0-rc1.kpz` on a controlled Koha 26.05 test instance. Do not use production patrons, bibliographic records, OAuth clients, or protected files during release-candidate verification.

## Pre-install checks

1. Back up the Koha database using the institution's approved backup procedure and verify that the backup is readable.
2. Preserve the currently installed Digital Circulation KPZ and record its plugin version and schema version.
3. Record the target Koha maintenance version and confirm it is compatible with minimum version `26.05.00.000`.
4. In Manage Plugins, confirm `Koha::Plugin::Com::Ecombranding::EbookContent` version `0.1.2` is installed and enabled.
5. Identify a dedicated test OAuth service account and record its exact Koha borrowernumber. Do not put its client ID or secret in this document.
6. Confirm that account has the `circulate_remaining_permissions` Koha gateway permission. The plugin allowlist remains an additional mandatory check.
7. Select only synthetic test patrons and bibliographic records. Prepare one eligible protected PDF mapping and one ineligible record.
8. Validate the KPZ checksum against the release record, inspect every archive member, and retain the old KPZ for rollback.

## Installation or update

Use Koha's supported staff interface: **Administration → Manage Plugins**. Select the install or upgrade action, upload the inspected RC KPZ, and confirm that Koha reports plugin version `0.2.0` and schema version `1`. The repository does not establish a portable CLI installation command; any site-specific CLI process requires separate local approval and verification.

Restart or reload Koha services only according to the site's established plugin-deployment procedure. Confirm the plugin loads before configuration.

## Configure the service actor

1. Open **Administration → Manage Plugins**.
2. Choose **Configure** for Digital Circulation.
3. Enter only the test OAuth service actor's exact Koha borrowernumber.
4. Save through the CSRF-protected form.
5. Reopen the form and verify the canonical comma-separated value.
6. Confirm that the Circulation link still opens the separate read-only operational tool.
7. To disable portal request creation immediately, submit the configuration with the field blank.

The configured value is a Koha borrowernumber, not an OAuth client ID, client secret, access token, patron password, or database credential.

## OAuth test prerequisites

The OAuth client must authenticate as the same Koha patron whose borrowernumber is allowlisted. Use an ephemeral test token with the minimum required gateway permission. Load secrets into the shell from the site's approved secret mechanism; never paste them into this document, commit them, or save them beside test output.

Prepare the non-secret variables:

```bash
export KOHA_BASE_URL='https://koha-test.example.invalid'
export SERVICE_ACTOR_BORROWERNUMBER='TEST_ACTOR_ID'
export TEST_PATRON_ID='TEST_PATRON_ID'
export TEST_BIBLIO_ID='TEST_BIBLIO_ID'
```

Load `KOHA_ACCESS_TOKEN` from the approved protected secret source without writing it into shell history. Confirm every variable is present:

```bash
: "${KOHA_BASE_URL:?}"
: "${KOHA_ACCESS_TOKEN:?}"
: "${SERVICE_ACTOR_BORROWERNUMBER:?}"
: "${TEST_PATRON_ID:?}"
: "${TEST_BIBLIO_ID:?}"
```

Generate request identifiers:

```bash
PORTAL_REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
IDEMPOTENCY_KEY="$(uuidgen | tr '[:upper:]' '[:lower:]')"
CORRELATION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
ENDPOINT="${KOHA_BASE_URL%/}/api/v1/contrib/jzl-digital-circulation/requests"
```

Run the creation request. The authorization header is supplied from the environment and must not be logged:

```bash
curl --silent --show-error \
  --output /tmp/jzl-phase2a-response.json \
  --write-out '%{http_code}\n' \
  --request POST "$ENDPOINT" \
  --header "Authorization: Bearer ${KOHA_ACCESS_TOKEN}" \
  --header 'Content-Type: application/json' \
  --header "Idempotency-Key: ${IDEMPOTENCY_KEY}" \
  --header "X-Correlation-ID: ${CORRELATION_ID}" \
  --data "{\"portal_request_id\":\"${PORTAL_REQUEST_ID}\",\"patron_id\":${TEST_PATRON_ID},\"biblio_id\":${TEST_BIBLIO_ID}}"
```

Inspect only the sanitized JSON response, then securely remove the temporary response file. Never enable shell tracing while tokens are loaded.

## Required live cases

Use fresh synthetic identifiers as appropriate and record only status, stable error code, request ID, and correlation ID.

| Case | Expected result |
| --- | --- |
| No bearer token | Koha authentication failure |
| Authenticated actor not in plugin allowlist | `403 SERVICE_ACCOUNT_NOT_AUTHORIZED` |
| Missing `Idempotency-Key` | `400 INVALID_IDEMPOTENCY_KEY` |
| Missing `X-Correlation-ID` | `400 INVALID_INPUT` |
| Missing, malformed, or additional body fields | `400 INVALID_INPUT` |
| Nonexistent synthetic patron | `404 PATRON_NOT_FOUND` |
| Nonexistent biblio | `404 BIBLIO_NOT_FOUND` |
| Existing but ineligible content | `409 CONTENT_NOT_ELIGIBLE` |
| Valid protected EbookContent mapping | `201`, one pending request |
| Same idempotency key and identical body | `200`, `idempotent_replay=true` |
| Same key with changed patron, biblio, or portal request ID | `409 IDEMPOTENCY_CONFLICT` |
| New key for the same pending patron/biblio | `200`, `duplicate_pending=true` |

For the replay, repeat the original request without regenerating its body or idempotency key. For duplicate-pending behavior, retain patron/biblio, use a new valid portal request ID and idempotency key, and use a new correlation ID.

## Read-only database verification

Run read-only queries through the approved Koha database administration channel and only against plugin-owned tables:

```sql
SELECT request_id, portal_request_id, portal_idempotency_key, source,
       patron_id, biblio_id, status, requested_at, row_version
FROM plugin_jzl_ebook_requests
WHERE portal_request_id = 'SYNTHETIC_PORTAL_REQUEST_UUID';

SELECT event_id, event_type, aggregate_type, aggregate_id, request_id,
       patron_id, biblio_id, actor_patron_id, source, correlation_id
FROM plugin_jzl_ebook_events
WHERE correlation_id = 'SYNTHETIC_CORRELATION_UUID';

SELECT COUNT(*) FROM plugin_jzl_ebook_loans
WHERE patron_id = SYNTHETIC_PATRON_ID AND biblio_id = SYNTHETIC_BIBLIO_ID;

SELECT COUNT(*)
FROM plugin_jzl_ebook_renewals n
JOIN plugin_jzl_ebook_loans l ON l.loan_id = n.loan_id
WHERE l.patron_id = SYNTHETIC_PATRON_ID
  AND l.biblio_id = SYNTHETIC_BIBLIO_ID;
```

Confirm one pending request and one `REQUEST_CREATED` event after creation. Exact replay and duplicate-pending calls must create neither a second request nor a second event. `actor_patron_id` must equal the OAuth service actor, while `patron_id` is the subject patron. The event correlation ID must match the creation call. Loan and renewal counts must remain zero. Do not query or modify native Koha circulation tables for this verification.

## Transaction rollback test

Perform rollback verification only on a disposable Koha/MariaDB test instance. Use an approved test-only fault-injection mechanism that makes the audit-event repository fail after request insertion but before commit. Invoke one synthetic request, confirm the API returns the safe unavailable response, and verify that neither the request nor event exists afterward. Remove the fault injection and repeat successfully. Do not corrupt tables, disable constraints, alter production privileges, or perform this scenario against production data.

## Disable and rollback

Blank the configured service-account allowlist to deny request creation immediately. If code rollback is required, use Manage Plugins to reinstall the previously preserved and inspected KPZ according to the site's change process. Plugin configuration and institutional request/audit data remain preserved by the current update/uninstall policy. Do not manually delete plugin rows during routine rollback.

Record the RC checksum, installation time, Koha version, installed EbookContent version, synthetic record IDs, test outcomes, and rollback decision in the controlled deployment record. Do not record tokens or client secrets.
