package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Service::SavedReportDefinitions;

use Modern::Perl;
use Digest::SHA qw(sha256_hex);

use constant GROUP_CODE     => 'DIGCIRC';
use constant GROUP_LABEL    => 'Digital Circulation';
use constant SUBGROUP_CODE  => 'EBOOKS';
use constant SUBGROUP_LABEL => 'eBooks';
use constant REPORT_AREA    => 'CIRC';
use constant DEFINITION_VERSION => 3;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        requests_table => $args{requests_table} || 'plugin_jzl_ebook_requests',
        loans_table    => $args{loans_table}    || 'plugin_jzl_ebook_loans',
        events_table   => $args{events_table}   || 'plugin_jzl_ebook_events',
    }, $class;
}

sub group {
    return {
        code  => GROUP_CODE,
        label => GROUP_LABEL,
    };
}

sub subgroup {
    return {
        code        => SUBGROUP_CODE,
        label       => SUBGROUP_LABEL,
        parent_code => GROUP_CODE,
    };
}

sub saved_reports_url {
    return '/cgi-bin/koha/reports/guided_reports.pl?op=list&filter_set=1&filter_group='
        . GROUP_CODE
        . '&filter_subgroup='
        . SUBGROUP_CODE;
}

sub ownership_prefix {
    return 'DigitalCirculation managed report:';
}

sub _marker {
    my ( $slug, $description ) = @_;
    return ownership_prefix() . " $slug; definition_version=" . DEFINITION_VERSION
        . "; $description Duplicate this report before customization.";
}

sub _date_params {
    return (
        { name => 'Start date', type => 'date', required => 1 },
        { name => 'End date',   type => 'date', required => 1 },
    );
}

sub _scope_params {
    return (
        { name => 'Branch',     type => 'branches:all', required => 0 },
        { name => 'Department', type => 'categorycode:all', required => 0 },
    );
}

