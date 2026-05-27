"""Unit tests for core/lock.py."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from imessage_archiver.core.lock import ArchiveLock, LockError, _pid_running


class TestPidRunning:
    def test_current_pid_running(self) -> None:
        assert _pid_running(os.getpid()) is True

    def test_dead_pid_not_running(self) -> None:
        # PID 99999999 almost certainly doesn't exist
        assert _pid_running(99999999) is False


class TestArchiveLock:
    def test_acquire_creates_lockfile(self, tmp_path: Path) -> None:
        lock_path = tmp_path / "archive.lock"
        lock = ArchiveLock(lock_path)
        lock.acquire()
        try:
            assert lock_path.exists()
            assert int(lock_path.read_text().strip()) == os.getpid()
        finally:
            lock.release()

    def test_release_removes_lockfile(self, tmp_path: Path) -> None:
        lock = ArchiveLock(tmp_path / "archive.lock")
        lock.acquire()
        lock.release()
        assert not (tmp_path / "archive.lock").exists()

    def test_double_release_is_idempotent(self, tmp_path: Path) -> None:
        lock = ArchiveLock(tmp_path / "archive.lock")
        lock.acquire()
        lock.release()
        lock.release()  # should not raise

    def test_context_manager(self, tmp_path: Path) -> None:
        lock_path = tmp_path / "archive.lock"
        with ArchiveLock(lock_path):
            assert lock_path.exists()
        assert not lock_path.exists()

    def test_stale_lock_removed(self, tmp_path: Path) -> None:
        lock_path = tmp_path / "archive.lock"
        lock_path.write_text("99999999")  # dead PID
        lock = ArchiveLock(lock_path)
        lock.acquire()
        try:
            assert int(lock_path.read_text().strip()) == os.getpid()
        finally:
            lock.release()

    def test_live_lock_raises(self, tmp_path: Path) -> None:
        lock_path = tmp_path / "archive.lock"
        lock_path.write_text(str(os.getpid()))  # our own PID = definitely running
        with pytest.raises(LockError):
            ArchiveLock(lock_path).acquire()

    def test_corrupt_lock_overwritten(self, tmp_path: Path) -> None:
        lock_path = tmp_path / "archive.lock"
        lock_path.write_text("not-a-pid")
        lock = ArchiveLock(lock_path)
        lock.acquire()
        try:
            assert lock_path.read_text().strip().isdigit()
        finally:
            lock.release()

    def test_creates_parent_dirs(self, tmp_path: Path) -> None:
        lock_path = tmp_path / "deep" / "nested" / "archive.lock"
        with ArchiveLock(lock_path):
            assert lock_path.exists()
