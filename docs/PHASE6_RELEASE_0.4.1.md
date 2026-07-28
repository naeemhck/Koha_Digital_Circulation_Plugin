# Digital Circulation 0.4.1

This corrective release makes the ten managed Koha Saved Reports compatible
with Koha 26.05 report validation. Every stored report now begins with
`SELECT`; there is no leading comment, parenthesis, byte-order mark, or CTE.

The report names, stable managed slugs, native `<<Item type|itemtypes>>`
parameter, privacy posture, lifecycle authority, and schema version remain
unchanged. Item-type matching still uses a distinct dual-mode mapping and an
`EXISTS` predicate, so multiple Koha item rows cannot multiply lifecycle rows.

During upgrade, only a report whose SQL hash exactly matches the known
unmodified 0.4.0 canonical definition is updated automatically. Drifted
reports remain protected until an authorized administrator uses Repair.