sub reports {
    my ($self) = @_;
    my $r = $self->{requests_table};
    my $l = $self->{loans_table};
    my $e = $self->{events_table};

    my @definitions = (
        {
            slug => 'lifecycle_summary',
            name => 'eBook lifecycle summary',
            description => 'Aggregate authoritative request, loan, and lifecycle-event counts for an inclusive date range.',
            parameters => [ _date_params(), _scope_params() ],
            expected_columns => [qw(requests_received pending_requests approved_requests rejected_requests cancelled_requests loans_issued active_loans returned_loans revoked_loans expired_loans renewal_events return_events revocation_events expiry_events)],
            privacy => 'aggregate-no-pii',
            sql => qq{
WITH request_base AS (
    SELECT req.request_id, req.status
    FROM $r req
    JOIN borrowers pat ON pat.borrowernumber = req.patron_id
    WHERE req.requested_at >= <<Start date|date>>
      AND req.requested_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
), loan_base AS (
    SELECT loan.loan_id, loan.status
    FROM $l loan
    JOIN borrowers pat ON pat.borrowernumber = loan.patron_id
    WHERE loan.started_at >= <<Start date|date>>
      AND loan.started_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
), event_base AS (
    SELECT evt.event_id, evt.event_type
    FROM $e evt
    JOIN borrowers pat ON pat.borrowernumber = evt.patron_id
    WHERE evt.occurred_at >= <<Start date|date>>
      AND evt.occurred_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
)
SELECT
    (SELECT COUNT(*) FROM request_base) AS requests_received,
    (SELECT COUNT(*) FROM request_base WHERE status = 'PENDING') AS pending_requests,
    (SELECT COUNT(*) FROM request_base WHERE status = 'APPROVED') AS approved_requests,
    (SELECT COUNT(*) FROM request_base WHERE status = 'REJECTED') AS rejected_requests,
    (SELECT COUNT(*) FROM request_base WHERE status = 'CANCELLED') AS cancelled_requests,
    (SELECT COUNT(*) FROM loan_base) AS loans_issued,
    (SELECT COUNT(*) FROM loan_base WHERE status = 'ACTIVE') AS active_loans,
    (SELECT COUNT(*) FROM loan_base WHERE status = 'RETURNED') AS returned_loans,
    (SELECT COUNT(*) FROM loan_base WHERE status = 'REVOKED') AS revoked_loans,
    (SELECT COUNT(*) FROM loan_base WHERE status = 'EXPIRED') AS expired_loans,
    (SELECT COUNT(*) FROM event_base WHERE event_type = 'LOAN_RENEWED') AS renewal_events,
    (SELECT COUNT(*) FROM event_base WHERE event_type = 'LOAN_RETURNED') AS return_events,
    (SELECT COUNT(*) FROM event_base WHERE event_type = 'LOAN_REVOKED') AS revocation_events,
    (SELECT COUNT(*) FROM event_base WHERE event_type = 'LOAN_EXPIRED') AS expiry_events
},
        },
        {
            slug => 'requests_awaiting_action',
            name => 'Requests awaiting action',
            description => 'Operational queue for pending requests and approved requests awaiting issuance.',
            parameters => [
                _date_params(), _scope_params(),
                { name => 'Request status', type => 'text', required => 0 },
            ],
            expected_columns => [qw(request_id request_date title biblio_id patron_cardnumber patron_category department branch status row_version last_updated)],
            privacy => 'operational-limited-cardnumber',
            sql => qq{
SELECT
    req.request_id AS request_id,
    req.requested_at AS request_date,
    bib.title AS title,
    req.biblio_id AS biblio_id,
    pat.cardnumber AS patron_cardnumber,
    pat.categorycode AS patron_category,
    COALESCE(cat.description, 'Unknown / Not recorded') AS department,
    pat.branchcode AS branch,
    req.status AS status,
    req.row_version AS row_version,
    req.updated_at AS last_updated
FROM $r req
JOIN borrowers pat ON pat.borrowernumber = req.patron_id
LEFT JOIN categories cat ON cat.categorycode = pat.categorycode
LEFT JOIN biblio bib ON bib.biblionumber = req.biblio_id
LEFT JOIN $l loan ON loan.request_id = req.request_id
WHERE req.requested_at >= <<Start date|date>>
  AND req.requested_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
  AND (req.status = 'PENDING' OR (req.status = 'APPROVED' AND loan.loan_id IS NULL))
  AND (<<Request status>> = '' OR (<<Request status>> IN ('PENDING','APPROVED') AND req.status = <<Request status>>))
  AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
  AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
ORDER BY req.requested_at, req.request_id
},
        },
        {
            slug => 'request_history',
            name => 'eBook request history',
            description => 'One row per authoritative request with decision and issuance outcome.',
            parameters => [
                _date_params(), _scope_params(),
                { name => 'Request status', type => 'text', required => 0 },
                { name => 'Title contains', type => 'text', required => 0 },
            ],
            expected_columns => [qw(request_id title request_status request_date decision_date staff_actor_id patron_category department branch loan_issued)],
            privacy => 'limited-operational-no-contact',
            sql => qq{
SELECT
    req.request_id AS request_id,
    bib.title AS title,
    req.status AS request_status,
    req.requested_at AS request_date,
    CASE
        WHEN req.status = 'APPROVED' THEN req.approved_at
        WHEN req.status = 'REJECTED' THEN req.rejected_at
        WHEN req.status = 'CANCELLED' THEN req.cancelled_at
        ELSE NULL
    END AS decision_date,
    CASE
        WHEN req.status = 'APPROVED' THEN req.approved_by
        WHEN req.status = 'REJECTED' THEN req.rejected_by
        ELSE NULL
    END AS staff_actor_id,
    pat.categorycode AS patron_category,
    COALESCE(cat.description, 'Unknown / Not recorded') AS department,
    pat.branchcode AS branch,
    CASE WHEN loan.loan_id IS NULL THEN 0 ELSE 1 END AS loan_issued
FROM $r req
JOIN borrowers pat ON pat.borrowernumber = req.patron_id
LEFT JOIN categories cat ON cat.categorycode = pat.categorycode
LEFT JOIN biblio bib ON bib.biblionumber = req.biblio_id
LEFT JOIN $l loan ON loan.request_id = req.request_id
WHERE req.requested_at >= <<Start date|date>>
  AND req.requested_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
  AND (<<Request status>> = '' OR (<<Request status>> IN ('PENDING','APPROVED','REJECTED','CANCELLED') AND req.status = <<Request status>>))
  AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
  AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
  AND (<<Title contains>> = '' OR bib.title LIKE CONCAT('%', LEFT(<<Title contains>>, 100), '%'))
ORDER BY req.requested_at DESC, req.request_id DESC
},
        },
        {
            slug => 'active_loans',
            name => 'Active digital loans',
            description => 'Current authoritative ACTIVE digital loans only.',
            parameters => [ _scope_params() ],
            expected_columns => [qw(loan_id request_id title biblio_id patron_cardnumber patron_category department branch start_date due_date renewal_count row_version days_remaining overdue)],
            privacy => 'operational-limited-cardnumber',
            sql => qq{
SELECT
    loan.loan_id AS loan_id,
    loan.request_id AS request_id,
    bib.title AS title,
    loan.biblio_id AS biblio_id,
    pat.cardnumber AS patron_cardnumber,
    pat.categorycode AS patron_category,
    COALESCE(cat.description, 'Unknown / Not recorded') AS department,
    pat.branchcode AS branch,
    loan.started_at AS start_date,
    loan.due_at AS due_date,
    loan.renewal_count AS renewal_count,
    loan.row_version AS row_version,
    TIMESTAMPDIFF(DAY, UTC_TIMESTAMP(), loan.due_at) AS days_remaining,
    CASE WHEN loan.due_at < UTC_TIMESTAMP() THEN 1 ELSE 0 END AS overdue
FROM $l loan
JOIN borrowers pat ON pat.borrowernumber = loan.patron_id
LEFT JOIN categories cat ON cat.categorycode = pat.categorycode
LEFT JOIN biblio bib ON bib.biblionumber = loan.biblio_id
WHERE loan.status = 'ACTIVE'
  AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
  AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
ORDER BY loan.due_at, loan.loan_id
},
        },
        {
            slug => 'completed_loans',
            name => 'Completed digital loans',
            description => 'Returned, revoked, and expired authoritative loans using the matching terminal timestamp.',
            parameters => [
                _date_params(), _scope_params(),
                { name => 'Terminal status', type => 'text', required => 0 },
                { name => 'Title contains', type => 'text', required => 0 },
            ],
            expected_columns => [qw(loan_id title patron_category department branch issue_date due_date terminal_status terminal_timestamp renewal_count loan_duration_days)],
            privacy => 'limited-operational-no-patron-id',
            sql => qq{
SELECT
    loan.loan_id AS loan_id,
    bib.title AS title,
    pat.categorycode AS patron_category,
    COALESCE(cat.description, 'Unknown / Not recorded') AS department,
    pat.branchcode AS branch,
    loan.started_at AS issue_date,
    loan.due_at AS due_date,
    loan.status AS terminal_status,
    CASE
        WHEN loan.status = 'RETURNED' THEN loan.returned_at
        WHEN loan.status = 'REVOKED' THEN loan.revoked_at
        WHEN loan.status = 'EXPIRED' THEN loan.expired_at
    END AS terminal_timestamp,
    loan.renewal_count AS renewal_count,
    TIMESTAMPDIFF(DAY, loan.started_at,
        CASE
            WHEN loan.status = 'RETURNED' THEN loan.returned_at
            WHEN loan.status = 'REVOKED' THEN loan.revoked_at
            WHEN loan.status = 'EXPIRED' THEN loan.expired_at
        END
    ) AS loan_duration_days
FROM $l loan
JOIN borrowers pat ON pat.borrowernumber = loan.patron_id
LEFT JOIN categories cat ON cat.categorycode = pat.categorycode
LEFT JOIN biblio bib ON bib.biblionumber = loan.biblio_id
WHERE loan.status IN ('RETURNED','REVOKED','EXPIRED')
  AND CASE
        WHEN loan.status = 'RETURNED' THEN loan.returned_at
        WHEN loan.status = 'REVOKED' THEN loan.revoked_at
        WHEN loan.status = 'EXPIRED' THEN loan.expired_at
      END >= <<Start date|date>>
  AND CASE
        WHEN loan.status = 'RETURNED' THEN loan.returned_at
        WHEN loan.status = 'REVOKED' THEN loan.revoked_at
        WHEN loan.status = 'EXPIRED' THEN loan.expired_at
      END < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
  AND (<<Terminal status>> = '' OR (<<Terminal status>> IN ('RETURNED','REVOKED','EXPIRED') AND loan.status = <<Terminal status>>))
  AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
  AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
  AND (<<Title contains>> = '' OR bib.title LIKE CONCAT('%', LEFT(<<Title contains>>, 100), '%'))
ORDER BY terminal_timestamp DESC, loan.loan_id DESC
},
        },
        {
            slug => 'renewal_activity',
            name => 'eBook renewal activity',
            description => 'Validated safe fields extracted from authoritative LOAN_RENEWED events.',
            parameters => [ _date_params(), _scope_params() ],
            expected_columns => [qw(event_date loan_id request_id title patron_category department previous_due_date new_due_date renewal_number source actor_category)],
            privacy => 'safe-event-fields-no-raw-json',
            sql => qq{
SELECT
    evt.occurred_at AS event_date,
    evt.loan_id AS loan_id,
    evt.request_id AS request_id,
    bib.title AS title,
    pat.categorycode AS patron_category,
    COALESCE(cat.description, 'Unknown / Not recorded') AS department,
    JSON_UNQUOTE(JSON_EXTRACT(evt.payload_json, '\$.previous_due_at')) AS previous_due_date,
    JSON_UNQUOTE(JSON_EXTRACT(evt.payload_json, '\$.new_due_at')) AS new_due_date,
    CAST(JSON_UNQUOTE(JSON_EXTRACT(evt.payload_json, '\$.renewal_count')) AS UNSIGNED) AS renewal_number,
    evt.source AS source,
    CASE
        WHEN evt.source = 'PORTAL' THEN 'SERVICE'
        WHEN evt.source = 'STAFF' THEN 'STAFF'
        ELSE 'SYSTEM'
    END AS actor_category
FROM $e evt
JOIN borrowers pat ON pat.borrowernumber = evt.patron_id
LEFT JOIN categories cat ON cat.categorycode = pat.categorycode
LEFT JOIN biblio bib ON bib.biblionumber = evt.biblio_id
WHERE evt.event_type = 'LOAN_RENEWED'
  AND evt.occurred_at >= <<Start date|date>>
  AND evt.occurred_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
  AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
  AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
ORDER BY evt.occurred_at DESC, evt.event_id DESC
},
        },
        {
            slug => 'most_used_titles',
            name => 'Most-used eBook titles',
            description => 'Pre-aggregated request, loan, and renewal usage by Koha biblio.',
            parameters => [
                _date_params(), _scope_params(),
                { name => 'Minimum usage count', type => 'text', required => 1 },
            ],
            expected_columns => [qw(biblio_id title requests issued_loans active_loans completed_loans renewals distinct_patrons usage_count)],
            privacy => 'aggregate-no-pii',
            sql => qq{
WITH request_usage AS (
    SELECT req.biblio_id, COUNT(*) AS requests, COUNT(DISTINCT req.patron_id) AS request_patrons
    FROM $r req
    JOIN borrowers pat ON pat.borrowernumber = req.patron_id
    WHERE req.requested_at >= <<Start date|date>>
      AND req.requested_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
    GROUP BY req.biblio_id
), loan_usage AS (
    SELECT loan.biblio_id, COUNT(*) AS issued_loans,
           SUM(loan.status = 'ACTIVE') AS active_loans,
           SUM(loan.status IN ('RETURNED','REVOKED','EXPIRED')) AS completed_loans,
           COUNT(DISTINCT loan.patron_id) AS loan_patrons
    FROM $l loan
    JOIN borrowers pat ON pat.borrowernumber = loan.patron_id
    WHERE loan.started_at >= <<Start date|date>>
      AND loan.started_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
    GROUP BY loan.biblio_id
), renewal_usage AS (
    SELECT evt.biblio_id, COUNT(*) AS renewals
    FROM $e evt
    JOIN borrowers pat ON pat.borrowernumber = evt.patron_id
    WHERE evt.event_type = 'LOAN_RENEWED'
      AND evt.occurred_at >= <<Start date|date>>
      AND evt.occurred_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
    GROUP BY evt.biblio_id
), usage_keys AS (
    SELECT biblio_id FROM request_usage
    UNION
    SELECT biblio_id FROM loan_usage
    UNION
    SELECT biblio_id FROM renewal_usage
)
SELECT
    usage_keys.biblio_id AS biblio_id,
    bib.title AS title,
    COALESCE(req.requests, 0) AS requests,
    COALESCE(loan.issued_loans, 0) AS issued_loans,
    COALESCE(loan.active_loans, 0) AS active_loans,
    COALESCE(loan.completed_loans, 0) AS completed_loans,
    COALESCE(ren.renewals, 0) AS renewals,
    GREATEST(COALESCE(req.request_patrons, 0), COALESCE(loan.loan_patrons, 0)) AS distinct_patrons,
    COALESCE(req.requests, 0) + COALESCE(loan.issued_loans, 0) + COALESCE(ren.renewals, 0) AS usage_count
FROM usage_keys
LEFT JOIN biblio bib ON bib.biblionumber = usage_keys.biblio_id
LEFT JOIN request_usage req ON req.biblio_id = usage_keys.biblio_id
LEFT JOIN loan_usage loan ON loan.biblio_id = usage_keys.biblio_id
LEFT JOIN renewal_usage ren ON ren.biblio_id = usage_keys.biblio_id
WHERE <<Minimum usage count>> REGEXP '^[0-9]{1,9}\$'
  AND COALESCE(req.requests, 0) + COALESCE(loan.issued_loans, 0) + COALESCE(ren.renewals, 0)
      >= CAST(<<Minimum usage count>> AS UNSIGNED)
ORDER BY usage_count DESC, title, biblio_id
},
        },
        {
            slug => 'department_usage',
            name => 'eBook usage by department',
            description => 'Aggregated usage by the canonical Koha patron-category department source.',
            parameters => [ _date_params(), _scope_params() ],
            expected_columns => [qw(department_code department_name requests approved_requests issued_loans active_loans returned_loans revoked_loans expired_loans renewals distinct_titles distinct_patrons)],
            privacy => 'aggregate-no-pii',
            sql => qq{
WITH request_usage AS (
    SELECT COALESCE(NULLIF(pat.categorycode, ''), '__UNKNOWN__') AS department_code,
           COUNT(*) AS requests,
           SUM(req.status = 'APPROVED') AS approved_requests,
           COUNT(DISTINCT req.biblio_id) AS request_titles,
           COUNT(DISTINCT req.patron_id) AS request_patrons
    FROM $r req
    JOIN borrowers pat ON pat.borrowernumber = req.patron_id
    WHERE req.requested_at >= <<Start date|date>>
      AND req.requested_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
    GROUP BY COALESCE(NULLIF(pat.categorycode, ''), '__UNKNOWN__')
), loan_usage AS (
    SELECT COALESCE(NULLIF(pat.categorycode, ''), '__UNKNOWN__') AS department_code,
           COUNT(*) AS issued_loans,
           SUM(loan.status = 'ACTIVE') AS active_loans,
           SUM(loan.status = 'RETURNED') AS returned_loans,
           SUM(loan.status = 'REVOKED') AS revoked_loans,
           SUM(loan.status = 'EXPIRED') AS expired_loans,
           COUNT(DISTINCT loan.biblio_id) AS loan_titles,
           COUNT(DISTINCT loan.patron_id) AS loan_patrons
    FROM $l loan
    JOIN borrowers pat ON pat.borrowernumber = loan.patron_id
    WHERE loan.started_at >= <<Start date|date>>
      AND loan.started_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
    GROUP BY COALESCE(NULLIF(pat.categorycode, ''), '__UNKNOWN__')
), renewal_usage AS (
    SELECT COALESCE(NULLIF(pat.categorycode, ''), '__UNKNOWN__') AS department_code,
           COUNT(*) AS renewals
    FROM $e evt
    JOIN borrowers pat ON pat.borrowernumber = evt.patron_id
    WHERE evt.event_type = 'LOAN_RENEWED'
      AND evt.occurred_at >= <<Start date|date>>
      AND evt.occurred_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
      AND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)
      AND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)
    GROUP BY COALESCE(NULLIF(pat.categorycode, ''), '__UNKNOWN__')
), usage_keys AS (
    SELECT department_code FROM request_usage
    UNION
    SELECT department_code FROM loan_usage
    UNION
    SELECT department_code FROM renewal_usage
)
SELECT
    usage_keys.department_code AS department_code,
    COALESCE(cat.description, 'Unknown / Not recorded') AS department_name,
    COALESCE(req.requests, 0) AS requests,
    COALESCE(req.approved_requests, 0) AS approved_requests,
    COALESCE(loan.issued_loans, 0) AS issued_loans,
    COALESCE(loan.active_loans, 0) AS active_loans,
    COALESCE(loan.returned_loans, 0) AS returned_loans,
    COALESCE(loan.revoked_loans, 0) AS revoked_loans,
    COALESCE(loan.expired_loans, 0) AS expired_loans,
    COALESCE(ren.renewals, 0) AS renewals,
    GREATEST(COALESCE(req.request_titles, 0), COALESCE(loan.loan_titles, 0)) AS distinct_titles,
    GREATEST(COALESCE(req.request_patrons, 0), COALESCE(loan.loan_patrons, 0)) AS distinct_patrons
FROM usage_keys
LEFT JOIN categories cat ON cat.categorycode = NULLIF(usage_keys.department_code, '__UNKNOWN__')
LEFT JOIN request_usage req ON req.department_code = usage_keys.department_code
LEFT JOIN loan_usage loan ON loan.department_code = usage_keys.department_code
LEFT JOIN renewal_usage ren ON ren.department_code = usage_keys.department_code
ORDER BY department_name, department_code
},
        },
        {
            slug => 'staff_activity',
            name => 'Digital Circulation staff activity',
            description => 'Aggregated staff activity with staff, service, and system actors separated.',
            parameters => [ _date_params(), { name => 'Branch', type => 'branches:all', required => 0 } ],
            expected_columns => [qw(activity_date actor_category staff_actor_id staff_branch action_type request_count loan_count approvals rejections issuances revocations)],
            privacy => 'safe-staff-numeric-id',
            sql => qq{
SELECT
    DATE(evt.occurred_at) AS activity_date,
    CASE
        WHEN evt.source = 'STAFF' THEN 'STAFF'
        WHEN evt.source = 'PORTAL' THEN 'SERVICE'
        ELSE 'SYSTEM'
    END AS actor_category,
    CASE WHEN evt.source = 'STAFF' THEN evt.actor_patron_id ELSE NULL END AS staff_actor_id,
    CASE WHEN evt.source = 'STAFF' THEN actor.branchcode ELSE NULL END AS staff_branch,
    evt.event_type AS action_type,
    COUNT(DISTINCT evt.request_id) AS request_count,
    COUNT(DISTINCT evt.loan_id) AS loan_count,
    SUM(evt.event_type = 'REQUEST_APPROVED') AS approvals,
    SUM(evt.event_type = 'REQUEST_REJECTED') AS rejections,
    SUM(evt.event_type = 'LOAN_CREATED') AS issuances,
    SUM(evt.event_type = 'LOAN_REVOKED') AS revocations
FROM $e evt
LEFT JOIN borrowers actor
  ON actor.borrowernumber = evt.actor_patron_id
 AND evt.source = 'STAFF'
WHERE evt.occurred_at >= <<Start date|date>>
  AND evt.occurred_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
  AND (<<Branch|branches:all>> = '' OR (evt.source = 'STAFF' AND actor.branchcode = <<Branch|branches:all>>))
GROUP BY DATE(evt.occurred_at), actor_category, staff_actor_id, staff_branch, evt.event_type
ORDER BY activity_date DESC, actor_category, staff_actor_id, action_type
},
        },
        {
            slug => 'audit_trail',
            name => 'Digital circulation audit trail',
            description => 'Controlled non-public audit view with safe summarized details and no raw event payload.',
            parameters => [
                _date_params(),
                { name => 'Event type', type => 'text', required => 0 },
                { name => 'Request ID', type => 'text', required => 0 },
                { name => 'Loan ID', type => 'text', required => 0 },
                { name => 'Source', type => 'text', required => 0 },
            ],
            expected_columns => [qw(event_id event_timestamp event_type request_id loan_id source actor_category subject_patron_id correlation_id safe_details)],
            privacy => 'controlled-audit-numeric-subject',
            sql => qq{
SELECT
    evt.event_id AS event_id,
    evt.occurred_at AS event_timestamp,
    evt.event_type AS event_type,
    evt.request_id AS request_id,
    evt.loan_id AS loan_id,
    evt.source AS source,
    CASE
        WHEN evt.source = 'STAFF' THEN 'STAFF'
        WHEN evt.source = 'PORTAL' THEN 'SERVICE'
        ELSE 'SYSTEM'
    END AS actor_category,
    evt.patron_id AS subject_patron_id,
    evt.correlation_id AS correlation_id,
    CASE evt.event_type
        WHEN 'LOAN_CREATED' THEN CONCAT('status=', COALESCE(JSON_UNQUOTE(JSON_EXTRACT(evt.payload_json, '\$.new_status')), ''))
        WHEN 'LOAN_RENEWED' THEN CONCAT('renewal_count=', COALESCE(JSON_UNQUOTE(JSON_EXTRACT(evt.payload_json, '\$.renewal_count')), ''))
        WHEN 'LOAN_RETURNED' THEN CONCAT('status=', COALESCE(JSON_UNQUOTE(JSON_EXTRACT(evt.payload_json, '\$.new_status')), ''))
        WHEN 'LOAN_REVOKED' THEN CONCAT('status=', COALESCE(JSON_UNQUOTE(JSON_EXTRACT(evt.payload_json, '\$.new_status')), ''))
        WHEN 'LOAN_EXPIRED' THEN CONCAT('status=', COALESCE(JSON_UNQUOTE(JSON_EXTRACT(evt.payload_json, '\$.new_status')), ''))
        ELSE CONCAT('aggregate=', evt.aggregate_type)
    END AS safe_details
FROM $e evt
WHERE evt.occurred_at >= <<Start date|date>>
  AND evt.occurred_at < DATE_ADD(<<End date|date>>, INTERVAL 1 DAY)
  AND (<<Event type>> = '' OR (<<Event type>> IN ('REQUEST_CREATED','REQUEST_APPROVED','REQUEST_REJECTED','LOAN_CREATED','LOAN_RENEWED','LOAN_RETURNED','LOAN_REVOKED','LOAN_EXPIRED') AND evt.event_type = <<Event type>>))
  AND (<<Request ID>> = '' OR (<<Request ID>> REGEXP '^[0-9]{1,20}\$' AND evt.request_id = CAST(<<Request ID>> AS UNSIGNED)))
  AND (<<Loan ID>> = '' OR (<<Loan ID>> REGEXP '^[0-9]{1,20}\$' AND evt.loan_id = CAST(<<Loan ID>> AS UNSIGNED)))
  AND (<<Source>> = '' OR (<<Source>> IN ('PORTAL','STAFF','SYSTEM') AND evt.source = <<Source>>))
ORDER BY evt.occurred_at DESC, evt.event_id DESC
},
        },
    );

    for my $definition (@definitions) {
        push @{ $definition->{parameters} },
            { name => 'Item type', type => 'itemtypes', required => 0 };

        # Koha::Report::is_sql_valid accepts only statements whose first
        # non-whitespace token is SELECT. Keep the item-type mapping local to
        # each predicate rather than prepending a shared CTE.
        my $item_type_filter = sub {
            my ($column) = @_;
            return "(<<Item type|itemtypes>> = '' OR EXISTS (\n"
                . "        SELECT 1\n"
                . "        FROM (\n"
                . "            SELECT DISTINCT item.biblionumber, item.itype AS item_type\n"
                . "            FROM items item\n"
                . "            WHERE COALESCE((SELECT value FROM systempreferences WHERE variable = 'item-level_itypes'), '0') = '1'\n"
                . "            UNION\n"
                . "            SELECT DISTINCT bi.biblionumber, bi.itemtype AS item_type\n"
                . "            FROM biblioitems bi\n"
                . "            WHERE COALESCE((SELECT value FROM systempreferences WHERE variable = 'item-level_itypes'), '0') <> '1'\n"
                . "               OR NOT EXISTS (\n"
                . "                    SELECT 1 FROM items mapped_item\n"
                . "                    WHERE mapped_item.biblionumber = bi.biblionumber\n"
                . "                      AND COALESCE(mapped_item.itype, '') <> ''\n"
                . "               )\n"
                . "        ) catalogue_item_types\n"
                . "        WHERE catalogue_item_types.biblionumber = $column\n"
                . "          AND catalogue_item_types.item_type = <<Item type|itemtypes>>\n"
                . "    ))";
        };

        my %filter_column = (
            requests_awaiting_action => 'req.biblio_id',
            request_history         => 'req.biblio_id',
            active_loans            => 'loan.biblio_id',
            completed_loans         => 'loan.biblio_id',
            renewal_activity        => 'evt.biblio_id',
            most_used_titles        => 'usage_keys.biblio_id',
            staff_activity          => 'evt.biblio_id',
            audit_trail             => 'evt.biblio_id',
        );
        if ( my $column = $filter_column{ $definition->{slug} } ) {
            my $filter = "\n  AND " . $item_type_filter->($column);
            my $marker = $definition->{slug} eq 'staff_activity'
                ? qr/\nGROUP BY/
                : qr/\nORDER BY/;
            $definition->{sql} =~ s/$marker/$filter$&/;
        }

        if ( $definition->{slug} eq 'lifecycle_summary' ) {
            my @columns = qw(req.biblio_id loan.biblio_id evt.biblio_id);
            $definition->{sql} =~ s{
(\QAND (<<Department|categorycode:all>> = '' OR pat.categorycode = <<Department|categorycode:all>>)\E)
}{$1 . "\n      AND " . $item_type_filter->(shift(@columns))}gex;
        }
        elsif ( $definition->{slug} eq 'department_usage' ) {
            my @columns = qw(req.biblio_id loan.biblio_id evt.biblio_id);
            $definition->{sql} =~ s{
(\QAND (<<Branch|branches:all>> = '' OR pat.branchcode = <<Branch|branches:all>>)\E)
}{$1 . "\n      AND " . $item_type_filter->(shift(@columns))}gex;
        }

        # MariaDB accepts a CTE inside a derived SELECT. This preserves the
        # independent aggregate calculations in the three aggregate reports
        # while ensuring the stored statement itself starts with SELECT.
        if ( $definition->{sql} =~ /\A\s*WITH\s+/ ) {
            my $columns = join ",\n    ", map {
                "managed_report_result.$_ AS $_"
            } @{ $definition->{expected_columns} };
            $definition->{sql} = "SELECT\n    $columns\nFROM (\n"
                . $definition->{sql} . "\n) AS managed_report_result";
        }

        $definition->{definition_version} = DEFINITION_VERSION;
        $definition->{group_code} = GROUP_CODE;
        $definition->{subgroup_code} = SUBGROUP_CODE;
        $definition->{report_area} = REPORT_AREA;
        $definition->{public} = 0;
        $definition->{cache_expiry} = 300;
        $definition->{notes} = _marker( $definition->{slug}, $definition->{description} );
        $definition->{sql} =~ s/\A\s+|\s+\z//g;
        $definition->{fingerprint} = sha256_hex(
            join "\x1f", map { defined $_ ? $_ : '' }
                @{$definition}{qw(slug name sql notes group_code subgroup_code report_area public cache_expiry)}
        );
    }
    return \@definitions;
}

sub by_slug {
    my ($self) = @_;
    return { map { $_->{slug} => $_ } @{ $self->reports } };
}

1;
