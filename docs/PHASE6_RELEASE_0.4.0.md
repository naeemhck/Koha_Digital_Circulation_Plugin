# Digital Circulation 0.4.0

Version **0.4.0** delivers Phase 6 native Koha Saved Reports while retaining
schema version **1**, minimum Koha version **26.05.00.000**, the existing REST
namespace, and all authoritative lifecycle behavior.

It provisions a non-public **Digital Circulation / eBooks** report collection
with ten ownership-marked definitions. Provisioning is idempotent, detects
conflicts, duplicates, and drift, and preserves librarian copies. Explicit
administrator-confirmed repair is CSRF protected.

Each report uses Koha's `<<Item type|itemtypes>>` parameter. The query selects
the correct catalogue source at execution time from `item-level_itypes`, using
`items.itype` for item-level configuration and `biblioitems.itemtype` for
record-level configuration. A distinct catalogue mapping plus `EXISTS`
prevents multi-item biblios from multiplying lifecycle results.

This release provides no Guided Report Wizard module, separate reporting
dashboard, or portal reporting page. It does not create `EBOOK`; if the
institution requires that code, a Koha administrator provisions it as a
deployment-time catalogue action. Native `issues` remains outside the digital
loan source of truth.
