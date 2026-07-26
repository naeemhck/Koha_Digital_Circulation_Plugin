(function () {
    'use strict';

    var script = document.currentScript;
    var toolUrl = script && script.dataset.jzlUrl;
    if (toolUrl) {
        // Navigation-only Circulation shortcut. Does not call request/loan APIs.
        // Koha 26.05 circulation-home uses .circulation-actions ul.buttons-list;
        // keep legacy #circ-menu / aria-label selectors for older templates.
        if (!document.getElementById('jzl-digital-circulation-shortcut')) {
            var menu = document.querySelector(
                '.circulation-actions ul.buttons-list,#circ-menu ul,nav[aria-label="Circulation"] ul'
            );
            if (menu) {
                var item = document.createElement('li');
                var link = document.createElement('a');
                link.id = 'jzl-digital-circulation-shortcut';
                link.className = 'circ-button jzl-digital-link';
                link.href = toolUrl;
                link.textContent = 'Digital Circulation';
                item.appendChild(link);
                menu.appendChild(item);
            }
        }
        return;
    }

    var table = document.getElementById('jzl-table');
    if (!table) {
        return;
    }

    var API_BASE = '/api/v1/contrib/jzl-digital-circulation';
    var DECISION_PATH = '/requests/';
    var ISSUE_PATH = '/requests/';
    var MAX_REASON_LENGTH = 4096;
    var PUBLIC_DECISION_FIELDS = [
        'request_id',
        'portal_request_id',
        'patron_id',
        'biblio_id',
        'status',
        'requested_at',
        'approved_at',
        'approved_by',
        'rejected_at',
        'rejected_by',
        'rejection_reason',
        'row_version'
    ];
    var PUBLIC_LOAN_SUMMARY_FIELDS = [
        'loan_id',
        'loan_status',
        'loan_started_at',
        'loan_due_at',
        'loan_row_version'
    ];
    var SAFE_COLUMNS = {
        loans: [
            'loan_id', 'request_id', 'patron_name', 'patron_id', 'title',
            'biblio_id', 'status', 'started_at', 'due_at', 'returned_at',
            'revoked_at', 'expired_at', 'approved_by'
        ],
        renewals: [
            'renewal_id', 'loan_id', 'patron_name', 'patron_id', 'title',
            'biblio_id', 'status', 'requested_at', 'previous_due_at',
            'proposed_due_at', 'decided_at', 'decided_by'
        ],
        events: [
            'event_id', 'event_type', 'aggregate_type', 'aggregate_id',
            'request_id', 'loan_id', 'renewal_id', 'patron_id', 'biblio_id',
            'actor_patron_id', 'source', 'occurred_at', 'delivery_status',
            'delivery_attempts', 'next_delivery_at', 'delivered_at',
            'last_error_code'
        ]
    };
    var ERROR_MESSAGES = {
        INVALID_INPUT: 'The submitted request was invalid.',
        INVALID_DECISION: 'The selected decision was invalid.',
        INVALID_REASON: 'Enter a valid rejection reason.',
        AUTHENTICATION_REQUIRED:
            'Your Koha session has expired. Sign in again before continuing.',
        STAFF_NOT_AUTHORIZED:
            'You are not authorized to decide digital requests.',
        REQUEST_NOT_FOUND: 'The request no longer exists.',
        VERSION_CONFLICT:
            'This request changed after the page was loaded. Refreshing the current request state.',
        REQUEST_ALREADY_DECIDED:
            'This request has already been decided. The current status will be refreshed.',
        INVALID_STATE:
            'This request cannot be decided in its current state. The current status will be refreshed.',
        DIGITAL_CIRCULATION_UNAVAILABLE:
            'Digital Circulation is temporarily unavailable. No decision was recorded.',
        INTERNAL_ERROR:
            'The decision could not be completed. No result should be assumed.'
    };
    var ISSUE_ERROR_MESSAGES = {
        INVALID_INPUT:
            'The issuance request was invalid. Refresh the page and try again.',
        AUTHENTICATION_REQUIRED:
            'Your Koha session has expired. Sign in again before continuing.',
        STAFF_NOT_AUTHORIZED:
            'You are not authorized to issue digital loans.',
        REQUEST_NOT_FOUND: 'This digital request no longer exists.',
        REQUEST_NOT_APPROVED:
            'Only an approved digital request can be issued.',
        LOAN_ALREADY_EXISTS:
            'A digital loan already exists for this request.',
        INVALID_MAPPING:
            'The protected-content mapping is no longer valid.',
        PROTECTED_CONTENT_UNAVAILABLE:
            'Protected digital content is temporarily unavailable.',
        INVALID_LOAN_PERIOD:
            'Digital loan duration is not configured correctly. Contact a system administrator.',
        DIGITAL_CIRCULATION_UNAVAILABLE:
            'Digital circulation is temporarily unavailable.',
        INTERNAL_ERROR:
            'The digital loan could not be issued because of an internal error.'
    };

    var tabs = document.querySelectorAll('.jzl-tab');
    var filterForm = document.getElementById('jzl-filters');
    var searchInput = document.getElementById('jzl-search');
    var statusRegion = document.getElementById('jzl-status');
    var errorRegion = document.getElementById('jzl-error');
    var loading = document.getElementById('jzl-loading');
    var empty = document.getElementById('jzl-empty');
    var pagination = document.getElementById('jzl-pagination');
    var region = table.closest('section');
    var rejectDialog = document.getElementById('jzl-reject-dialog');
    var rejectForm = document.getElementById('jzl-reject-form');
    var rejectLabel = document.getElementById('jzl-reject-request-label');
    var rejectReason = document.getElementById('jzl-reject-reason');
    var rejectError = document.getElementById('jzl-reject-error');
    var rejectCancel = document.getElementById('jzl-reject-cancel');
    var rejectSubmit = document.getElementById('jzl-reject-submit');

    var current = 'requests-PENDING';
    var page = 1;
    var rows = [];
    var pageInfo = {};
    var inFlight = Object.create(null);
    var loadSequence = 0;
    var rejectContext = null;
    var rejectSubmitting = false;

    function clear(node) {
        while (node.firstChild) {
            node.removeChild(node.firstChild);
        }
    }

    function text(value) {
        return value === null || value === undefined ? '' : String(value);
    }

    function title(value) {
        return text(value).replace(/_/g, ' ');
    }

    function positiveInteger(value) {
        return (
            (typeof value === 'number' && Number.isInteger(value) && value > 0) ||
            (typeof value === 'string' && /^[1-9][0-9]*$/.test(value))
        );
    }

    function requestId(row) {
        return positiveInteger(row.request_id) ? Number(row.request_id) : null;
    }

    function requestVersion(row) {
        return positiveInteger(row.row_version) ? Number(row.row_version) : null;
    }

    function uuid() {
        if (
            window.crypto &&
            typeof window.crypto.randomUUID === 'function'
        ) {
            return window.crypto.randomUUID();
        }
        if (
            !window.crypto ||
            typeof window.crypto.getRandomValues !== 'function'
        ) {
            throw new Error('UUID_UNAVAILABLE');
        }
        var bytes = new Uint8Array(16);
        window.crypto.getRandomValues(bytes);
        bytes[6] = (bytes[6] & 15) | 64;
        bytes[8] = (bytes[8] & 63) | 128;
        var hex = Array.prototype.map.call(bytes, function (byte) {
            return byte.toString(16).padStart(2, '0');
        });
        return (
            hex.slice(0, 4).join('') + '-' +
            hex.slice(4, 6).join('') + '-' +
            hex.slice(6, 8).join('') + '-' +
            hex.slice(8, 10).join('') + '-' +
            hex.slice(10, 16).join('')
        );
    }

    function notify(message, type) {
        statusRegion.textContent = message;
        statusRegion.className = 'alert alert-' + type;
        statusRegion.setAttribute(
            'role',
            type === 'danger' ? 'alert' : 'status'
        );
        statusRegion.setAttribute(
            'aria-live',
            type === 'danger' ? 'assertive' : 'polite'
        );
        statusRegion.hidden = false;
    }

    function hideNotification() {
        statusRegion.hidden = true;
        statusRegion.textContent = '';
    }

    function showPageError(message) {
        errorRegion.textContent = message;
        errorRegion.hidden = false;
    }

    function hidePageError() {
        errorRegion.hidden = true;
        errorRegion.textContent = '';
    }

    function safeErrorCode(response, body, messages) {
        var table = messages || ERROR_MESSAGES;
        if (
            body &&
            typeof body === 'object' &&
            body.error &&
            typeof body.error === 'object' &&
            typeof body.error.code === 'string' &&
            Object.prototype.hasOwnProperty.call(table, body.error.code)
        ) {
            return body.error.code;
        }
        if (response.status === 401) {
            return 'AUTHENTICATION_REQUIRED';
        }
        if (response.status === 403) {
            return 'STAFF_NOT_AUTHORIZED';
        }
        if (response.status === 404) {
            return 'REQUEST_NOT_FOUND';
        }
        if (response.status === 500) {
            return 'INTERNAL_ERROR';
        }
        if (response.status === 503) {
            return 'DIGITAL_CIRCULATION_UNAVAILABLE';
        }
        return 'INTERNAL_ERROR';
    }

    function loanPresence(request) {
        var hasId = positiveInteger(request.loan_id);
        var status = request.loan_status;
        var hasStatus =
            typeof status === 'string' && status.length > 0 && !/^\s+$/.test(status);
        var blankSummary =
            !hasId &&
            (status === null || status === undefined || status === '') &&
            (request.loan_started_at === null ||
                request.loan_started_at === undefined ||
                request.loan_started_at === '') &&
            (request.loan_due_at === null ||
                request.loan_due_at === undefined ||
                request.loan_due_at === '') &&
            (request.loan_row_version === null ||
                request.loan_row_version === undefined ||
                request.loan_row_version === '');
        if (blankSummary) {
            return 'absent';
        }
        if (
            hasId &&
            hasStatus &&
            positiveInteger(request.loan_row_version) &&
            typeof request.loan_started_at === 'string' &&
            request.loan_started_at.length > 0 &&
            typeof request.loan_due_at === 'string' &&
            request.loan_due_at.length > 0
        ) {
            return 'present';
        }
        return 'ambiguous';
    }

    function canIssueRequest(request) {
        return (
            request &&
            request.status === 'APPROVED' &&
            requestId(request) !== null &&
            loanPresence(request) === 'absent'
        );
    }

    function parseJsonResponse(response) {
        return response.text().then(function (bodyText) {
            var body;
            try {
                body = JSON.parse(bodyText);
            } catch (error) {
                throw new Error('MALFORMED_RESPONSE');
            }
            if (!body || typeof body !== 'object' || Array.isArray(body)) {
                throw new Error('MALFORMED_RESPONSE');
            }
            return { response: response, body: body };
        });
    }

    function copyPublicDecisionRequest(original, authoritative) {
        var merged = {};
        Object.keys(original).forEach(function (key) {
            merged[key] = original[key];
        });
        PUBLIC_DECISION_FIELDS.forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(authoritative, key)) {
                merged[key] = authoritative[key];
            }
        });
        PUBLIC_LOAN_SUMMARY_FIELDS.forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(authoritative, key)) {
                merged[key] = authoritative[key];
            }
        });
        return merged;
    }

    function validDecisionSuccess(body, row, decision) {
        var expectedStatus = decision === 'APPROVE' ? 'APPROVED' : 'REJECTED';
        return (
            body &&
            body.previous_status === 'PENDING' &&
            body.new_status === expectedStatus &&
            positiveInteger(body.previous_row_version) &&
            Number(body.previous_row_version) === requestVersion(row) &&
            positiveInteger(body.row_version) &&
            Number(body.row_version) === requestVersion(row) + 1 &&
            body.request &&
            typeof body.request === 'object' &&
            requestId(body.request) === requestId(row) &&
            body.request.status === expectedStatus &&
            requestVersion(body.request) === Number(body.row_version)
        );
    }

    function replaceRequest(authoritative, original) {
        var id = requestId(authoritative);
        rows = rows.map(function (row) {
            return requestId(row) === id
                ? copyPublicDecisionRequest(original || row, authoritative)
                : row;
        });
        renderCurrent();
    }

    function backgroundRefreshRequest(id) {
        return fetch(API_BASE + '/requests/' + encodeURIComponent(String(id)), {
            credentials: 'same-origin',
            headers: { Accept: 'application/json' }
        })
            .then(function (response) {
                if (!response.ok) {
                    throw new Error('REFRESH_FAILED');
                }
                return parseJsonResponse(response);
            })
            .then(function (result) {
                var authoritative = result.body;
                if (
                    requestId(authoritative) !== id ||
                    !positiveInteger(authoritative.row_version) ||
                    typeof authoritative.status !== 'string'
                ) {
                    throw new Error('REFRESH_FAILED');
                }
                var original = rows.find(function (row) {
                    return requestId(row) === id;
                }) || {};
                replaceRequest(authoritative, original);
            })
            .catch(function () {
                return undefined;
            });
    }

    function decisionEndpoint(id) {
        return (
            API_BASE +
            DECISION_PATH +
            encodeURIComponent(String(id)) +
            '/decision'
        );
    }

    function issueEndpoint(id) {
        return (
            API_BASE +
            ISSUE_PATH +
            encodeURIComponent(String(id)) +
            '/issue'
        );
    }

    function refreshForCode(code) {
        return (
            code === 'VERSION_CONFLICT' ||
            code === 'REQUEST_ALREADY_DECIDED' ||
            code === 'INVALID_STATE' ||
            code === 'REQUEST_NOT_FOUND' ||
            code === 'DIGITAL_CIRCULATION_UNAVAILABLE' ||
            code === 'INTERNAL_ERROR'
        );
    }

    function refreshForIssueCode(code) {
        return (
            code === 'LOAN_ALREADY_EXISTS' ||
            code === 'REQUEST_NOT_APPROVED' ||
            code === 'REQUEST_NOT_FOUND' ||
            code === 'INVALID_MAPPING' ||
            code === 'DIGITAL_CIRCULATION_UNAVAILABLE' ||
            code === 'INTERNAL_ERROR' ||
            code === 'INVALID_LOAN_PERIOD' ||
            code === 'PROTECTED_CONTENT_UNAVAILABLE'
        );
    }

    function finishFailure(row, response, body) {
        var id = requestId(row);
        var code = safeErrorCode(response, body);
        notify(ERROR_MESSAGES[code], 'danger');
        delete inFlight[id];
        if (refreshForCode(code)) {
            return load();
        }
        renderCurrent();
        return Promise.resolve();
    }

    function finishIssuanceFailure(row, response, body) {
        var id = requestId(row);
        var code = safeErrorCode(response, body, ISSUE_ERROR_MESSAGES);
        notify(ISSUE_ERROR_MESSAGES[code], 'danger');
        delete inFlight[id];
        if (refreshForIssueCode(code)) {
            return load();
        }
        renderCurrent();
        return Promise.resolve();
    }

    function validTimestamp(value) {
        return (
            typeof value === 'string' &&
            /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/.test(
                value
            )
        );
    }

    function validIssuanceSuccess(body, row) {
        if (!body || typeof body !== 'object' || Array.isArray(body)) {
            return false;
        }
        var keys = Object.keys(body).sort();
        var expected = [
            'biblio_id',
            'due_at',
            'loan_id',
            'patron_id',
            'request_id',
            'row_version',
            'started_at',
            'status'
        ];
        if (keys.length !== expected.length) {
            return false;
        }
        for (var i = 0; i < expected.length; i += 1) {
            if (keys[i] !== expected[i]) {
                return false;
            }
        }
        return (
            positiveInteger(body.loan_id) &&
            requestId(body) === requestId(row) &&
            positiveInteger(body.patron_id) &&
            positiveInteger(body.biblio_id) &&
            body.status === 'ACTIVE' &&
            validTimestamp(body.started_at) &&
            validTimestamp(body.due_at) &&
            body.due_at > body.started_at &&
            positiveInteger(body.row_version)
        );
    }

    function applyIssuanceLoanSummary(original, body) {
        var merged = {};
        Object.keys(original).forEach(function (key) {
            merged[key] = original[key];
        });
        merged.loan_id = body.loan_id;
        merged.loan_status = body.status;
        merged.loan_started_at = body.started_at;
        merged.loan_due_at = body.due_at;
        merged.loan_row_version = body.row_version;
        return merged;
    }

    function confirmIssuance(row, trigger) {
        var confirmed = window.confirm(
            'Issue an ACTIVE digital loan for this approved request?\n\n' +
            'This creates an ACTIVE plugin-owned digital loan. ' +
            'The due date is calculated from configured policy. ' +
            'Approval alone did not create the loan. ' +
            'This action still does not grant protected-PDF reader access. ' +
            'A second loan cannot be created for the same request.'
        );
        if (!confirmed) {
            trigger.focus();
            return;
        }
        submitIssuance(row);
    }

    function submitIssuance(row) {
        var id = requestId(row);
        if (!canIssueRequest(row) || inFlight[id]) {
            notify(ISSUE_ERROR_MESSAGES.INVALID_INPUT, 'danger');
            return Promise.resolve();
        }

        var correlationId;
        try {
            correlationId = uuid();
        } catch (error) {
            notify(
                'A secure correlation identifier could not be generated. No loan was issued.',
                'danger'
            );
            return Promise.resolve();
        }

        inFlight[id] = true;
        hideNotification();
        renderCurrent();

        return fetch(issueEndpoint(id), {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
                Accept: 'application/json',
                'X-Correlation-ID': correlationId
            }
        })
            .then(parseJsonResponse)
            .then(function (result) {
                if (result.response.status !== 201) {
                    return finishIssuanceFailure(
                        row,
                        result.response,
                        result.body
                    );
                }
                if (!validIssuanceSuccess(result.body, row)) {
                    throw new Error('MALFORMED_RESPONSE');
                }
                delete inFlight[id];
                rows = rows.map(function (currentRow) {
                    return requestId(currentRow) === id
                        ? applyIssuanceLoanSummary(currentRow, result.body)
                        : currentRow;
                });
                renderCurrent();
                notify('Digital loan issued successfully.', 'success');
                return backgroundRefreshRequest(id);
            })
            .catch(function () {
                delete inFlight[id];
                notify(ISSUE_ERROR_MESSAGES.INTERNAL_ERROR, 'danger');
                return load();
            });
    }

    function submitDecision(row, decision, reason) {
        var id = requestId(row);
        var version = requestVersion(row);
        if (
            id === null ||
            version === null ||
            row.status !== 'PENDING' ||
            inFlight[id]
        ) {
            notify(ERROR_MESSAGES.INVALID_INPUT, 'danger');
            return Promise.resolve();
        }

        var correlationId;
        try {
            correlationId = uuid();
        } catch (error) {
            notify(
                'A secure correlation identifier could not be generated. No decision was recorded.',
                'danger'
            );
            return Promise.resolve();
        }

        inFlight[id] = true;
        hideNotification();
        renderCurrent();

        var command = {
            expected_row_version: version,
            decision: decision,
            reason: decision === 'APPROVE' ? null : reason
        };

        return fetch(decisionEndpoint(id), {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
                'Content-Type': 'application/json',
                'X-Correlation-ID': correlationId
            },
            body: JSON.stringify(command)
        })
            .then(parseJsonResponse)
            .then(function (result) {
                if (result.response.status !== 200) {
                    return finishFailure(row, result.response, result.body);
                }
                if (!validDecisionSuccess(result.body, row, decision)) {
                    throw new Error('MALFORMED_RESPONSE');
                }
                delete inFlight[id];
                replaceRequest(result.body.request, row);
                notify(
                    decision === 'APPROVE'
                        ? 'Request approved successfully.'
                        : 'Request rejected successfully.',
                    'success'
                );
                return backgroundRefreshRequest(id);
            })
            .catch(function () {
                delete inFlight[id];
                notify(ERROR_MESSAGES.INTERNAL_ERROR, 'danger');
                return load();
            });
    }

    function appendTextCell(row, value, className) {
        var cell = document.createElement('td');
        if (className) {
            cell.className = className;
        }
        cell.textContent = text(value);
        row.appendChild(cell);
        return cell;
    }

    function appendHeader(headerRow, label) {
        var header = document.createElement('th');
        header.scope = 'col';
        header.textContent = label;
        headerRow.appendChild(header);
    }

    function statusBadge(value) {
        var status = text(value);
        var badge = document.createElement('span');
        badge.className =
            'jzl-status-badge jzl-status-' + status.toLowerCase();
        badge.textContent = status || 'UNKNOWN';
        return badge;
    }

    function patronLabel(row) {
        return row.patron_name
            ? text(row.patron_name) + ' (' + text(row.patron_id) + ')'
            : text(row.patron_id);
    }

    function biblioLabel(row) {
        return row.title
            ? text(row.title) + ' (' + text(row.biblio_id) + ')'
            : text(row.biblio_id);
    }

    function decisionText(row) {
        if (row.status === 'APPROVED') {
            return (
                'Approved ' +
                text(row.approved_at) +
                ' by staff ' +
                text(row.approved_by)
            );
        }
        if (row.status === 'REJECTED') {
            return (
                'Rejected ' +
                text(row.rejected_at) +
                ' by staff ' +
                text(row.rejected_by)
            );
        }
        if (row.status === 'CANCELLED') {
            return 'Cancelled ' + text(row.cancelled_at);
        }
        return '';
    }

    function confirmApproval(row, trigger) {
        var approved = window.confirm(
            'Approve this digital request?\n\n' +
            'This records the librarian decision only. ' +
            'It does not create a loan or grant digital access.'
        );
        if (!approved) {
            trigger.focus();
            return;
        }
        submitDecision(row, 'APPROVE', null);
    }

    function validateReason(reason) {
        return (
            typeof reason === 'string' &&
            reason.trim().length > 0 &&
            reason.length <= MAX_REASON_LENGTH
        );
    }

    function openRejectDialog(row, trigger) {
        if (
            !rejectDialog ||
            typeof rejectDialog.showModal !== 'function'
        ) {
            var fallbackReason = window.prompt(
                'Reject digital request ' + text(row.request_id) +
                '. Enter a required plain-text reason (maximum 4,096 characters).'
            );
            if (fallbackReason === null) {
                trigger.focus();
                return;
            }
            if (!validateReason(fallbackReason)) {
                notify(ERROR_MESSAGES.INVALID_REASON, 'danger');
                trigger.focus();
                return;
            }
            submitDecision(row, 'REJECT', fallbackReason);
            return;
        }

        rejectContext = { row: row, trigger: trigger };
        rejectSubmitting = false;
        rejectLabel.textContent = '#' + text(row.request_id);
        rejectReason.value = '';
        rejectReason.disabled = false;
        rejectError.textContent = '';
        rejectError.hidden = true;
        rejectCancel.disabled = false;
        rejectSubmit.disabled = false;
        rejectDialog.hidden = false;
        rejectDialog.showModal();
        rejectReason.focus();
    }

    function appendLoanSummaryCell(tableRow, request) {
        var cell = document.createElement('td');
        var presence = loanPresence(request);
        if (presence === 'present') {
            var summary = document.createElement('div');
            summary.className = 'jzl-loan-summary';
            var titleNode = document.createElement('span');
            titleNode.className = 'jzl-loan-summary-title';
            titleNode.textContent = 'Active digital loan';
            summary.appendChild(titleNode);
            summary.appendChild(document.createElement('br'));
            var statusNode = document.createElement('span');
            statusNode.appendChild(statusBadge(request.loan_status));
            summary.appendChild(statusNode);
            summary.appendChild(document.createElement('br'));
            var started = document.createElement('span');
            started.textContent = 'Started ' + text(request.loan_started_at);
            summary.appendChild(started);
            summary.appendChild(document.createElement('br'));
            var due = document.createElement('span');
            due.textContent = 'Due ' + text(request.loan_due_at);
            summary.appendChild(due);
            cell.appendChild(summary);
        } else if (presence === 'ambiguous') {
            cell.textContent = 'Loan state unavailable';
        } else {
            cell.textContent = 'No digital loan';
        }
        tableRow.appendChild(cell);
    }

    function appendRequestActions(tableRow, request) {
        var cell = document.createElement('td');
        var id = requestId(request);
        var busy = id !== null && Boolean(inFlight[id]);

        if (request.status === 'PENDING' && id !== null) {
            var decisionActions = document.createElement('div');
            decisionActions.className = 'jzl-decision-actions';
            cell.appendChild(decisionActions);

            var approve = document.createElement('button');
            approve.type = 'button';
            approve.className = 'btn btn-primary btn-sm';
            approve.textContent = 'Approve';
            approve.setAttribute(
                'aria-label',
                'Approve digital request ' + text(id)
            );

            var reject = document.createElement('button');
            reject.type = 'button';
            reject.className = 'btn btn-danger btn-sm';
            reject.textContent = 'Reject';
            reject.setAttribute(
                'aria-label',
                'Reject digital request ' + text(id)
            );

            approve.disabled = busy;
            reject.disabled = busy;
            approve.addEventListener('click', function () {
                confirmApproval(request, approve);
            });
            reject.addEventListener('click', function () {
                openRejectDialog(request, reject);
            });
            decisionActions.appendChild(approve);
            decisionActions.appendChild(reject);

            if (busy) {
                var decisionProgress = document.createElement('span');
                decisionProgress.className = 'jzl-decision-progress';
                decisionProgress.setAttribute('role', 'status');
                decisionProgress.textContent = 'Decision in progress…';
                decisionActions.appendChild(decisionProgress);
            }
        } else if (canIssueRequest(request)) {
            var issueActions = document.createElement('div');
            issueActions.className = 'jzl-issue-actions';
            cell.appendChild(issueActions);

            var issue = document.createElement('button');
            issue.type = 'button';
            issue.className = 'btn btn-success btn-sm';
            issue.textContent = 'Issue Loan';
            issue.setAttribute(
                'aria-label',
                'Issue digital loan for approved request ' + text(id)
            );
            issue.disabled = busy;
            issue.addEventListener('click', function () {
                confirmIssuance(request, issue);
            });
            issueActions.appendChild(issue);

            if (busy) {
                var issueProgress = document.createElement('span');
                issueProgress.className = 'jzl-issue-progress';
                issueProgress.setAttribute('role', 'status');
                issueProgress.textContent = 'Issuance in progress…';
                issueActions.appendChild(issueProgress);
            }
        } else if (request.status === 'APPROVED' && loanPresence(request) === 'present') {
            cell.textContent = 'No issuance actions';
        } else if (request.status === 'APPROVED' && loanPresence(request) === 'ambiguous') {
            cell.textContent = 'Issuance unavailable';
        } else {
            cell.textContent = 'No decision actions';
        }

        tableRow.appendChild(cell);
    }

    function renderRequests(displayRows) {
        var labels = [
            'Request ID',
            'Patron',
            'Bibliographic record',
            'Status',
            'Requested',
            'Row version',
            'Decision',
            'Rejection reason',
            'Digital loan',
            'Actions'
        ];
        var headerRow = document.createElement('tr');
        labels.forEach(function (label) {
            appendHeader(headerRow, label);
        });
        table.tHead.appendChild(headerRow);

        displayRows.forEach(function (request) {
            var row = document.createElement('tr');
            appendTextCell(row, request.request_id);
            appendTextCell(row, patronLabel(request));
            appendTextCell(row, biblioLabel(request));
            var statusCell = document.createElement('td');
            statusCell.appendChild(statusBadge(request.status));
            row.appendChild(statusCell);
            appendTextCell(row, request.requested_at);
            appendTextCell(row, request.row_version);
            appendTextCell(row, decisionText(request));
            appendTextCell(
                row,
                request.status === 'REJECTED'
                    ? request.rejection_reason
                    : '',
                'jzl-rejection-reason'
            );
            appendLoanSummaryCell(row, request);
            appendRequestActions(row, request);
            table.tBodies[0].appendChild(row);
        });
    }

    function renderGeneric(resource, displayRows) {
        var columns = SAFE_COLUMNS[resource] || [];
        var headerRow = document.createElement('tr');
        columns.forEach(function (column) {
            appendHeader(headerRow, title(column));
        });
        table.tHead.appendChild(headerRow);
        displayRows.forEach(function (record) {
            var row = document.createElement('tr');
            columns.forEach(function (column) {
                appendTextCell(row, record[column]);
            });
            table.tBodies[0].appendChild(row);
        });
    }

    function filteredRows() {
        var query = searchInput ? searchInput.value.trim().toLowerCase() : '';
        if (!query) {
            return rows.slice();
        }
        return rows.filter(function (row) {
            return [
                row.request_id,
                row.portal_request_id,
                row.patron_id,
                row.patron_name,
                row.biblio_id,
                row.title,
                row.status
            ].some(function (value) {
                return text(value).toLowerCase().indexOf(query) !== -1;
            });
        });
    }

    function renderCurrent() {
        var resource = current.split('-')[0];
        var displayRows = filteredRows();
        clear(table.tHead);
        clear(table.tBodies[0]);
        if (resource === 'requests') {
            renderRequests(displayRows);
        } else {
            renderGeneric(resource, displayRows);
        }
        empty.hidden = displayRows.length !== 0;
        pagination.textContent =
            pageInfo.total !== undefined
                ? (
                    'Page ' + text(pageInfo.page) +
                    ' of ' + text(pageInfo.total_pages) +
                    ' — ' + text(pageInfo.total) + ' records'
                )
                : '';
    }

    function load() {
        var parts = current.split('-');
        var resource = parts[0];
        var status = parts.slice(1).join('-');
        var sequence = ++loadSequence;
        var url =
            API_BASE + '/' + resource +
            '?page=' + page +
            '&per_page=25' +
            (status ? '&status=' + encodeURIComponent(status) : '');

        region.setAttribute('aria-busy', 'true');
        loading.hidden = false;
        hidePageError();

        return fetch(url, {
            credentials: 'same-origin',
            headers: { Accept: 'application/json' }
        })
            .then(function (response) {
                if (response.status === 401) {
                    throw new Error('AUTHENTICATION_REQUIRED');
                }
                if (response.status === 403) {
                    throw new Error('STAFF_NOT_AUTHORIZED');
                }
                if (!response.ok) {
                    throw new Error('LOAD_FAILED');
                }
                return parseJsonResponse(response);
            })
            .then(function (result) {
                if (
                    sequence !== loadSequence ||
                    !Array.isArray(result.body.data) ||
                    !result.body.pagination ||
                    typeof result.body.pagination !== 'object'
                ) {
                    if (sequence !== loadSequence) {
                        return;
                    }
                    throw new Error('MALFORMED_RESPONSE');
                }
                rows = result.body.data;
                pageInfo = result.body.pagination;
                renderCurrent();
            })
            .catch(function (error) {
                if (sequence !== loadSequence) {
                    return;
                }
                rows = [];
                pageInfo = {};
                renderCurrent();
                if (error.message === 'AUTHENTICATION_REQUIRED') {
                    showPageError(ERROR_MESSAGES.AUTHENTICATION_REQUIRED);
                } else if (error.message === 'STAFF_NOT_AUTHORIZED') {
                    showPageError(ERROR_MESSAGES.STAFF_NOT_AUTHORIZED);
                } else {
                    showPageError('The records could not be loaded safely.');
                }
            })
            .then(function () {
                if (sequence === loadSequence) {
                    loading.hidden = true;
                    region.setAttribute('aria-busy', 'false');
                }
            });
    }

    if (rejectCancel) {
        rejectCancel.addEventListener('click', function () {
            if (!rejectSubmitting) {
                rejectDialog.close('cancel');
            }
        });
    }

    if (rejectDialog) {
        rejectDialog.addEventListener('cancel', function (event) {
            if (rejectSubmitting) {
                event.preventDefault();
            }
        });
        rejectDialog.addEventListener('close', function () {
            rejectDialog.hidden = true;
            if (
                rejectContext &&
                rejectContext.trigger &&
                !rejectSubmitting
            ) {
                rejectContext.trigger.focus();
            }
            if (!rejectSubmitting) {
                rejectContext = null;
            }
        });
    }

    if (rejectForm) {
        rejectForm.addEventListener('submit', function (event) {
            event.preventDefault();
            if (rejectSubmitting || !rejectContext) {
                return;
            }
            var reason = rejectReason.value;
            if (!validateReason(reason)) {
                rejectError.textContent = ERROR_MESSAGES.INVALID_REASON;
                rejectError.hidden = false;
                rejectReason.focus();
                return;
            }
            rejectSubmitting = true;
            rejectReason.disabled = true;
            rejectCancel.disabled = true;
            rejectSubmit.disabled = true;
            var context = rejectContext;
            submitDecision(context.row, 'REJECT', reason).then(function () {
                rejectSubmitting = false;
                rejectDialog.close('submitted');
                rejectContext = null;
            });
        });
    }

    if (filterForm) {
        filterForm.addEventListener('submit', function (event) {
            event.preventDefault();
            renderCurrent();
        });
    }

    tabs.forEach(function (tab) {
        tab.addEventListener('click', function () {
            current = tab.dataset.view;
            page = 1;
            rows = [];
            pageInfo = {};
            hideNotification();
            tabs.forEach(function (candidate) {
                candidate.setAttribute(
                    'aria-selected',
                    candidate === tab ? 'true' : 'false'
                );
            });
            document.getElementById('jzl-view-heading').textContent =
                tab.textContent;
            load();
        });
    });

    if (tabs[0]) {
        tabs[0].setAttribute('aria-selected', 'true');
        load();
    }
}());
