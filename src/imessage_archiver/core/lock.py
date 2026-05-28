"""Process-level lockfile to prevent concurrent archive runs."""

from __future__ import annotations

import os
from pathlib import Path


class LockError(Exception):
    """Raised when the lock is held by another live process."""


class ArchiveLock:
    """Advisory PID lockfile.

    Creates *path* containing the current PID.  On acquisition, if a stale
    lock exists (process no longer running) it is silently removed first.
    """

    def __init__(self, path: Path) -> None:
        self._path = path
        self._locked = False

    def acquire(self) -> None:
        """Acquire the lock or raise :exc:`LockError`."""
        if self._path.exists():
            try:
                existing_pid = int(self._path.read_text().strip())
            except (ValueError, OSError):
                existing_pid = None

            if existing_pid is not None and _pid_running(existing_pid):
                raise LockError(
                    f"Archive run already in progress (PID {existing_pid}). "
                    "If this is wrong, delete the lockfile: "
                    f"{self._path}"
                )
            # Stale lock — remove it
            self._path.unlink(missing_ok=True)

        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(str(os.getpid()))
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


def _pid_running(pid: int) -> bool:
    """Return True if *pid* is a running process on this machine."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Process exists but we can't signal it — treat as running
        return True
