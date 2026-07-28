#!/usr/bin/env python3
"""Disposable Phase 5 lifecycle semantics and source-contract simulation."""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation"


@dataclass
class Loan:
    status: str = "ACTIVE"
    due_at: datetime = datetime(2030, 1, 1, tzinfo=timezone.utc)
    renewal_count: int = 0
    row_version: int = 1
    returned_at: datetime | None = None
    revoked_at: datetime | None = None
    expired_at: datetime | None = None
    progress: int = 37


class Lifecycle:
    def __init__(self, loan: Loan):
        self.loan = loan
        self.events: dict[tuple[str, str], dict] = {}

    def renew(self, expected: int, correlation: str, now: datetime, fail_event=False):
        key = ("LOAN_RENEWED", correlation)
        if key in self.events:
            return deepcopy(self.loan), True
        before = deepcopy(self.loan)
        if self.loan.status != "ACTIVE" or self.loan.row_version != expected:
            return None, False
        if self.loan.due_at <= now or self.loan.renewal_count >= 2:
            return None, False
        self.loan.due_at += timedelta(days=14)
        self.loan.renewal_count += 1
        self.loan.row_version += 1
        if fail_event:
            self.loan = before
            raise RuntimeError("event insert failed")
        self.events[key] = {"previous_due": before.due_at, "new_due": self.loan.due_at}
        return deepcopy(self.loan), False

    def terminal(self, status: str, expected: int, correlation: str, now: datetime, fail_event=False):
        event = f"LOAN_{status}"
        key = (event, correlation)
        if key in self.events:
            return deepcopy(self.loan), True
        before = deepcopy(self.loan)
        if self.loan.status != "ACTIVE" or self.loan.row_version != expected:
            return None, False
        self.loan.status = status
        setattr(self.loan, f"{status.lower()}_at", now)
        self.loan.row_version += 1
        if fail_event:
            self.loan = before
            raise RuntimeError("event insert failed")
        self.events[key] = {"status": status}
        return deepcopy(self.loan), False


def require(value: bool, message: str):
    if not value:
        raise AssertionError(message)
    print(f"ok - {message}")


def simulate():
    now = datetime(2029, 12, 1, tzinfo=timezone.utc)
    lifecycle = Lifecycle(Loan())
    renewed, replay = lifecycle.renew(1, "renew-1", now)
    require(renewed is not None and not replay, "renewal succeeds from ACTIVE")
    require(renewed.due_at == datetime(2030, 1, 15, tzinfo=timezone.utc), "renewal extends existing due_at by 14 days")
    require((renewed.renewal_count, renewed.row_version) == (1, 2), "renewal counters increment exactly once")
    again, replay = lifecycle.renew(1, "renew-1", now)
    require(replay and again == renewed and len(lifecycle.events) == 1, "correlation replay is idempotent")
    require(lifecycle.renew(1, "renew-race", now)[0] is None, "stale concurrent renewal loses")

    for winner, loser in (
        ("RETURNED", "REVOKED"),
        ("RETURNED", "EXPIRED"),
        ("REVOKED", "EXPIRED"),
    ):
        race = Lifecycle(Loan())
        first, _ = race.terminal(winner, 1, f"{winner}-1", now)
        second, _ = race.terminal(loser, 1, f"{loser}-1", now)
        require(first is not None and second is None and race.loan.status == winner, f"{winner}/{loser} race has one terminal winner")
        timestamps = [race.loan.returned_at, race.loan.revoked_at, race.loan.expired_at]
        require(sum(value is not None for value in timestamps) == 1, f"{winner}/{loser} leaves one terminal timestamp")

    past_due = Lifecycle(Loan(due_at=now))
    require(past_due.renew(1, "past", now)[0] is None, "past-due ACTIVE loan cannot renew")
    expired, _ = past_due.terminal("EXPIRED", 1, "expiry", now)
    require(expired is not None, "past-due ACTIVE loan can expire")

    batch = [Lifecycle(Loan(due_at=now - timedelta(days=i))) for i in range(5)]
    changed = 0
    for index, item in enumerate(batch[:3]):
        changed += item.terminal("EXPIRED", 1, f"batch:{index}", now)[0] is not None
    require(changed == 3 and sum(item.loan.status == "ACTIVE" for item in batch) == 2, "expiry batch is bounded and deterministic")
    replay_changed = sum(item.terminal("EXPIRED", 1, f"batch:{index}", now)[1] for index, item in enumerate(batch[:3]))
    require(replay_changed == 3, "repeated expiry batch is idempotent")

    rollback = Lifecycle(Loan())
    original = deepcopy(rollback.loan)
    try:
        rollback.terminal("REVOKED", 1, "rollback", now, fail_event=True)
    except RuntimeError:
        pass
    require(rollback.loan == original and not rollback.events, "event failure rolls back loan mutation")
    require(rollback.loan.progress == 37, "lifecycle changes preserve reading progress")

    service = (BUNDLE / "Service/LoanLifecycleService.pm").read_text(encoding="utf-8")
    repository = (BUNDLE / "Repository/LoanRepository.pm").read_text(encoding="utf-8")
    events = (BUNDLE / "Repository/EventRepository.pm").read_text(encoding="utf-8")
    openapi = (BUNDLE / "openapi.json").read_text(encoding="utf-8")
    all_new = service + repository + events
    require("FOR UPDATE" in repository and "GET_LOCK(?, 0)" in service, "source locks rows and expiry sweep")
    require("due_at = DATE_ADD(due_at" in repository and "UTC_TIMESTAMP()" in repository, "source uses existing due_at and database UTC")
    require(all(event in events for event in ("LOAN_RENEWED", "LOAN_REVOKED", "LOAN_EXPIRED")), "source declares all lifecycle events")
    require(all(route in openapi for route in ('"/loans/{loan_id}/renew"', '"/loans/{loan_id}/revoke"', '"/maintenance/expire-loans"')), "OpenAPI declares all lifecycle routes")
    require(not any(token in all_new for token in ("AddIssue", "AddReturn", "INSERT INTO issues", "UPDATE issues")), "lifecycle source has no native circulation mutation")


if __name__ == "__main__":
    simulate()
    print("Phase 5 lifecycle simulation passed")
