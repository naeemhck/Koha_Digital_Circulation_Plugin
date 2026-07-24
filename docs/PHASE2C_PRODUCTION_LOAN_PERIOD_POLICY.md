# Phase 2C — Production loan-period policy

This unit adds the authoritative plugin configuration and production policy that
calculates digital loan due dates for `LoanIssuanceService`.

Staff issuance REST exposure is documented in
`docs/PHASE2C_STAFF_LOAN_ISSUANCE_HTTP_API.md`. The staff Issue Loan UI is
documented in `docs/PHASE2C_STAFF_LOAN_ISSUANCE_UI.md`.

## Configuration key

`default_loan_duration_days`

Stored through the Koha plugin `store_data` / `retrieve_data` API. No schema
migration and no configuration table are introduced.

## Valid range

Whole calendar days from **1** through **365** inclusive.

This range is a plugin safety boundary, not a production default.

## Blank or missing behavior

Blank, whitespace-only, or missing configuration means digital loan issuance is
not operationally configured. The production policy fails closed so
`LoanIssuanceService` returns:

`INVALID_LOAN_PERIOD`

No hidden default duration is invented. Blank is not treated as zero.

## Calendar-day calculation

`ConfiguredLoanPeriodPolicy->resolve_due_at` receives the exact `started_at`
supplied by `LoanIssuanceService`.

It:

- adds the configured whole calendar days;
- preserves the wall-clock time from `started_at`;
- returns canonical `YYYY-MM-DD HH:MM:SS`;
- does not call a clock;
- does not use request creation or approval timestamps;
- does not accept caller-supplied durations.

Day arithmetic uses UTC-noon calendar stepping so daylight-saving transitions do
not alter the intended calendar-day span when preserving wall-clock time.

## Trusted started_at source

`started_at` comes only from the issuance service clock path. The policy never
reads browser time, CGI time, or configuration timestamps.

## Production wiring

`DigitalCirculation->_build_loan_issuance_service` constructs
`LoanIssuanceService` with:

- plugin table resolver;
- `ConfiguredLoanPeriodPolicy` as `due_date_policy`;
- optional diagnostics.

`StaffLoanIssuanceApplication` uses that factory when a plugin is supplied and
no issuance service is injected.

## Failure behavior

Policy failure shape:

```perl
{ ok => 0, code => 'INVALID_LOAN_PERIOD' }
```

Successful policy shape:

```perl
{ ok => 1, due_at => 'YYYY-MM-DD HH:MM:SS' }
```

## Configure-page behavior

The plugin configuration page includes:

**Default digital loan duration (days)**

with min `1`, max `365`, step `1`, and explanatory text stating that approval
alone does not create a loan or grant protected-content access.

Server-side validation is authoritative. Invalid submissions do not overwrite a
previous valid duration. Unrelated `portal_service_account_ids` values are
preserved when the duration field is invalid, and the reverse is also true.
CSRF validation remains required.

## Explicit non-goals retained from this unit

- no live loan creation through deployment of this policy alone
- no schema change
- no native Koha issue
- no reader/access behavior

## Current integration status

The controlled authenticated staff issuance endpoint and Issue Loan staff UI
now exist. See `docs/PHASE2C_STAFF_LOAN_ISSUANCE_HTTP_API.md` and
`docs/PHASE2C_STAFF_LOAN_ISSUANCE_UI.md`.
