# Protected eBook-content eligibility

## Verified authority

Koha and `Koha::Plugin::Com::Ecombranding::EbookContent` own protected PDF uploads and biblio mappings. The adapter contract was traced against the canonical Windows source for EbookContent version `0.1.2` in `koha-plugin-ebook-content`, specifically:

- `Koha/Plugin/Com/Ecombranding/EbookContent.pm`
- `Koha/Plugin/Com/Ecombranding/EbookContent/Controller.pm`
- `Koha/Plugin/Com/Ecombranding/EbookContent/openapi.json`
- `Koha/Plugin/Com/Ecombranding/EbookContent/Path.pm`
- `Koha/Plugin/Com/Ecombranding/EbookContent/Range.pm`
- `MANIFEST`, `MANIFEST.md`, `README.md`, `CHANGELOG.md`, `build-kpz.ps1`, and `build-kpz.sh`
- tests `t/01-range.t` through `t/07-compatibility-source.t`

The plugin declares version `0.1.2`, API namespace `ebookcontent`, and loads its routes from its bundled `openapi.json`. Its package archive is `dist/koha-plugin-ebook-content-0.1.2.kpz`, with SHA-256 `F60B7B022251A14185F2493D5A32BBA23B95D215523344982E6199D5A8E8F659`.

## Route and validation trace

`GET /api/v1/contrib/ebookcontent/ebooks/{biblio_id}/metadata` maps to `Controller::metadata`. After the plugin's API-enabled and service-account checks, the controller calls `EbookContent::validated_mapping($biblio_id)`.

`validated_mapping` reads the plugin's qualified `mappings` table using a parameterized lookup and calls `validate_upload`. That method requires an existing Koha biblio and uploaded-file row, a permanent and non-public upload in category `EBOOK_PDF`, a `.pdf` filename, a safely contained path below Koha's permanent upload directory, a readable non-empty file, and a `%PDF-` signature. It returns the biblio, upload, validated path, size, optional digest, and mapping. Missing, inactive, stale, unsafe, unreadable, and non-PDF mappings throw stable symbolic errors.

The metadata controller converts that result to:

- top level: `biblio_id`, `title`
- `file`: `upload_id`, `original_filename`, `mime_type`, `file_size_bytes`, `sha256`, `category`, `permanent`, `public`, `active`

`GET` and implicit `HEAD` on `/ebooks/{biblio_id}/content` call the same `validated_mapping` method before range handling and file streaming. The adapter therefore reuses the exact validation boundary that proves content is the active protected PDF served by the plugin.

## Selected Perl integration

There is no separately documented cross-plugin metadata method or service/repository class in version `0.1.2`. `validated_mapping` is a non-underscored method on the main plugin class and is the deliberate seam used by both controller actions and the controller tests. The Digital Circulation adapter uses priority-three integration: a narrow wrapper around that exact internal method.

The default loader calls `Koha::Plugins->get_enabled_plugins`, then selects only the installed `Koha::Plugin::Com::Ecombranding::EbookContent` instance and verifies that `validated_mapping` exists. It also requires plugin metadata version `0.1.2`. This uses Koha's documented enabled-plugin discovery and avoids hardcoded plugin directories, server-instance names, Windows reference paths, HTTP, and OAuth.

This boundary is clear and tested in EbookContent itself, but it is not explicitly documented as a public cross-plugin API. A future EbookContent release may change the return shape or error symbols. Pinning the verified version makes such a change fail closed instead of silently granting eligibility.

## Normalized field mapping

| Eligibility field | EbookContent `validated_mapping` source |
|---|---|
| `biblio_id` | `mapping.biblionumber` |
| `title` | `biblio->title` |
| `file.upload_id` | `upload->id` |
| `file.original_filename` | `upload->filename` |
| `file.file_size_bytes` | validated `size` |
| `file.mime_type` | `application/pdf`, matching the controller after PDF validation |
| `file.category` | `EBOOK_PDF`, guaranteed by `validate_upload` |
| `file.public` | false, guaranteed by `validate_upload` |
| `file.permanent` | true, guaranteed by `validate_upload` |
| `file.active` | true, guaranteed by `validated_mapping` |
| `file.sha256` | optional `mapping.sha256_cache` |

The validated filesystem path is deliberately discarded. The adapter normalizes facts but never decides eligibility; `Service::EbookContentEligibility` performs the final contract checks.

## Safe outcomes

The adapter returns only safe categories:

- `PLUGIN_UNAVAILABLE` when discovery/loading or the pinned version fails
- `METHOD_UNAVAILABLE` when `validated_mapping` is absent
- `METADATA_NOT_FOUND` for `MAPPING_NOT_FOUND` or `BIBLIO_NOT_FOUND`
- `MALFORMED_METADATA` for malformed or stale/invalid mapping results
- `BIBLIO_MISMATCH` when the returned mapping does not match the requested biblionumber
- `LOOKUP_EXCEPTION` for an unclassified dependency exception
- `CONTENT_DISABLED` for `MAPPING_INACTIVE`

Raw exceptions, paths, SQL, table names, database details, credentials, and tokens are never returned. Dependency absence and unclassified exceptions become `CONTENT_LOOKUP_UNAVAILABLE`; missing mappings become `MISSING_PROTECTED_CONTENT`; malformed/mismatched mappings remain `INVALID_CONTENT_MAPPING`; inactive mappings become `CONTENT_DISABLED`.

## Remaining Debian verification

Windows tests use dependency injection and deterministic plugin doubles. Before enabling request creation, verify on the controlled Koha 26.05 host that `Koha::Plugins->get_enabled_plugins` returns the installed EbookContent v0.1.2 instance and that mapped, missing, inactive, and stale synthetic records produce the documented outcomes. This unit does not claim live cross-plugin verification.
