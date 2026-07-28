# State machine

Requests: `PENDING -> APPROVED|REJECTED|CANCELLED`. Authoritative loans:
`ACTIVE -> RETURNED|REVOKED|EXPIRED`, or `ACTIVE -> ACTIVE` through renewal.
Renewal extends the existing due date and increments the renewal counter and
row version. `RETURNED`, `REVOKED`, and `EXPIRED` are terminal; no reactivation
or cross-terminal transition exists. All lifecycle writes lock the same loan
and use the current row version. See
[PHASE5_AUTHORITATIVE_LOAN_LIFECYCLE.md](PHASE5_AUTHORITATIVE_LOAN_LIFECYCLE.md).
