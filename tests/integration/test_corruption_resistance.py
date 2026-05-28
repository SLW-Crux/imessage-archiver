"""Layer 6: Corruption resistance and atomicity.

Per CLAUDE.md and TEST_PLAN.md the archiver must survive:
- Two concurrent runs (the lock blocks the second)
- A killed mid-run (orphan .tmp files, truncated tar, half-written manifest)
- A future schema version (refuse to open with a clear error)
"""

from __future__ import annotations

import multiprocessing as mp
import sqlite3
import sys
import time
from pathlib import Path

import pytest

from imessage_archiver.core.archive import (
    MAX_SUPPORTED_SCHEMA_VERSION,
    ArchiveWriter,
    SchemaVersionError,
)
from imessage_archiver.core.lock import ArchiveLock, LockError
from imessage_archiver.core.verify import verify_bundle
from imessage_archiver.db.reader import Reader

FIXTURES = Path(__file__).parent.parent / "fixtures"


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found — run tests/fixtures/generate.py")
    return p


# ----------------------------------------------------------------------
# Concurrent-writer test (C2 from review)
# ----------------------------------------------------------------------


class TestConcurrentWriters:
    def test_second_acquire_raises_lockerror(self, tmp_path: Path) -> None:
        lock_path = tmp_path / "archive.lock"
        with ArchiveLock(lock_path):
            with pytest.raises(LockError):
                ArchiveLock(lock_path).acquire()

    def test_stale_pid_lock_is_reclaimed(self, tmp_path: Path) -> None:
        """A lock left by a dead process should be silently reclaimed."""
        lock_path = tmp_path / "archive.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        # Write a PID that almost certainly doesn't exist.
        lock_path.write_text("999999")
        lock = ArchiveLock(lock_path)
        lock.acquire()  # Should not raise
        assert lock_path.exists()
        lock.release()

    def test_o_excl_atomic_create_prevents_double_acquire(self, tmp_path: Path) -> None:
        """Two threads racing for an empty lock — exactly one wins."""
        import threading

        lock_path = tmp_path / "archive.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)

        winners = []
        losers = []
        barrier = threading.Barrier(8)

        def attempt() -> None:
            barrier.wait()
            try:
                lock = ArchiveLock(lock_path)
                lock.acquire()
                winners.append(lock)
            except LockError:
                losers.append(True)

        threads = [threading.Thread(target=attempt) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert len(winners) == 1, f"Expected exactly 1 winner, got {len(winners)}"
        assert len(losers) == 7
        winners[0].release()


# ----------------------------------------------------------------------
# Schema-version refusal (C1 / CR-3 from review)
# ----------------------------------------------------------------------


class TestSchemaVersionRefusal:
    def test_writer_refuses_to_open_future_schema(self, tmp_path: Path) -> None:
        """A bundle whose schema_migrations.max > MAX_SUPPORTED must error."""
        # First build a real v1 bundle...
        bundle = tmp_path / "future.imarchive"
        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)

        # ...then bump its schema_migrations row to v99 (simulating a future
        # archiver having written here previously).
        sqlite_path = bundle / "archive.sqlite"
        conn = sqlite3.connect(str(sqlite_path))
        conn.execute(
            "INSERT OR REPLACE INTO schema_migrations VALUES (?, ?)",
            (99, int(time.time())),
        )
        conn.commit()
        conn.close()

        writer = ArchiveWriter(bundle)
        with pytest.raises(SchemaVersionError) as exc_info:
            writer._open_db()
        assert "99" in str(exc_info.value)
        assert str(MAX_SUPPORTED_SCHEMA_VERSION) in str(exc_info.value)

    def test_writer_accepts_current_schema(self, tmp_path: Path) -> None:
        """A bundle at our current schema version opens normally."""
        bundle = tmp_path / "current.imarchive"
        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)
        # Re-open should succeed (the version is now == MAX_SUPPORTED).
        with ArchiveWriter(bundle) as w:
            w._open_db()


# ----------------------------------------------------------------------
# Truncated / corrupt tar (CR-4 / C3 from review)
# ----------------------------------------------------------------------


