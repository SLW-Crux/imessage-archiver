"""Archive integrity verification.

Reads every LOCAL_PRESENT attachment row, seeks to tar_offset in
attachments.tar, reads tar_length bytes, recomputes SHA-256, and
compares with the stored value.
"""

from __future__ import annotations

import hashlib
import sqlite3
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class VerifyResult:
    ok: bool = True
    checked: int = 0
    failures: list[str] = field(default_factory=list)
    duration_s: float = 0.0


def verify_bundle(bundle_path: Path, log_path: Path | None = None) -> VerifyResult:
    """Verify every archived attachment in *bundle_path*.

    Writes a human-readable log to *log_path* (default:
    ``~/.imessage-archiver/logs/verify-{ts}.log``).

    Returns a :class:`VerifyResult` with ``ok=True`` iff all hashes match.
    """
    sqlite_path = bundle_path / "archive.sqlite"
    tar_path = bundle_path / "attachments.tar"

    if not sqlite_path.exists():
        raise FileNotFoundError(f"archive.sqlite not found in {bundle_path}")
    if not tar_path.exists():
        raise FileNotFoundError(f"attachments.tar not found in {bundle_path}")

    if log_path is None:
        log_dir = Path.home() / ".imessage-archiver" / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_path = log_dir / f"verify-{int(time.time())}.log"

    result = VerifyResult()
    t0 = time.monotonic()

    conn = sqlite3.connect(f"file:{sqlite_path}?mode=ro&immutable=1", uri=True)
    rows = conn.execute(
        """SELECT attachment_guid, sha256, tar_offset, tar_length
           FROM attachments
           WHERE state='LOCAL_PRESENT'
             AND tar_offset IS NOT NULL
             AND tar_length IS NOT NULL
             AND sha256 IS NOT NULL"""
    ).fetchall()
    conn.close()

    lines: list[str] = [
        f"verify started {_iso_now()}",
        f"bundle: {bundle_path}",
        f"attachments to check: {len(rows)}",
        "",
    ]

    with tar_path.open("rb") as fh:
        for guid, stored_sha, tar_offset, tar_length in rows:
            result.checked += 1
            fh.seek(tar_offset)
            data = fh.read(tar_length)
            actual_sha = hashlib.sha256(data).hexdigest()
            if actual_sha == stored_sha:
                lines.append(f"OK  {guid}")
            else:
                msg = f"FAIL {guid}: expected {stored_sha} got {actual_sha}"
                lines.append(msg)
                result.failures.append(msg)
                result.ok = False

    result.duration_s = time.monotonic() - t0
    lines += [
        "",
        f"checked: {result.checked}",
        f"failures: {len(result.failures)}",
        f"duration: {result.duration_s:.1f}s",
        f"result: {'PASS' if result.ok else 'FAIL'}",
    ]
    log_path.write_text("\n".join(lines))
    return result


def _iso_now() -> str:
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
