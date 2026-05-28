"""Process-level lockfile to prevent concurrent archive runs.

Uses ``open(O_CREAT | O_EXCL | O_WRONLY)`` for race-free creation. The PID
detection-then-claim sequence in the previous version had a TOCTOU window
that allowed two concurrent acquirers to both pass the liveness check and
both overwrite each other's lock. ``O_EXCL`` closes that window.
"""

from __future__ import annotations

import errno
import os
from pathlib import Path


class LockError(Exception):
    """Raised when the lock is held by another live process."""


class ArchiveLock:
    """Advisory PID lockfile.

    Atomic acquire pattern:

    1. ``open(O_CREAT | O_EXCL | O_WRONLY, mode=0o600)`` — succeeds only if
       the lockfile does not exist. Race-free under POSIX.
    2. If it fails with ``EEXIST``: read the PID, check liveness, and on a
       stale lock ``unlink`` + retry once.
    3. After successful create: write our PID, fsync, close.
    """

    def __init__(self, path: Path) -> None:
        self._path = path
        self._locked = False

    def acquire(self) -> None:
        """Acquire the lock or raise :exc:`LockError`."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        if not self._try_create():
            # Lock exists. Inspect its contents.
            try:
                raw = self._path.read_text()
            except OSError:
                raw = ""
            stripped = raw.strip()

            if stripped == "":
                # Empty file: another acquirer is in the tiny window between
                # O_EXCL create and PID write. They win.
                raise LockError(f"Lock race lost — another process is claiming the lock: {self._path}")

            try:
                existing_pid = int(stripped)
            except ValueError:
                # Non-empty but unparseable: a prior process crashed before
                # writing a clean PID. Treat as stale.
                existing_pid = None

            if existing_pid is not None and _pid_running(existing_pid):
                raise LockError(
                    f"Archive run already in progress (PID {existing_pid}). "
                    f"If this is wrong, delete the lockfile: {self._path}"
                )

            # Stale lock from a dead PID or unparseable content. Unlink and
            # try once more — if THAT also fails, the new acquirer wins.
            self._path.unlink(missing_ok=True)
            if not self._try_create():
                raise LockError(f"Lock race lost — another process claimed the lock first: {self._path}")

        self._locked = True

    def release(self) -> None:
        """Release the lock (idempotent)."""
        if self._locked:
            self._path.unlink(missing_ok=True)
            self._locked = False

    def __enter__(self) -> ArchiveLock:
        self.acquire()
        return self

    def __exit__(self, *_: object) -> None:
        self.release()

    # ------------------------------------------------------------------

    def _try_create(self) -> bool:
        """Atomically create the lockfile with our PID. Return success."""
        try:
            fd = os.open(
                str(self._path),
                os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                0o600,
            )
        except OSError as e:
            if e.errno == errno.EEXIST:
                return False
            raise

        try:
            os.write(fd, str(os.getpid()).encode("ascii"))
            os.fsync(fd)
        finally:
            os.close(fd)
        return True


def _pid_running(pid: int) -> bool:
    """Return True if *pid* is a running process on this machine."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Process exists but we can't signal it — treat as running.
        return True
