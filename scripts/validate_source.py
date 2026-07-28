#!/usr/bin/env python3
"""Deterministic source and KPZ contract checks runnable on Windows or Debian."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE = pathlib.Path("Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation")
BUNDLE_MANIFEST = pathlib.PurePosixPath("Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation")
MAIN = ROOT / pathlib.Path(f"{BUNDLE}.pm")
EXPECTED_TABLES = [
    "requests",
    "loans",
    "renewals",
    "events",
    "schema_versions",
]
PLUGIN_VERSION = "0.2.0"

# Detect real Windows absolute paths, UNC shares, Koha instance paths, usable
# bearer samples, and literal credentials. The drive-letter branch requires a
# multi-segment path so Perl regex fragments such as Authorization:\s and
# \d\d:\d\d are not misclassified as Windows paths.
FORBIDDEN_PRODUCTION_CONTENT = re.compile(
    r"(?<![A-Za-z0-9_])[A-Za-z]:\\[^\\\r\n]{2,}\\|"
    r"\\\\[A-Za-z0-9._-]+\\[A-Za-z0-9._$\\-]+|"
    r"/var/lib/koha/library|"
    r"Authorization:\s*Bearer\s+[A-Za-z0-9._~+/-]{12,}|"
    r"(?:client_secret|password)\s*(?:=>|=)\s*['\"][^'\"]+['\"]",
    re.I,
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"ok - {message}")


def contains_forbidden_production_content(text: str) -> bool:
    return FORBIDDEN_PRODUCTION_CONTENT.search(text) is not None


def check_path_scan_contract() -> None:
    false_positive_samples = [
        r"$error =~ s/Authorization:\s*Bearer\s+\S+/Authorization: Bearer [REDACTED]/ig;",
        r"$requested_at =~ /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/;",
        r"die'INVALID_FILTER'unless$q->{$k}=~/\A\d{4}-\d\d-\d\d(?:[ T]\d\d:\d\d(?::\d\d)?)?\z/;",
        r"$reason =~ /\bdata\s*:\s*text\/html/i;",
        "https://example.com/api/v1/contrib/jzl-digital-circulation/requests",
        "Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation",
        r'name="csrf_token"',
        "See docs/TESTING.md for the Windows and Koha validation matrix.",
        r"$error =~ s/\b(password|passwd|pwd|client_secret|access_token)\s*[=:]\s*[^\s;]+/$1=[REDACTED]/ig;",
    ]
    require(
        not any(
            contains_forbidden_production_content(sample)
            for sample in false_positive_samples
        ),
        "path scan accepts redaction regexes, URLs, namespaces, and documentation text",
    )

    require(
        contains_forbidden_production_content(r"C:\Windows\System32\drivers"),
        "path scan rejects a real Windows absolute path",
    )
    require(
        contains_forbidden_production_content(
            r"D:\Koha_Digital_Circulation_Plugin\plugin.pm"
        ),
        "path scan rejects a real Windows project path",
    )
    require(
        contains_forbidden_production_content(r"\\\\fileserver\\library\\ebooks"),
        "path scan rejects a real UNC path",
    )
    require(
        contains_forbidden_production_content("/var/lib/koha/library/plugins"),
        "path scan rejects a hardcoded Koha instance path",
    )
    require(
        contains_forbidden_production_content(
            "Authorization: Bearer abcdefghijklmnop"
        ),
        "path scan rejects a usable bearer sample",
    )
    require(
        contains_forbidden_production_content("password => 'secret-value'"),
        "path scan rejects a literal password assignment",
    )


def create_table_sql(source: str) -> list[str]:
    return re.findall(
        r"CREATE TABLE IF NOT EXISTS `\$[rlnve]` \(.*?\) ENGINE=InnoDB "
        r"DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
        source,
        flags=re.DOTALL,
    )


def check_source() -> None:
    source = MAIN.read_text(encoding="utf-8")
    manifest = [
        line.strip()
        for line in (ROOT / "MANIFEST").read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    openapi = json.loads((ROOT / BUNDLE / "openapi.json").read_text(encoding="utf-8"))
    require(f"our $VERSION             = '{PLUGIN_VERSION}';" in source, "plugin version is 0.2.0")
    require("our $SCHEMA_VERSION      = 1;" in source, "schema version remains 1")
    require("minimum_version => '26.05.00.000'" in source, "minimum Koha version remains 26.05.00.000")

    statements = create_table_sql(source)
    require(len(statements) == 5, "exactly five CREATE TABLE statements")
    for index, statement in enumerate(statements, 1):
        require(statement.count("(") == statement.count(")"), f"CREATE TABLE {index} parentheses balanced")
        require(
            statement.endswith("ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"),
            f"CREATE TABLE {index} engine/charset declaration",
        )
    require(
        not re.search(r"ON DELETE RESTRICT\s*\)\s*\) ENGINE", statements[3]),
        "events foreign key has no redundant closing parenthesis",
    )
    for name in EXPECTED_TABLES:
        require(f"table('{name}')" in source, f"expected table mapping: {name}")
    require("INSERT IGNORE INTO `$v`" in source, "schema version insertion is retry-safe")
    require(source.count("CREATE TABLE IF NOT EXISTS") == 5, "partial migration retry preserves existing tables")
    require("$self->_verify_schema($dbh);" in source, "install verifies schema before success")
    require("Schema version 1 was not recorded" in source, "install verifies schema version 1")
    require("SELECT GET_LOCK(?, 30)" in source and "== 1" in source, "migration lock result is checked")
    require("SELECT RELEASE_LOCK(?)" in source, "migration lock release is always attempted")
    require("migration failed: " in source and "_safe_install_error" in source, "safe detailed migration logging")

    request_guard = re.search(r"pending_guard VARCHAR\(80\).*?STORED", source, re.DOTALL)
    require(request_guard is not None, "request pending generated guard exists")
    require("status = 'PENDING'" in request_guard.group() and "ELSE NULL" in request_guard.group(), "request guard applies only to PENDING")
    require("UNIQUE KEY jzl_req_pending_uq (pending_guard)" in source, "request pending guard is unique")
    require(not re.search(r"UNIQUE[^\n]*patron_id[^\n]*biblio_id[^\n]*status", source, re.I), "no historical-status uniqueness constraint")
    renewal_guard = re.search(r"pending_guard BIGINT UNSIGNED.*?STORED", source, re.DOTALL)
    require(renewal_guard is not None and "status = 'PENDING'" in renewal_guard.group() and "ELSE NULL" in renewal_guard.group(), "renewal guard applies only to PENDING")

    tool_path = BUNDLE_MANIFEST / "tool.tt"
    configure_path = BUNDLE_MANIFEST / "configure.tt"
    require((ROOT / tool_path).is_file(), "tool.tt exists at bundle root")
    require(tool_path.as_posix() in manifest, "tool.tt bundle-root path is in MANIFEST")
    require((ROOT / configure_path).is_file(), "configure.tt exists at bundle root")
    require(configure_path.as_posix() in manifest, "configure.tt bundle-root path is in MANIFEST")
    require(not (ROOT / BUNDLE / "templates" / "tool.tt").exists(), "no duplicate guessed template path")
    require(not (ROOT / BUNDLE / "templates" / "configure.tt").exists(), "no obsolete configuration template path")
    for runtime in [
        f"{BUNDLE_MANIFEST}.pm",
        f"{BUNDLE_MANIFEST}/openapi.json",
        f"{BUNDLE_MANIFEST}/Controller/Requests.pm",
        f"{BUNDLE_MANIFEST}/Service/EbookContentAdapter.pm",
        f"{BUNDLE_MANIFEST}/Service/EbookContentEligibility.pm",
        f"{BUNDLE_MANIFEST}/Service/PortalServiceAuthorization.pm",
        f"{BUNDLE_MANIFEST}/Service/PortalRequestApplication.pm",
        f"{BUNDLE_MANIFEST}/Service/PortalLoanReadApplication.pm",
        f"{BUNDLE_MANIFEST}/Service/PortalLoanReturnApplication.pm",
        f"{BUNDLE_MANIFEST}/Controller/Patrons.pm",
        f"{BUNDLE_MANIFEST}/Controller/Loans.pm",
        f"{BUNDLE_MANIFEST}/Repository/RequestRepository.pm",
        f"{BUNDLE_MANIFEST}/Repository/EventRepository.pm",
        f"{BUNDLE_MANIFEST}/Service/RequestDecisionService.pm",
        f"{BUNDLE_MANIFEST}/Service/RequestService.pm",
        f"{BUNDLE_MANIFEST}/Service/LoanIssuanceService.pm",
        f"{BUNDLE_MANIFEST}/Service/LoanReturnService.pm",
        f"{BUNDLE_MANIFEST}/Service/ConfiguredLoanPeriodPolicy.pm",
        f"{BUNDLE_MANIFEST}/Service/StaffDecisionAuthorization.pm",
        f"{BUNDLE_MANIFEST}/Service/StaffRequestDecisionApplication.pm",
        f"{BUNDLE_MANIFEST}/Service/StaffLoanIssuanceApplication.pm",
        f"{BUNDLE_MANIFEST}/Repository/LoanRepository.pm",
        f"{BUNDLE_MANIFEST}/static/css/jzl-digital-circulation.css",
        f"{BUNDLE_MANIFEST}/static/js/jzl-digital-circulation.js",
    ]:
        require(runtime in manifest and (ROOT / runtime).is_file(), f"runtime file packaged: {runtime}")

    tool = (ROOT / tool_path).read_text(encoding="utf-8")
    staff_js = (
        ROOT / BUNDLE / "static" / "js" / "jzl-digital-circulation.js"
    ).read_text(encoding="utf-8")
    staff_ui = tool + "\n" + staff_js
    require(
        "Phase 2C — request decisions and loan issuance" in tool
        and "Approval alone does not create a loan" in tool
        and "does not grant protected-PDF reader access" in tool,
        "staff tool states the Phase 2C decision and issuance boundary",
    )
    require(
        "approve.textContent = 'Approve'" in staff_js
        and "reject.textContent = 'Reject'" in staff_js
        and "request.status === 'PENDING'" in staff_js,
        "staff tool exposes Approve and Reject only for pending requests",
    )
    require(
        "issue.textContent = 'Issue Loan'" in staff_js
        and "canIssueRequest(request)" in staff_js
        and "loanPresence(request) === 'absent'" in staff_js
        and "request.status === 'APPROVED'" in staff_js,
        "Issue Loan appears only for APPROVED requests without a loan",
    )
    require(
        "DECISION_PATH = '/requests/'" in staff_js
        and "'/decision'" in staff_js
        and "ISSUE_PATH = '/requests/'" in staff_js
        and "'/issue'" in staff_js
        and "method: 'POST'" in staff_js
        and "credentials: 'same-origin'" in staff_js,
        "staff decisions and issuance use only the same-origin verified REST endpoints",
    )
    require(
        "'X-Correlation-ID': correlationId" in staff_js
        and "expected_row_version: version" in staff_js
        and "window.crypto.randomUUID()" in staff_js
        and "window.crypto.getRandomValues(bytes)" in staff_js
        and "submitIssuance" in staff_js,
        "staff writes use a fresh secure correlation UUID and dedicated issuance submit helper",
    )
    require(
        "innerHTML" not in staff_js
        and "Authorization" not in staff_js
        and "portal_service_account_ids" not in staff_ui
        and "grantAccess" not in staff_js
        and "activateReader" not in staff_js,
        "staff UI contains no unsafe HTML, authorization header, portal allowlist, or reader access",
    )
    for control in ("Create", "Delete", "Return", "Renew", "Revoke", "Edit"):
        require(
            re.search(rf">\s*{control}(?: Request)?\s*<", tool) is None
            and re.search(rf"\.textContent\s*=\s*['\"]{control}(?: Request)?['\"]", staff_js)
            is None,
            f"staff tool has no {control} write control",
        )
    base_repo = (ROOT / BUNDLE / "Repository" / "Base.pm").read_text(encoding="utf-8")
    require(
        "LEFT JOIN plugin_jzl_ebook_loans l ON l.request_id=r.request_id" in base_repo
        and "l.loan_id AS loan_id" in base_repo
        and "l.status AS loan_status" in base_repo,
        "request read model left-joins a safe loan summary",
    )

    portal_auth = (ROOT / BUNDLE / "Service" / "PortalServiceAuthorization.pm").read_text(encoding="utf-8")
    require("CONFIG_KEY => 'portal_service_account_ids'" in portal_auth, "portal service allowlist has one stable configuration key")
    require("retrieve_data(CONFIG_KEY)" in portal_auth and "store_data( { CONFIG_KEY()" in portal_auth, "portal service allowlist uses Koha plugin data API")
    require("sub load_config" in portal_auth and "sub store_config" in portal_auth, "one service owns configuration loading and storage")
    require("stash('koha.user')" in portal_auth, "portal service actor comes from Koha authentication context")
    require("haspermission" not in portal_auth, "portal service authorization does not rely on general circulation permission")

    content_adapter = (ROOT / BUNDLE / "Service" / "EbookContentAdapter.pm").read_text(encoding="utf-8")
    content_eligibility = (ROOT / BUNDLE / "Service" / "EbookContentEligibility.pm").read_text(encoding="utf-8")
    require("Koha::Plugins->get_enabled_plugins" in content_adapter, "EbookContent adapter uses enabled Koha plugin discovery")
    require("validated_mapping" in content_adapter, "EbookContent adapter uses the verified metadata/content validation boundary")
    require("DEPENDENCY_VERSION => '0.1.2'" in content_adapter, "EbookContent adapter pins the verified dependency contract")
    require("reason    => 'CONTENT_LOOKUP_UNAVAILABLE'" in content_adapter, "EbookContent adapter fails closed when its dependency is unavailable")
    require("REQUIRED_CATEGORY => 'EBOOK_PDF'" in content_eligibility and "REQUIRED_MIME     => 'application/pdf'" in content_eligibility, "eligibility enforces verified protected PDF type and category")
    require("Koha::Biblios->find($biblio_id)" in content_eligibility, "eligibility verifies Koha biblio existence")
    require(
        not re.search(
            r"https?://|Authorization:\s*Bearer|/var/lib/koha|[A-Za-z]:[\\/]|KohaPluginWorkspace|SELECT\s+.*ebook",
            content_adapter + content_eligibility,
            re.I,
        ),
        "content integration avoids HTTP, OAuth, deployed paths, Windows paths, and private-table coupling",
    )

    request_repository = (ROOT / BUNDLE / "Repository" / "RequestRepository.pm").read_text(encoding="utf-8")
    event_repository = (ROOT / BUNDLE / "Repository" / "EventRepository.pm").read_text(encoding="utf-8")
    request_service = (ROOT / BUNDLE / "Service" / "RequestService.pm").read_text(encoding="utf-8")
    require(
        all(
            method in request_repository
            for method in (
                "find_by_idempotency_key",
                "find_pending_by_patron_and_biblio",
                "insert_pending_request",
                "get_by_id",
            )
        ),
        "request repository exposes narrow persistence methods",
    )
    require("insert_request_created_event" in event_repository, "event repository exposes request-created insertion")
    require(
        all(token in request_service for token in ("begin_work", "commit", "rollback")),
        "request service owns the DML transaction",
    )
    require(
        "REQUEST_CREATED" in request_service
        and "IDEMPOTENT_REPLAY" in request_service
        and "DUPLICATE_PENDING" in request_service
        and "IDEMPOTENCY_CONFLICT" in request_service,
        "request service implements creation and repeat classifications",
    )
    require(
        request_repository.count("?") >= 9 and event_repository.count("?") >= 15,
        "request and event repositories use bound SQL placeholders",
    )
    require(
        not re.search(
            r"INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)|"
            r"\b(?:issues|old_issues|reserves|items)\b",
            request_repository + event_repository + request_service,
            re.I,
        ),
        "request persistence does not write later-phase or native circulation domains",
    )

    decision_service = (
        ROOT / BUNDLE / "Service" / "RequestDecisionService.pm"
    ).read_text(encoding="utf-8")
    require(
        all(
            method in request_repository
            for method in ("get_for_decision", "update_pending_decision", "get_by_id")
        ),
        "request repository exposes guarded decision methods",
    )
    require(
        "insert_request_approved_event" in event_repository
        and "insert_request_rejected_event" in event_repository,
        "event repository exposes explicit decision-event methods",
    )
    require(
        all(
            token in decision_service
            for token in (
                "sub decide_request",
                "APPROVE",
                "REJECT",
                "insert_request_approved_event",
                "insert_request_rejected_event",
                "expected_row_version",
                "begin_work",
                "commit",
                "rollback",
            )
        ),
        "decision service implements both transactional decisions",
    )
    require(
        "row_version = row_version + 1" in request_repository
        and "status = 'PENDING'" in request_repository
        and request_repository.count("?") >= 20,
        "decision updates use optimistic guards and bound parameters",
    )
    require(
        "can_transition" in decision_service
        and "StateMachine" in decision_service,
        "decision service reuses the existing state machine",
    )
    require(
        not re.search(
            r"\b(?:status\s*=>\s*\d{3}|render\s*\(|haspermission|stash\('koha\.user'\))\b|"
            r"INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)|"
            r"\b(?:issues|old_issues|reserves|items)\b",
            decision_service,
            re.I,
        ),
        "decision service contains no HTTP, authorization, loan, renewal, or native circulation work",
    )

    loan_repository = (ROOT / BUNDLE / "Repository" / "LoanRepository.pm").read_text(encoding="utf-8")
    loan_issuance = (ROOT / BUNDLE / "Service" / "LoanIssuanceService.pm").read_text(encoding="utf-8")
    require(
        all(
            token in loan_issuance
            for token in (
                "sub issue_loan",
                "get_for_issuance",
                "insert_active_loan",
                "insert_loan_created_event",
                "check_biblio_eligibility",
                "due_date_policy",
                "begin_work",
                "commit",
                "rollback",
                "ACTIVE",
                "LOAN_ALREADY_EXISTS",
            )
        )
        and "LOAN_CREATED" in event_repository
        and "insert_loan_created_event" in event_repository,
        "loan issuance service exists with transactional loan and event creation",
    )
    require(
        "request->{patron_id}" in loan_issuance
        and "request->{biblio_id}" in loan_issuance
        and "insert_active_loan" in loan_issuance,
        "loan issuance uses trusted request-derived patron and biblio identity",
    )
    require(
        "check_biblio_eligibility" in loan_issuance
        and "PROTECTED_CONTENT_UNAVAILABLE" in loan_issuance
        and "INVALID_MAPPING" in loan_issuance,
        "loan issuance requires protected-content revalidation",
    )
    require(
        "find_by_request_id" in loan_repository
        and "insert_active_loan" in loan_repository
        and "get_for_issuance" in request_repository
        and "insert_loan_created_event" in event_repository,
        "loan issuance persistence methods are narrow and explicit",
    )
    require(
        "our $SCHEMA_VERSION      = 1" in source
        and "SCHEMA_VERSION" in source,
        "schema version remains unchanged for loan issuance foundation",
    )
    require(
        not re.search(
            r"\b(?:status\s*=>\s*\d{3}|render\s*\(|haspermission|AddIssue|GetIssue)\b|"
            r"\b(?:issues|old_issues|reserves|items)\b|"
            r"reader[_-]?token|byte-range|entitlement|protected.?pdf.?path",
            loan_issuance,
            re.I,
        ),
        "loan issuance contains no HTTP, native issue, or reader-access behavior",
    )
    require(
        "LoanIssuanceService" not in decision_service
        and "issue_loan" not in decision_service,
        "approval decision service remains unwired from loan issuance",
    )

    loan_period_policy = (
        ROOT / BUNDLE / "Service" / "ConfiguredLoanPeriodPolicy.pm"
    ).read_text(encoding="utf-8")
    require(
        "CONFIG_KEY => 'default_loan_duration_days'" in loan_period_policy
        and "MIN_DAYS   => 1" in loan_period_policy
        and "MAX_DAYS   => 365" in loan_period_policy
        and "sub resolve_due_at" in loan_period_policy,
        "configured production loan policy exists with validated duration range",
    )
    require(
        "loan_duration_missing" in loan_period_policy
        and "INVALID_LOAN_PERIOD" in loan_period_policy,
        "blank configuration fails closed as INVALID_LOAN_PERIOD",
    )
    require(
        "due_at" in loan_period_policy
        and "duration_seconds" not in loan_period_policy,
        "configured policy returns due_at and does not invent duration_seconds",
    )
    require(
        "_build_loan_issuance_service" in source
        and "ConfiguredLoanPeriodPolicy" in source,
        "LoanIssuanceService production wiring receives the configured policy",
    )
    require(
        "default_loan_duration_days" in (
            ROOT / BUNDLE / "configure.tt"
        ).read_text(encoding="utf-8")
        and "Default digital loan duration (days)"
        in (ROOT / BUNDLE / "configure.tt").read_text(encoding="utf-8"),
        "configure page exposes the loan duration setting",
    )
    require(
        not re.search(
            r"\b(?:AddIssue|GetIssue)\b|reader[_-]?token|entitlement|byte-range|"
            r"\bstatus\s*=>\s*\d{3}\b|\brender\s*\(",
            loan_period_policy,
            re.I,
        ),
        "loan period policy contains no HTTP, native issue, or reader-access behavior",
    )

    staff_authorization = (
        ROOT / BUNDLE / "Service" / "StaffDecisionAuthorization.pm"
    ).read_text(encoding="utf-8")
    staff_decision_application = (
        ROOT / BUNDLE / "Service" / "StaffRequestDecisionApplication.pm"
    ).read_text(encoding="utf-8")
    require(
        "stash('koha.user')" in staff_authorization
        and "C4::Auth::haspermission" in staff_authorization
        and "circulate_remaining_permissions" in staff_authorization,
        "staff decision authorization uses trusted Koha actor and established permission",
    )
    require(
        "PortalServiceAuthorization->new" in staff_authorization
        and "load_config" in staff_authorization
        and "_parse_allowlist" in staff_authorization
        and "PortalServiceAuthorization->authorize_controller" not in staff_authorization,
        "staff decisions reuse canonical portal identity parsing without portal authorization",
    )
    require(
        staff_authorization.index("my $is_service_account")
        < staff_authorization.index("my $permission")
        and "STAFF_NOT_AUTHORIZED" in staff_authorization,
        "configured portal service accounts are denied before staff permission lookup",
    )
    decide_request = re.search(
        r"sub decide_request \{.*?\n\}",
        staff_decision_application,
        re.DOTALL,
    )
    require(
        decide_request is not None,
        "staff decision application exposes internal decide_request",
    )
    staff_flow = decide_request.group()
    require(
        staff_flow.index("_authorize")
        < staff_flow.index("_validate_command")
        < staff_flow.index("decision_service")
        < staff_flow.index("_normalize_result"),
        "staff decision application preserves authorization-first orchestration order",
    )
    require(
        "StaffDecisionAuthorization" in staff_decision_application
        and "RequestDecisionService" in staff_decision_application,
        "staff decision application composes authorization and persistence boundaries",
    )
    require(
        "StaffDecisionAuthorization->new(\n                plugin => $args{plugin}" in staff_decision_application,
        "staff decision application supplies plugin configuration to authorization",
    )
    require(
        "PortalServiceAuthorization" not in staff_decision_application,
        "staff decision application has no portal authorization dependency",
    )
    require(
        not re.search(
            r"\b(?:SELECT|INSERT|UPDATE|DELETE)\b|\b(?:begin_work|commit|rollback)\b|"
            r"\bstatus\s*=>\s*\d{3}\b|\brender\s*\(|"
            r"plugin_jzl_ebook_(?:loans|renewals)|\b(?:issues|old_issues|reserves|items)\b",
            staff_decision_application,
            re.I,
        ),
        "staff decision application contains no SQL, transaction, HTTP, loan, or renewal work",
    )

    staff_loan_issuance_application = (
        ROOT / BUNDLE / "Service" / "StaffLoanIssuanceApplication.pm"
    ).read_text(encoding="utf-8")
    require(
        "sub issue_loan" in staff_loan_issuance_application
        and "StaffDecisionAuthorization" in staff_loan_issuance_application
        and "LoanIssuanceService" in staff_loan_issuance_application,
        "StaffLoanIssuanceApplication exists with staff authorization and issuance delegation",
    )
    require(
        "StaffDecisionAuthorization->new(\n                plugin => $args{plugin}"
        in staff_loan_issuance_application,
        "staff loan issuance application supplies plugin configuration to authorization",
    )
    issue_loan = re.search(
        r"sub issue_loan \{.*?\n\}",
        staff_loan_issuance_application,
        re.DOTALL,
    )
    require(issue_loan is not None, "staff loan issuance application exposes internal issue_loan")
    issuance_flow = issue_loan.group()
    require(
        issuance_flow.index("_authorize")
        < issuance_flow.index("_validate_command")
        < issuance_flow.index("issuance_service")
        < issuance_flow.index("_normalize_result"),
        "staff loan issuance application preserves authorization-first orchestration order",
    )
    require(
        "request_id => $command->{request_id}" in staff_loan_issuance_application
        and "actor_id   => $actor_id" in staff_loan_issuance_application,
        "LoanIssuanceService receives trusted actor and validated request ID only",
    )
    require(
        "PortalServiceAuthorization" not in staff_loan_issuance_application,
        "staff loan issuance application has no portal authorization dependency",
    )
    require(
        "ALLOWED_COMMAND_KEYS" in staff_loan_issuance_application
        and "INVALID_INPUT" in staff_loan_issuance_application,
        "staff loan issuance command rejects caller authority fields",
    )
    require(
        not re.search(
            r"\b(?:SELECT|INSERT|UPDATE|DELETE)\b|\b(?:begin_work|commit|rollback)\b|"
            r"\bstatus\s*=>\s*\d{3}\b|\brender\s*\(|"
            r"\b(?:AddIssue|GetIssue)\b|reader[_-]?token|entitlement|byte-range|"
            r"plugin_jzl_ebook_(?:loans|renewals)|\b(?:issues|old_issues|reserves|items)\b",
            staff_loan_issuance_application,
            re.I,
        ),
        "staff loan issuance application contains no SQL, HTTP, native issue, or reader-access behavior",
    )

    request_application = (ROOT / BUNDLE / "Service" / "PortalRequestApplication.pm").read_text(encoding="utf-8")
    create_request = re.search(r"sub create_request \{.*?\n\}", request_application, re.DOTALL)
    require(create_request is not None, "portal request application exposes internal create_request")
    application_flow = create_request.group()
    require(
        application_flow.index("_authorize") < application_flow.index("patron_validator")
        < application_flow.index("_check_eligibility") < application_flow.index("create_portal_request"),
        "portal request application preserves authorization-first orchestration order",
    )
    require(
        "PortalServiceAuthorization" in request_application
        and "EbookContentEligibility" in request_application
        and "RequestService" in request_application,
        "portal request application reuses existing services",
    )
    require(
        not re.search(
            r"\b(?:SELECT|INSERT|UPDATE|DELETE)\b|\b(?:begin_work|commit|rollback)\b|"
            r"\bstatus\s*=>\s*\d{3}\b|\brender\s*\(",
            request_application,
            re.I,
        ),
        "portal request application contains no SQL, transaction, or HTTP mapping",
    )

    require(source.count("use base qw(Koha::Plugins::Base)") == 1, "single Koha::Plugins::Base inheritance declaration")
    require("use parent" not in source, "no conflicting parent declaration")
    require("sub uninstall" in source and "DROP TABLE" not in source, "normal uninstall preserves tables")
    write_routes = sorted(
        f"{method.lower()} {path}"
        for path, path_item in openapi.items()
        for method in path_item
        if method.lower() in {"post", "put", "patch", "delete"}
    )
    require(
        write_routes
        == [
            "post /loans/{loan_id}/return",
            "post /requests",
            "post /requests/{request_id}/decision",
            "post /requests/{request_id}/issue",
        ],
        "source OpenAPI has exactly four POST routes including patron return",
    )
    return_post = openapi.get("/loans/{loan_id}/return", {}).get("post")
    require(
        isinstance(return_post, dict)
        and return_post.get("operationId") == "jzlReturnDigitalLoan"
        and return_post.get("x-mojo-to")
        == "Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Loans#return_loan",
        "patron return OpenAPI route and controller operation agree",
    )
    portal_loan_get = openapi.get("/patrons/{patron_id}/loans", {}).get("get")
    require(
        isinstance(portal_loan_get, dict)
        and portal_loan_get.get("operationId") == "jzlListPatronDigitalLoans"
        and portal_loan_get.get("x-mojo-to")
        == "Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Patrons#list_loans",
        "portal loan-read OpenAPI route and controller operation agree",
    )
    portal_loan_parameters = {
        (parameter.get("in"), parameter.get("name")): parameter
        for parameter in portal_loan_get.get("parameters", [])
    }
    require(
        portal_loan_parameters.get(("path", "patron_id"), {}).get("required")
        and portal_loan_parameters.get(("header", "X-Correlation-ID"), {}).get(
            "required"
        )
        and ("query", "status") not in portal_loan_parameters,
        "portal loan-read requires path patron_id and correlation UUID without status filter",
    )
    portal_loan_schema = (
        portal_loan_get.get("responses", {}).get("200", {}).get("schema", {})
    )
    require(
        portal_loan_schema.get("additionalProperties") is False
        and set(portal_loan_schema.get("required", [])) == {"loans", "pagination"}
        and "portal_request_id"
        in portal_loan_schema.get("properties", {})
        .get("loans", {})
        .get("items", {})
        .get("properties", {})
        and "portal_ebook_uuid"
        not in portal_loan_schema.get("properties", {})
        .get("loans", {})
        .get("items", {})
        .get("properties", {})
        and "approved_by"
        not in portal_loan_schema.get("properties", {})
        .get("loans", {})
        .get("items", {})
        .get("properties", {}),
        "portal loan-read schema uses portal_request_id and forbids ebook UUID/approved_by",
    )
    require(
        set(portal_loan_get.get("responses", {}))
        == {"200", "400", "401", "403", "500", "503"},
        "portal loan-read response statuses are complete",
    )
    portal_loan_application = (
        ROOT / BUNDLE / "Service" / "PortalLoanReadApplication.pm"
    ).read_text(encoding="utf-8")
    patrons_controller = (
        ROOT / BUNDLE / "Controller" / "Patrons.pm"
    ).read_text(encoding="utf-8")
    loan_repository = (
        ROOT / BUNDLE / "Repository" / "LoanRepository.pm"
    ).read_text(encoding="utf-8")
    require(
        "PortalServiceAuthorization" in portal_loan_application
        and "StaffDecisionAuthorization" not in portal_loan_application
        and "sub list_patron_loans" in portal_loan_application
        and "list_for_patron" in portal_loan_application
        and "portal_ebook_uuid" not in portal_loan_application,
        "PortalLoanReadApplication uses portal authorization and repository list_for_patron",
    )
    public_fields_match = re.search(
        r"my @PUBLIC_LOAN_FIELDS = qw\((.*?)\);",
        portal_loan_application,
        re.S,
    )
    require(public_fields_match is not None, "portal loan public field allowlist exists")
    public_fields = public_fields_match.group(1)
    require(
        "portal_request_id" in public_fields
        and "approved_by" not in public_fields
        and "portal_ebook_uuid" not in public_fields,
        "portal loan public fields include portal_request_id and exclude approved_by/ebook UUID",
    )
    require(
        "sub list_loans" in patrons_controller
        and "PortalLoanReadApplication" in patrons_controller
        and "StaffDecisionAuthorization" not in patrons_controller
        and "X-Correlation-ID" in patrons_controller
        and "selectrow" not in patrons_controller
        and "INSERT" not in patrons_controller,
        "patrons controller is a thin read adapter without SQL writes",
    )
    list_for_patron_body = loan_repository.split("sub list_for_patron", 1)[-1]
    list_for_patron_body = re.split(
        r"\nsub [a-zA-Z_]", list_for_patron_body, maxsplit=1
    )[0]
    require(
        "INNER JOIN" in list_for_patron_body
        and "portal_request_id" in list_for_patron_body
        and "borrowers" not in list_for_patron_body
        and "FOR UPDATE" not in list_for_patron_body
        and not re.search(r"\b(?:INSERT|UPDATE|DELETE)\b", list_for_patron_body),
        "list_for_patron joins requests without borrower PII or writes",
    )
    require(
        "portal_ebook_uuid" not in json.dumps(portal_loan_get),
        "portal loan-read OpenAPI omits portal_ebook_uuid",
    )
    issue_post = openapi.get("/requests/{request_id}/issue", {}).get("post")
    require(
        isinstance(issue_post, dict)
        and issue_post.get("operationId") == "jzlIssueDigitalLoan"
        and issue_post.get("x-mojo-to")
        == "Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#issue",
        "staff issuance OpenAPI route and controller operation agree",
    )
    require(
        issue_post.get("x-koha-authorization", {}).get("permissions")
        == {"circulate": "circulate_remaining_permissions"},
        "staff issuance route declares established Koha permission",
    )
    issue_parameters = {
        (parameter.get("in"), parameter.get("name")): parameter
        for parameter in issue_post.get("parameters", [])
    }
    require(
        issue_parameters.get(("path", "request_id"), {}).get("required")
        and issue_parameters.get(("header", "X-Correlation-ID"), {}).get("required")
        and ("body", "body") not in issue_parameters,
        "staff issuance requires path and correlation header and no body",
    )
    require(
        set(issue_post.get("responses", {}))
        == {"201", "400", "401", "403", "404", "409", "500", "503"},
        "staff issuance response statuses are complete",
    )
    require(
        issue_post.get("responses", {})
        .get("201", {})
        .get("schema", {})
        .get("additionalProperties")
        is False,
        "staff issuance success schema forbids additional properties",
    )
    decision_post = openapi.get("/requests/{request_id}/decision", {}).get("post")
    require(
        isinstance(decision_post, dict)
        and decision_post.get("operationId") == "jzlDecideDigitalRequest"
        and decision_post.get("x-mojo-to")
        == "Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Requests#decide",
        "staff decision OpenAPI route and controller operation agree",
    )
    require(
        decision_post.get("x-koha-authorization", {}).get("permissions")
        == {"circulate": "circulate_remaining_permissions"},
        "staff decision route declares established Koha permission",
    )
    decision_parameters = {
        (parameter.get("in"), parameter.get("name")): parameter
        for parameter in decision_post.get("parameters", [])
    }
    require(
        decision_parameters.get(("path", "request_id"), {}).get("required")
        and decision_parameters.get(("header", "X-Correlation-ID"), {}).get(
            "required"
        )
        and decision_parameters.get(("body", "body"), {}).get("required"),
        "staff decision path, correlation header, and body are required",
    )
    decision_body = decision_parameters[("body", "body")]["schema"]
    require(
        decision_body.get("additionalProperties") is False
        and set(decision_body.get("required", []))
        == {"expected_row_version", "decision"}
        and decision_body.get("properties", {})
        .get("decision", {})
        .get("enum")
        == ["APPROVE", "REJECT"],
        "staff decision body is closed and command enum is exact",
    )
    require(
        set(decision_post.get("responses", {}))
        == {"200", "400", "401", "403", "404", "409", "500", "503"},
        "staff decision response statuses are complete",
    )
    request_controller = (
        ROOT / BUNDLE / "Controller" / "Requests.pm"
    ).read_text(encoding="utf-8")
    require(
        "sub decide" in request_controller
        and "_staff_request_decision_application" in request_controller
        and "StaffRequestDecisionApplication->new" in request_controller,
        "request controller exposes decision application adapter",
    )
    require(
        "sub issue" in request_controller
        and "_staff_loan_issuance_application" in request_controller
        and "StaffLoanIssuanceApplication->new" in request_controller
        and "issue_loan" in request_controller,
        "request controller exposes staff loan issuance application adapter",
    )
    issue_action = re.search(
        r"sub issue \{.*?\nsub ",
        request_controller,
        re.DOTALL,
    )
    require(issue_action is not None, "issuance controller action body is extractable")
    issue_body = issue_action.group()
    require(
        "X-Correlation-ID" in issue_body
        and "_uuid($correlation_id)" in issue_body
        and "_issue_body_rejected" in issue_body
        and "_staff_loan_issuance_application" in issue_body,
        "issuance action requires correlation UUID and rejects authority-bearing bodies",
    )
    require(
        all(
            token not in issue_body
            for token in (
                "patron_id =>",
                "biblio_id =>",
                "due_at =>",
                "actor_id =>",
                "duration",
            )
        ),
        "issuance controller does not accept caller patron, biblio, due date, or actor fields",
    )
    require(
        "@PUBLIC_LOAN_FIELDS" in request_controller
        and "_public_loan" in request_controller,
        "issuance controller enforces a safe response-field allowlist",
    )
    require(
        not re.search(
            r"\b(?:begin_work|commit|rollback|haspermission)\b|"
            r"PortalServiceAuthorization|portal_service_account_ids|"
            r"INSERT\s+INTO\s+`?plugin_jzl_ebook_(?:loans|renewals)|"
            r"\b(?:AddIssue|GetIssue)\b|reader[_-]?token|entitlement",
            request_controller,
            re.I,
        ),
        "request controller contains no transaction, permission, portal SQL, native issue, or reader-access work",
    )
    require("/assets/{asset}" in openapi, "OpenAPI asset route exists")
    require(
        "/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-css"
        in source,
        "CSS logical URL matches REST namespace",
    )
    require(
        "/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation-js"
        in source,
        "JavaScript logical URL matches REST namespace",
    )
    require(
        "/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation.css"
        not in source,
        "broken extension-bearing CSS URL is absent",
    )
    require(
        "/api/v1/contrib/jzl-digital-circulation/assets/jzl-digital-circulation.js"
        not in source,
        "broken extension-bearing JavaScript URL is absent",
    )
    require(len(manifest) == len(set(manifest)), "MANIFEST has no duplicate paths")
    for name in manifest:
        require(not pathlib.PurePosixPath(name).is_absolute(), f"manifest path is relative: {name}")


def check_archive(path: pathlib.Path) -> None:
    manifest = sorted(
        line.strip()
        for line in (ROOT / "MANIFEST").read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
    require(
        re.fullmatch(
            rf"JunaidZaidiLibrary-DigitalCirculation-v{re.escape(PLUGIN_VERSION)}"
            r"(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?\.kpz",
            path.name,
        )
        is not None,
        "archive filename matches internal plugin version",
    )
    require(path.stat().st_size >= 10_000, "archive is not suspiciously small")
    with zipfile.ZipFile(path) as archive:
        names = sorted(archive.namelist())
        bad = [
            name
            for name in names
            if re.search(
                r"(^|/)(\.git|t|diagnostics|node_modules|vendor|coverage|test-results|__pycache__)(/|$)"
                r"|(^|/)\.env($|\.)|\.(?:kpz|db|sqlite|sql|swp|pyc)$|~$|\.before-diagnostic$",
                name,
                re.I,
            )
        ]
        require(names == manifest, "archive tree exactly matches MANIFEST")
        require(not bad, "archive excludes secrets, dumps, caches, backups, and nested KPZ files")
        require(
            all(name.startswith("Koha/") and "\\" not in name for name in names),
            "archive uses package-relative Unix paths",
        )
        require(names.count(f"{BUNDLE_MANIFEST}.pm") == 1, "archive has one plugin root")
        require(f"{BUNDLE_MANIFEST}/tool.tt" in names, "archive contains tool.tt at bundle root")
        require(f"{BUNDLE_MANIFEST}/configure.tt" in names, "archive contains configure.tt at bundle root")
        require(not any(name.startswith("Koha_Digital_Circulation_Plugin/") for name in names), "archive has no extra top-level repository directory")
        packaged_main = archive.read(f"{BUNDLE_MANIFEST}.pm").decode("utf-8")
        require(
            f"our $VERSION             = '{PLUGIN_VERSION}';" in packaged_main,
            "packaged internal plugin version is 0.2.0",
        )
        require(
            "return 'jzl-digital-circulation';" in packaged_main,
            "packaged API namespace is unchanged",
        )
        packaged_openapi = json.loads(
            archive.read(f"{BUNDLE_MANIFEST}/openapi.json").decode("utf-8")
        )
        operation_ids = [
            operation.get("operationId")
            for path_item in packaged_openapi.values()
            for method, operation in path_item.items()
            if method.lower() in {"get", "post", "put", "patch", "delete"}
        ]
        require(
            len(operation_ids) == len(set(operation_ids)),
            "packaged OpenAPI operation IDs are unique",
        )
        post_routes = sorted(
            path for path, path_item in packaged_openapi.items() if "post" in path_item
        )
        require(
            post_routes
            == [
                "/loans/{loan_id}/return",
                "/requests",
                "/requests/{request_id}/decision",
                "/requests/{request_id}/issue",
            ],
            "packaged OpenAPI has exactly four POST routes including patron return",
        )
        require(
            packaged_openapi["/loans/{loan_id}/return"]["post"].get("operationId")
            == "jzlReturnDigitalLoan",
            "packaged return operation ID is correct",
        )
        require(
            packaged_openapi["/requests/{request_id}/issue"]["post"].get("operationId")
            == "jzlIssueDigitalLoan",
            "packaged issuance operation ID is correct",
        )
        post = packaged_openapi["/requests"]["post"]
        require(
            post.get("operationId") == "jzlCreateDigitalRequest",
            "packaged request operation ID is correct",
        )
        body = next(
            (
                parameter
                for parameter in post.get("parameters", [])
                if parameter.get("in") == "body" and parameter.get("name") == "body"
            ),
            None,
        )
        require(
            body is not None
            and body.get("required") is True
            and body.get("schema", {}).get("additionalProperties") is False,
            "packaged request body is required and closed",
        )
        headers = {
            parameter.get("name")
            for parameter in post.get("parameters", [])
            if parameter.get("in") == "header" and parameter.get("required") is True
        }
        require(
            {"Idempotency-Key", "X-Correlation-ID"} <= headers,
            "packaged required UUID headers are documented",
        )
        require(
            {"200", "201", "400", "401", "403", "404", "409", "500", "503"}
            <= set(post.get("responses", {})),
            "packaged request responses are complete",
        )
        tool = archive.read(f"{BUNDLE_MANIFEST}/tool.tt").decode("utf-8")
        packaged_staff_js = archive.read(
            f"{BUNDLE_MANIFEST}/static/js/jzl-digital-circulation.js"
        ).decode("utf-8")
        packaged_staff_ui = tool + "\n" + packaged_staff_js
        require(
            "Phase 2C — request decisions and loan issuance" in tool
            and "Approval alone does not create a loan" in tool
            and "does not grant protected-PDF reader access" in tool,
            "packaged staff tool states the Phase 2C decision and issuance boundary",
        )
        require(
            "approve.textContent = 'Approve'" in packaged_staff_js
            and "reject.textContent = 'Reject'" in packaged_staff_js
            and "request.status === 'PENDING'" in packaged_staff_js,
            "packaged staff tool exposes Approve and Reject only for pending requests",
        )
        require(
            "issue.textContent = 'Issue Loan'" in packaged_staff_js
            and "canIssueRequest(request)" in packaged_staff_js
            and "'/issue'" in packaged_staff_js
            and "submitIssuance" in packaged_staff_js,
            "packaged staff tool exposes Issue Loan for eligible approved requests",
        )
        require(
            "DECISION_PATH = '/requests/'" in packaged_staff_js
            and "'/decision'" in packaged_staff_js
            and "ISSUE_PATH = '/requests/'" in packaged_staff_js
            and "method: 'POST'" in packaged_staff_js
            and "credentials: 'same-origin'" in packaged_staff_js,
            "packaged staff decisions and issuance use only the same-origin verified REST endpoints",
        )
        require(
            "'X-Correlation-ID': correlationId" in packaged_staff_js
            and "expected_row_version: version" in packaged_staff_js
            and "window.crypto.randomUUID()" in packaged_staff_js
            and "window.crypto.getRandomValues(bytes)" in packaged_staff_js,
            "packaged staff writes use a fresh secure correlation UUID and row version",
        )
        require(
            "innerHTML" not in packaged_staff_js
            and "Authorization" not in packaged_staff_js
            and "portal_service_account_ids" not in packaged_staff_ui
            and "grantAccess" not in packaged_staff_js
            and "activateReader" not in packaged_staff_js,
            "packaged staff UI contains no unsafe HTML, authorization header, portal allowlist, or reader access",
        )
        for control in ("Create", "Delete", "Return", "Renew", "Revoke", "Edit"):
            require(
                re.search(rf">\s*{control}(?: Request)?\s*<", tool) is None
                and re.search(
                    rf"\.textContent\s*=\s*['\"]{control}(?: Request)?['\"]",
                    packaged_staff_js,
                )
                is None,
                f"packaged staff tool has no {control} write control",
            )
        require(
            f"{BUNDLE_MANIFEST}/Service/StaffLoanIssuanceApplication.pm" in names
            and f"{BUNDLE_MANIFEST}/Service/ConfiguredLoanPeriodPolicy.pm" in names
            and f"{BUNDLE_MANIFEST}/Service/LoanIssuanceService.pm" in names,
            "packaged archive includes Phase 2C issuance runtime modules",
        )
        require(
            f"{BUNDLE_MANIFEST}/Service/LoanReturnService.pm" in names
            and f"{BUNDLE_MANIFEST}/Service/PortalLoanReturnApplication.pm" in names
            and f"{BUNDLE_MANIFEST}/Controller/Loans.pm" in names,
            "packaged archive includes Phase 4B return runtime modules",
        )
        configure = archive.read(f"{BUNDLE_MANIFEST}/configure.tt").decode("utf-8")
        require('name="csrf_token"' in configure, "packaged configuration includes CSRF token field")
        require(
            re.search(
                r'name="[^"]*(?:client_secret|bearer|password|database|dsn)[^"]*"',
                configure,
                re.I,
            )
            is None,
            "packaged configuration requests no credentials",
        )
        production = "\n".join(
            archive.read(name).decode("utf-8")
            for name in names
            if re.search(r"\.(?:pm|json|tt|js|css)$", name, re.I)
        )
        require(
            not contains_forbidden_production_content(production),
            "packaged production files contain no paths or literal credentials",
        )
    print(f"SHA-256: {hashlib.sha256(path.read_bytes()).hexdigest()}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kpz", type=pathlib.Path)
    args = parser.parse_args()
    try:
        check_path_scan_contract()
        check_source()
        if args.kpz:
            check_archive(args.kpz.resolve())
    except (AssertionError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"not ok - {error}", file=sys.stderr)
        return 1
    print("Source/package validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
