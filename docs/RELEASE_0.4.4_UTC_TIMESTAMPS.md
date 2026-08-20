# Digital Circulation 0.4.4 — UTC timestamp normalization

Date: 2026-08-17

## Fix

Normalize service-generated lifecycle timestamps to UTC before storing/returning them. This prevents Koha installations running in a local timezone (for example Asia/Karachi / PKT) from emitting timezone-less local timestamps that the portal interprets as UTC.

Affected service clocks:
- RequestService
- RequestDecisionService
- LoanIssuanceService
- LoanReturnService

Schema version remains 1. No database schema migration is required. Existing rows created by 0.4.3 are not rewritten automatically.
