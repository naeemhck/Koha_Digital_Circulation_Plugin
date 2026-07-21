# Read-only API

Base: `/api/v1/contrib/jzl-digital-circulation`. GET endpoints are `/health`, `/version`, `/requests`, `/requests/{request_id}`, `/loans`, `/loans/{loan_id}`, `/renewals`, `/renewals/{renewal_id}`, `/events`, and `/events/{event_id}`. Lists support documented status/identifier/date filters, `page` 1+, `per_page` 1–100, allowlisted sort fields, and `asc|desc`; ordering includes the primary key as a stable tiebreaker. Errors use safe codes and never return SQL, exceptions, credentials, or stacks. No POST, PUT, PATCH, or DELETE path exists.
