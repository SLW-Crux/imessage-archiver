"""Tests for GUI worker threads (snapshot, chats, messages, archive).

Uses pytest-qt's qtbot to drive signal/slot communication. The Qt platform
must be offscreen so no display is required.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication  # noqa: E402

from imessage_archiver.gui.workers import (  # noqa: E402
    ArchiveWorker,
    LoadChatsWorker,
    LoadMessagesWorker,
    SnapshotWorker,
)

FIXTURES = Path(__file__).parent.parent / "fixtures"


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication(sys.argv[:1])


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found — run tests/fixtures/generate.py")
    return p


# ----------------------------------------------------------------------
# SnapshotWorker
# ----------------------------------------------------------------------


class TestSnapshotWorker:
    def test_emits_finished_with_path_and_sha(self, app, qtbot, tmp_path: Path) -> None:
        src = _fixture("tiny.db")
        worker = SnapshotWorker(source_db=src)
        with qtbot.waitSignal(worker.finished, timeout=10_000) as blocker:
            worker.start()
        snap_path, sha = blocker.args
        assert isinstance(snap_path, Path)
        assert snap_path.exists()
        assert len(sha) == 64  # SHA-256 hex
        worker.wait(1000)

    def test_emits_error_on_missing_source(self, app, qtbot, tmp_path: Path) -> None:
        worker = SnapshotWorker(source_db=tmp_path / "does-not-exist.db")
        with qtbot.waitSignal(worker.error, timeout=10_000) as blocker:
            worker.start()
        assert "Snapshot failed" in blocker.args[0]
        worker.wait(1000)


# ----------------------------------------------------------------------
# LoadChatsWorker
# ----------------------------------------------------------------------


class TestLoadChatsWorker:
    def test_emits_chat_list(self, app, qtbot) -> None:
        worker = LoadChatsWorker(db_path=_fixture("tiny.db"))
        with qtbot.waitSignal(worker.finished, timeout=10_000) as blocker:
            worker.start()
        chats = blocker.args[0]
        assert isinstance(chats, list)
        assert len(chats) >= 1
        worker.wait(1000)

    def test_emits_error_on_missing_db(self, app, qtbot, tmp_path: Path) -> None:
        worker = LoadChatsWorker(db_path=tmp_path / "nope.db")
        with qtbot.waitSignal(worker.error, timeout=10_000):
            worker.start()
        worker.wait(1000)


# ----------------------------------------------------------------------
# LoadMessagesWorker (last-write-wins semantics)
# ----------------------------------------------------------------------


class TestLoadMessagesWorker:
    def test_emits_chat_guid_and_messages(self, app, qtbot) -> None:
        # Get a real chat_guid via the chats worker first.
        chats_worker = LoadChatsWorker(db_path=_fixture("tiny.db"))
        with qtbot.waitSignal(chats_worker.finished, timeout=10_000) as blocker:
            chats_worker.start()
        chats = blocker.args[0]
        assert chats
        chats_worker.wait(1000)

        target_guid = chats[0].chat_guid
        msg_worker = LoadMessagesWorker(db_path=_fixture("tiny.db"), chat_guid=target_guid)
        with qtbot.waitSignal(msg_worker.finished, timeout=10_000) as blocker:
            msg_worker.start()
        emitted_guid, msgs = blocker.args
        assert emitted_guid == target_guid
        assert isinstance(msgs, list)
        msg_worker.wait(1000)


# ----------------------------------------------------------------------
# ArchiveWorker (full path)
# ----------------------------------------------------------------------


class TestArchiveWorker:
    @pytest.mark.timeout(30)
    def test_archive_worker_emits_finished(self, app, qtbot, tmp_path: Path) -> None:
        bundle = tmp_path / "out.imarchive"
        # Use a tmp lock path so we don't collide with the user's real lock.
        worker = ArchiveWorker(source_db=_fixture("tiny.db"), bundle_path=bundle)
        worker._LOCK = tmp_path / "archive.lock"  # override class attr per-instance
        with qtbot.waitSignal(worker.finished, timeout=30_000) as blocker:
            worker.start()
        stats = blocker.args[0]
        assert stats.messages_seen > 0
        assert (bundle / "archive.sqlite").exists()
        assert (bundle / "manifest.json").exists()
        worker.wait(1000)

    @pytest.mark.timeout(30)
    def test_archive_worker_emits_error_on_missing_source(self, app, qtbot, tmp_path: Path) -> None:
        worker = ArchiveWorker(
            source_db=tmp_path / "does-not-exist.db",
            bundle_path=tmp_path / "out.imarchive",
        )
        worker._LOCK = tmp_path / "archive.lock"
        with qtbot.waitSignal(worker.error, timeout=10_000) as blocker:
            worker.start()
        assert "failed" in blocker.args[0].lower() or "cannot" in blocker.args[0].lower()
        worker.wait(1000)