class TestTruncatedTar:
    def test_truncated_tar_fails_verify_cleanly(self, tmp_path: Path) -> None:
        """A truncated attachments.tar must be reported via the verify
        failures list — not crash with struct.unpack or a generic exception."""
        bundle = tmp_path / "trunc.imarchive"
        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)

        tar = bundle / "attachments.tar"
        original = tar.read_bytes()
        if len(original) < 1024:
            pytest.skip("tiny fixture has no attachments to truncate")
        # Truncate aggressively to a few hundred bytes — definitely below
        # the first attachment's data offset.
        tar.write_bytes(original[:300])

        result = verify_bundle(bundle, log_path=tmp_path / "v.log")
        assert not result.ok
        assert len(result.failures) > 0, "verify must report which attachments failed"

    def test_extra_bytes_at_end_of_tar_does_not_crash_verify(self, tmp_path: Path) -> None:
        """Extra junk bytes appended after the tar must not crash verify."""
        bundle = tmp_path / "extra.imarchive"
        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)

        tar = bundle / "attachments.tar"
        with tar.open("ab") as f:
            f.write(b"\x00" * 4096 + b"GARBAGE" + b"\x00" * 100)

        # The known offsets/lengths still point at the original bytes, so
        # verify should pass (nothing was changed in the indexed region).
        result = verify_bundle(bundle, log_path=tmp_path / "v.log")
        assert result.ok


# ----------------------------------------------------------------------
# Manifest atomicity (CR-4 from review)
# ----------------------------------------------------------------------


class TestManifestAtomicity:
    def test_manifest_tmp_file_not_left_behind(self, tmp_path: Path) -> None:
        """After a successful archive, no .tmp file should remain."""
        bundle = tmp_path / "atomic.imarchive"
        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)

        assert (bundle / "manifest.json").exists()
        assert not (bundle / "manifest.json.tmp").exists()


# ----------------------------------------------------------------------
# Subprocess concurrent archive (integration with the actual CLI lock path)
# ----------------------------------------------------------------------


def _hold_lock(lock_path_str: str, ready: mp.Event, done: mp.Event) -> None:
    """Worker: acquire a lock, signal ready, wait for done signal."""
    lock = ArchiveLock(Path(lock_path_str))
    lock.acquire()
    ready.set()
    done.wait(timeout=10)
    lock.release()


class TestSubprocessConcurrentArchive:
    def test_second_process_blocked_by_first(self, tmp_path: Path) -> None:
        """A real second process must hit LockError, not race silently."""
        if sys.platform == "win32":
            pytest.skip("POSIX-only")
        ctx = mp.get_context("spawn")
        ready = ctx.Event()
        done = ctx.Event()
        lock_path = tmp_path / "archive.lock"

        # Worker process holds the lock.
        p = ctx.Process(target=_hold_lock, args=(str(lock_path), ready, done))
        p.start()
        try:
            assert ready.wait(timeout=10), "worker failed to acquire lock"
            # We are a different process; we should hit LockError.
            with pytest.raises(LockError):
                ArchiveLock(lock_path).acquire()
        finally:
            done.set()
            p.join(timeout=10)
            if p.is_alive():
                p.terminate()


# ----------------------------------------------------------------------
# Snapshot symlink-attack defence (Sec-M2 from review)
# ----------------------------------------------------------------------


class TestSnapshotSymlinkDefence:
    def test_work_root_created_with_0o700(self, tmp_path: Path) -> None:
        from imessage_archiver.db.snapshot import snapshot

        work_root = tmp_path / "work"
        # Pre-create with a permissive mode; snapshot() should chmod it down.
        work_root.mkdir(mode=0o755)
        snapshot(source=_fixture("tiny.db"), work_root=work_root)

        # Snapshot succeeded; verify the work_root is now 0o700.
        mode = work_root.stat().st_mode & 0o777
        assert mode == 0o700, f"work_root mode = {oct(mode)}, expected 0o700"

    def test_snapshot_rejects_unsafe_path_chars(self, tmp_path: Path) -> None:
        """A work_root containing a single quote should be refused."""
        from imessage_archiver.db.snapshot import snapshot

        bad = tmp_path / "with'quote"
        with pytest.raises(ValueError):
            snapshot(source=_fixture("tiny.db"), work_root=bad)
