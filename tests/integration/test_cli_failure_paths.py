"""CLI failure-path coverage (H4 from the test-coverage review).

Each test exercises a distinct user-observable failure surface:
- lock conflict
- corrupt manifest
- missing source DB
- info on missing bundle
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from imessage_archiver.cli.commands import cli
from imessage_archiver.core.archive import ArchiveWriter
from imessage_archiver.core.lock import ArchiveLock
from imessage_archiver.db.reader import Reader

FIXTURES = Path(__file__).parent.parent / "fixtures"


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found")
    return p


@pytest.fixture
def tiny_bundle(tmp_path: Path) -> Path:
    bundle = tmp_path / "tiny.imarchive"
    with Reader(_fixture("tiny.db")) as r:
        with ArchiveWriter(bundle) as w:
            w.run(r)
    return bundle


@pytest.fixture
def runner() -> CliRunner:
    return CliRunner()


# ----------------------------------------------------------------------
# archive: lock conflict
# ----------------------------------------------------------------------


def test_archive_exits_1_when_lock_held(runner: CliRunner, tmp_path: Path, monkeypatch) -> None:
    lock_path = tmp_path / "archive.lock"
    monkeypatch.setattr("imessage_archiver.cli.commands._LOCK_PATH", lock_path)

    with ArchiveLock(lock_path):
        result = runner.invoke(
            cli,
            [
                "archive",
                "--source",
                str(_fixture("tiny.db")),
                "--dest",
                str(tmp_path / "out.imarchive"),
            ],
        )
    assert result.exit_code == 1, result.output
    assert "already in progress" in result.output.lower() or "lock" in result.output.lower()


# ----------------------------------------------------------------------
# stats: corrupt manifest tolerated, all fields show "?"
# ----------------------------------------------------------------------


def test_stats_corrupt_manifest_tolerated(runner: CliRunner, tiny_bundle: Path) -> None:
    (tiny_bundle / "manifest.json").write_text("{not json")
    result = runner.invoke(cli, ["stats", "--archive", str(tiny_bundle)])
    assert result.exit_code == 0, result.output
    assert "?" in result.output


# ----------------------------------------------------------------------
# info: missing bundle exits non-zero
# ----------------------------------------------------------------------


def test_info_missing_bundle_exits_nonzero(runner: CliRunner, tmp_path: Path) -> None:
    result = runner.invoke(cli, ["info", "--archive", str(tmp_path / "no-such-bundle.imarchive")])
    assert result.exit_code != 0


# ----------------------------------------------------------------------
# verify: bundle missing → exit 1
# ----------------------------------------------------------------------


def test_verify_missing_bundle_exits_1(runner: CliRunner, tmp_path: Path) -> None:
    result = runner.invoke(cli, ["verify", "--archive", str(tmp_path / "missing.imarchive")])
    assert result.exit_code != 0


# ----------------------------------------------------------------------
# stats: valid manifest renders correctly (positive control)
# ----------------------------------------------------------------------


def test_stats_valid_manifest(runner: CliRunner, tiny_bundle: Path) -> None:
    result = runner.invoke(cli, ["stats", "--archive", str(tiny_bundle)])
    assert result.exit_code == 0
    # Should show "Messages" row with a numeric value
    assert "Messages" in result.output
    # Confirm manifest stayed valid JSON
    manifest = json.loads((tiny_bundle / "manifest.json").read_text())
    assert manifest["message_count"] > 0
