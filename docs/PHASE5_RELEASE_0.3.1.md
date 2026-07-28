# Digital Circulation 0.3.1

Version **0.3.1** is the Phase 5 renewal and revocation actor-context hotfix.
It parenthesizes trusted-field `map` expressions before appending the
authenticated `actor_id`, preventing Perl list-operator precedence from
consuming the actor pair.

The HTTP contracts, exact correlation rules, row-version concurrency,
idempotency, lifecycle policy, schema version **1**, minimum Koha version
**26.05.00.000**, namespace, and native-circulation isolation are unchanged.
No portal source change or database migration is required.
