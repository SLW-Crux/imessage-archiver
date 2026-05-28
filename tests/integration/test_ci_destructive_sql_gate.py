"""CI guard self-test: the destructive-SQL grep must:

1. Find no destructive writes targeting chat.db in the current src/ tree
   (positive control — the gate must pass on the real repo).
2. Catch obvious destructive patterns when seeded into a temp file
   (negative control — the gate must fail on a regression).

Without this test, a refactor that loosens the regex would silently
weaken the most important non-destructive guarantee.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent
SRC_DIR = REPO_ROOT / "src"

# Pattern copied from .github/workflows/ci.yml. Keep in sync.
_GREP_PATTERN = (
    r"(INSERT|UPDATE|DELETE|DROP|ALTER|REPLACE|TRUNCATE|VACUUM)"
    r"[[:space:]]+(INTO[[:space:]]+|FROM[[:space:]]+|TABLE[[:space:]]+)?"
    r"['\"]?chat\.(db|sqlite)"
)


def _grep(pattern: str, directory: Path) -> int:
    """Run BSD/GNU grep -rEi; return exit code (0 = match, 1 = no match)."""
    proc = subprocess.run(
        ["grep", "-rEi", pattern, str(directory)],
        capture_output=True,
        text=True,
    )
    return proc.returncode


def test_gate_passes_on_current_src() -> None:
    """The current src/ tree must NOT contain any destructive SQL targeting
    chat.db. If this fails, a regression has been introduced.
    """
    exit_code = _grep(_GREP_PATTERN, SRC_DIR)
    assert exit_code != 0, "Destructive SQL targeting chat.db found in src/ — this is a P0 bug"


def test_gate_catches_obvious_regression(tmp_path: Path) -> None:
    """Seeding a known-bad SQL pattern into a temp file must trigger the gate."""
    bad = tmp_path / "bad.py"
    bad.write_text('conn.execute("DELETE FROM chat.db WHERE id = ?", (123,))\n')
    exit_code = _grep(_GREP_PATTERN, tmp_path)
    assert exit_code == 0, "Destructive-SQL grep failed to catch a known-bad pattern"


def test_gate_catches_update_pattern(tmp_path: Path) -> None:
    bad = tmp_path / "bad.py"
    bad.write_text('conn.execute("UPDATE chat.db SET text=?", ("x",))\n')
    exit_code = _grep(_GREP_PATTERN, tmp_path)
    assert exit_code == 0


def test_gate_does_not_match_archive_sqlite_reads(tmp_path: Path) -> None:
    """Reading FROM archive.sqlite (our own bundle file) must not trigger.
    The gate is specifically about chat.db (the source)."""
    good = tmp_path / "good.py"
    good.write_text('conn.execute("SELECT * FROM archive.sqlite")\n')
    exit_code = _grep(_GREP_PATTERN, tmp_path)
    # exit_code 1 = no match
    assert exit_code == 1
