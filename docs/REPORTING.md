# Native Koha Saved Reports

Phase 6 / v0.4.0 provisions ten non-public, tabular reports in Koha's native Saved
Reports subsystem under **Digital Circulation / eBooks**. The plugin retains
schema 1; reporting adds no plugin table and never reads
Koha's physical `issues` table as a digital-circulation source.

The authoritative sources are `plugin_jzl_ebook_requests`,
`plugin_jzl_ebook_loans`, `plugin_jzl_ebook_renewals`, and
`plugin_jzl_ebook_events`, joined only to Koha bibliographic, branch, patron
category, and staff metadata needed for labels and controlled filters.
“Department” means the patron's Koha `categorycode`, displayed using the
category description. Missing values are shown as `Unknown / Not recorded`.

Every managed report includes Koha's native `<<Item type|itemtypes>>` runtime
parameter. The SQL reads `item-level_itypes` at execution time: value `1`
selects `items.itype`; other values select `biblioitems.itemtype`. A distinct
`(biblionumber, item_type)` mapping plus `EXISTS` filtering prevents multiple
items from multiplying plugin lifecycle rows. An empty selection includes
mapped and unmapped biblios; a selected type includes only matching biblios.

Managed definitions are ownership-marked in `saved_sql.notes`. Installation
creates missing report-group authorized values and missing reports in one
transaction. A normal upgrade is idempotent and preserves locally changed
managed rows. The configuration page reports missing, changed, duplicate, or
conflicting definitions. An authorized administrator can explicitly repair
changed definitions after a CSRF-protected confirmation; repair never updates
duplicates, unknown ownership markers, or conflicting group codes.

All reports are non-public, use explicit output columns, and accept native
Koha runtime parameters. Date ranges are inclusive through the end date.
Branch and department selectors use Koha authorized selectors. Audit output
projects only allowlisted JSON values and never returns raw event payloads.
Duplicate a managed report before adapting it for local use.

The report list link is available from plugin configuration. Koha's native
`create_reports` and `execute_reports` permissions continue to govern viewing,
editing, and execution.

Librarian workflow: **More → Reports → Saved reports → Digital Circulation →
eBooks → select report → Item type: EBOOK → Run report**.
