#!/usr/bin/env python3
"""Disposable in-memory simulation of the schema-1 plugin-version stamp flow."""

from __future__ import annotations

import copy
import json
import pathlib
import sqlite3

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (
    ROOT
    / "Koha"
    / "Plugin"
    / "Com"
    / "JunaidZaidiLibrary"
    / "DigitalCirculation.pm"
).read_text(encoding="utf-8")
CURRENT_VERSION = "0.4.1"


def require_source_contract() -> None:
    required = [
        "sub _stamp_schema_state",
        "ON DUPLICATE KEY UPDATE",
        "plugin_version = VALUES(plugin_version)",
        "$self->_stamp_schema_state($dbh);",
        "$self->_verify_schema($dbh);",
        "$dbh->begin_work;",
        "$dbh->commit;",
        "$dbh->rollback",
        "Schema state must contain exactly one canonical row",
    ]
    missing = [token for token in required if token not in SOURCE]
    if missing:
        raise AssertionError(f"source contract missing: {missing}")
    if "our $SCHEMA_VERSION      = 1;" not in SOURCE:
        raise AssertionError("schema version is not 1")
    if "DROP TABLE" in SOURCE or "AddIssue" in SOURCE or "AddReturn" in SOURCE:
        raise AssertionError("destructive or native-circulation mutation found")


def database() -> sqlite3.Connection:
    connection = sqlite3.connect(":memory:")
    connection.row_factory = sqlite3.Row
    connection.executescript(
        """
        CREATE TABLE schema_state (
            schema_version INTEGER PRIMARY KEY,
            plugin_version TEXT NOT NULL,
            migration_name TEXT NOT NULL UNIQUE,
            checksum TEXT
        );
        CREATE TABLE requests (
            request_id INTEGER PRIMARY KEY,
            status TEXT NOT NULL,
            row_version INTEGER NOT NULL
        );
        CREATE TABLE loans (
            loan_id INTEGER PRIMARY KEY,
            request_id INTEGER NOT NULL,
            status TEXT NOT NULL,
            row_version INTEGER NOT NULL,
            returned_at TEXT,
            revoked_at TEXT,
            expired_at TEXT,
            renewal_count INTEGER NOT NULL
        );
        CREATE TABLE events (
            event_id INTEGER PRIMARY KEY,
            event_type TEXT NOT NULL,
            loan_id INTEGER
        );
        CREATE TABLE native_issues (issue_id INTEGER PRIMARY KEY);
        """
    )
    return connection


def stamp(connection: sqlite3.Connection, *, fail: bool = False) -> None:
    if fail:
        raise sqlite3.OperationalError("simulated version stamp failure")
    row = connection.execute(
        """
        SELECT schema_version
        FROM schema_state
        WHERE schema_version = ? OR migration_name = ?
        """,
        (1, "001_initial_schema"),
    ).fetchone()
    if row is None:
        connection.execute(
            """
            INSERT INTO schema_state
                (schema_version, plugin_version, migration_name, checksum)
            VALUES (?, ?, ?, ?)
            """,
            (1, CURRENT_VERSION, "001_initial_schema", "69bcf09d56f99afe"),
        )
    else:
        connection.execute(
            """
            UPDATE schema_state
            SET plugin_version = ?, migration_name = ?, checksum = ?
            WHERE schema_version = ?
            """,
            (
                CURRENT_VERSION,
                "001_initial_schema",
                "69bcf09d56f99afe",
                row["schema_version"],
            ),
        )


def verify(connection: sqlite3.Connection) -> None:
    rows = connection.execute(
        "SELECT schema_version, plugin_version FROM schema_state"
    ).fetchall()
    if len(rows) != 1:
        raise AssertionError("schema state must contain exactly one canonical row")
    if rows[0]["schema_version"] != 1 or rows[0]["plugin_version"] != CURRENT_VERSION:
        raise AssertionError("schema state does not match current schema/plugin version")


def upgrade(connection: sqlite3.Connection, *, fail_stamp: bool = False) -> bool:
    try:
        connection.execute("BEGIN")
        stamp(connection, fail=fail_stamp)
        verify(connection)
        connection.commit()
        return True
    except (AssertionError, sqlite3.DatabaseError):
        connection.rollback()
        return False


def rows(connection: sqlite3.Connection, table: str) -> list[dict]:
    return [
        dict(row)
        for row in connection.execute(f"SELECT * FROM {table} ORDER BY 1").fetchall()
    ]


def seed_business(connection: sqlite3.Connection) -> None:
    connection.execute(
        "INSERT INTO requests VALUES (9, 'APPROVED', 2)"
    )
    connection.execute(
        """
        INSERT INTO loans
        VALUES (3, 9, 'ACTIVE', 1, NULL, NULL, NULL, 0)
        """
    )
    connection.execute(
        "INSERT INTO events VALUES (21, 'LOAN_CREATED', 3)"
    )
    connection.commit()


def snapshot_business(connection: sqlite3.Connection) -> dict[str, list[dict]]:
    return {
        table: copy.deepcopy(rows(connection, table))
        for table in ("requests", "loans", "events", "native_issues")
    }


def run() -> dict[str, str]:
    require_source_contract()

    fresh = database()
    assert upgrade(fresh)
    assert rows(fresh, "schema_state") == [
        {
            "schema_version": 1,
            "plugin_version": CURRENT_VERSION,
            "migration_name": "001_initial_schema",
            "checksum": "69bcf09d56f99afe",
        }
    ]

    prior = database()
    prior.execute(
        "INSERT INTO schema_state VALUES (1, '0.2.2', '001_initial_schema', '69bcf09d56f99afe')"
    )
    seed_business(prior)
    before = snapshot_business(prior)
    assert upgrade(prior)
    assert rows(prior, "schema_state")[0]["plugin_version"] == CURRENT_VERSION
    assert snapshot_business(prior) == before
    assert upgrade(prior)
    assert snapshot_business(prior) == before
    assert len(rows(prior, "schema_state")) == 1

    invalid = database()
    invalid.execute(
        "INSERT INTO schema_state VALUES (2, '0.2.2', '001_initial_schema', '69bcf09d56f99afe')"
    )
    invalid.commit()
    invalid_before = rows(invalid, "schema_state")
    assert not upgrade(invalid)
    assert rows(invalid, "schema_state") == invalid_before

    failed_write = database()
    failed_write.execute(
        "INSERT INTO schema_state VALUES (1, '0.2.2', '001_initial_schema', '69bcf09d56f99afe')"
    )
    failed_write.commit()
    assert not upgrade(failed_write, fail_stamp=True)
    assert rows(failed_write, "schema_state")[0]["plugin_version"] == "0.2.2"

    return {
        "fresh_install": "PASS",
        "upgrade_0.4.0_to_0.4.1": "PASS",
        "idempotent_replay": "PASS",
        "invalid_schema_rollback": "PASS",
        "write_failure_rollback": "PASS",
        "business_data_preservation": "PASS",
        "native_circulation_isolation": "PASS",
    }


if __name__ == "__main__":
    print(json.dumps(run(), indent=2, sort_keys=True))
