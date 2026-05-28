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

echo ""
echo "==> Fixture ready:"
ls -lh "$BUNDLE"
