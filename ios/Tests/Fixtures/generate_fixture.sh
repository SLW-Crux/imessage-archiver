#!/usr/bin/env bash
# Produce a tiny.imarchive bundle from the Python tiny.db fixture and place
# it in ios/Tests/Fixtures/ so iOS XCTest can resolve it via Bundle.url(...).
#
# Run from the repo root:
#   ./ios/Tests/Fixtures/generate_fixture.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT_DIR="$REPO_ROOT/ios/Tests/Fixtures"
PY_FIXTURE="$REPO_ROOT/tests/fixtures/tiny.db"
BUNDLE="$OUT_DIR/tiny.imarchive"

if [ ! -f "$PY_FIXTURE" ]; then
    echo "ERROR: tiny.db not found at $PY_FIXTURE" >&2
    echo "Run 'python tests/fixtures/generate.py' from the repo root first." >&2
    exit 1
fi

if [ -f "$REPO_ROOT/.venv/bin/activate" ]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.venv/bin/activate"
fi

rm -rf "$BUNDLE"
echo "==> Generating $BUNDLE from $PY_FIXTURE"
imessage-archiver archive --source "$PY_FIXTURE" --dest "$BUNDLE"

# Convert archive.sqlite from WAL to DELETE journal mode.
# The Python archiver writes WAL by default. WAL-mode databases require
# SQLite to manage -wal/-shm companion files at open time, and GRDB on
# iOS simulator can't satisfy that (the test runner's sandbox refuses
# the journal-file creation, yielding SQLITE_CANTOPEN even on a clean
# tmp-dir copy). DELETE mode is the portable rollback-journal default
# that opens cleanly in any process.
#
# VACUUM rewrites the file with the new journal_mode baked in. The
# Mac app reads either mode fine — production archives can stay in
# WAL — this conversion only applies to the test fixture.
echo "==> Converting archive.sqlite WAL → DELETE (so iOS XCTest can open it)"
sqlite3 "$BUNDLE/archive.sqlite" "PRAGMA journal_mode=DELETE; VACUUM;" > /dev/null

echo ""
echo "==> Fixture ready:"
ls -lh "$BUNDLE"
