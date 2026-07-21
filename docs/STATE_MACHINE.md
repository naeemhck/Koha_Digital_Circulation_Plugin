# State machine

Requests: `PENDING -> APPROVED|REJECTED|CANCELLED`. Renewals: the same. Loans: `ACTIVE -> RENEWAL_PENDING|RETURNED|EXPIRED|REVOKED`, and `RENEWAL_PENDING -> ACTIVE` after either renewal decision. All other transitions, duplicate decisions, terminal reactivation, loans without an approved portal request, more than one loan per request, and multiple pending renewals are forbidden. Phase 1 encodes and tests rules but exposes no mutation route.
