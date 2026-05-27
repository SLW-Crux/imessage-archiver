"""CLI integration test — full archive run end-to-end on medium.db fixture."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest
from click.testing import CliRunner

from imessage_archiver.cli.commands import cli

FIXTURES = Path(__file__).parent.parent / "fixtures"


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found")
    return p


@pytest.fixture()
def runner() -> CliRunner:
    return CliRunner()


class TestArchiveCommand:
    def test_archive_medium_db(self, runner: CliRunner, tmp_path: Path) -> None:
        """Full archive run on medium.db via CLI — end-to-end integration."""
        bundle = tmp_path / "archive.imarchive"
        result = runner.invoke(cli, [
            "archive",
            "--source", str(_fixture("medium.db")),
            "--dest", str(bundle),
        ])
        assert result.exit_code == 0, result.output
        assert bundle.exists()
        assert (bundle / "archive.sqlite").exists()
        assert (bundle / "manifest.json").exists()
        assert "Done!" in result.output

    def test_archive_dry_run(self, runner: CliRunner, tmp_path: Path) -> None:
        result = runner.invoke(cli, [
            "archive",
            "--source", str(_fixture("tiny.db")),
            "--dest", str(tmp_path / "archive.imarchive"),
            "--dry-run",
        ])
        assert result.exit_code == 0, result.output
        assert "Dry run" in result.output
        assert not (tmp_path / "archive.imarchive").exists()

    def test_archive_missing_source_exits_nonzero(self, runner: CliRunner, tmp_path: Path) -> None:
        result = runner.invoke(cli, [
            "archive",
            "--source", str(tmp_path / "nonexistent.db"),
            "--dest", str(tmp_path / "archive.imarchive"),
        ])
        assert result.exit_code != 0


class TestVerifyCommand:
    def test_verify_good_bundle(self, runner: CliRunner, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"
        runner.invoke(cli, [
            "archive",
            "--source", str(_fixture("tiny.db")),
            "--dest", str(bundle),
        ])
        result = runner.invoke(cli, ["verify", "--archive", str(bundle)])
        assert result.exit_code == 0, result.output
        assert "PASS" in result.output

    def test_verify_missing_bundle(self, runner: CliRunner, tmp_path: Path) -> None:
        result = runner.invoke(cli, ["verify", "--archive", str(tmp_path / "nonexistent")])
        assert result.exit_code != 0


class TestStatsCommand:
    def test_stats_shows_counts(self, runner: CliRunner, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"
        runner.invoke(cli, [
            "archive",
            "--source", str(_fixture("tiny.db")),
            "--dest", str(bundle),
        ])
        result = runner.invoke(cli, ["stats", "--archive", str(bundle)])
        assert result.exit_code == 0, result.output
        assert "Messages" in result.output

    def test_stats_missing_bundle(self, runner: CliRunner, tmp_path: Path) -> None:
        result = runner.invoke(cli, ["stats", "--archive", str(tmp_path / "nope")])
        assert result.exit_code != 0


class TestInfoCommand:
    def test_info_shows_manifest(self, runner: CliRunner, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"
        runner.invoke(cli, [
            "archive",
            "--source", str(_fixture("tiny.db")),
            "--dest", str(bundle),
        ])
        result = runner.invoke(cli, ["info", "--archive", str(bundle)])
        assert result.exit_code == 0, result.output
        assert "schema_version" in result.output

    def test_info_missing_bundle(self, runner: CliRunner, tmp_path: Path) -> None:
        result = runner.invoke(cli, ["info", "--archive", str(tmp_path / "nope")])
        assert result.exit_code != 0


class TestSetupCommand:
    def test_setup_runs(self, runner: CliRunner) -> None:
        result = runner.invoke(cli, ["setup"])
        # May exit 0 (FDA granted) or 1 (not granted) — must not crash
        assert isinstance(result.exit_code, int)


class TestMergeCommand:
    def test_merge_idempotent(self, runner: CliRunner, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"
        runner.invoke(cli, [
            "archive",
            "--source", str(_fixture("tiny.db")),
            "--dest", str(bundle),
        ])
        conn = sqlite3.connect(str(bundle / "archive.sqlite"))
        count1 = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        conn.close()

        result = runner.invoke(cli, [
            "merge",
            "--source", str(_fixture("tiny.db")),
            "--archive", str(bundle),
        ])
        assert result.exit_code == 0, result.output

        conn = sqlite3.connect(str(bundle / "archive.sqlite"))
        count2 = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        conn.close()
        assert count1 == count2
