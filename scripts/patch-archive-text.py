"""One-off archive REPAIR: patch missing message text from a source bundle.

When you have:
  - A 'fat' archive bundle (lots of attachments archived) with bad text
    (because the typedstream parser pre-PR #31 missed ~75% of text).
  - A fresh archive bundle (correct text, but maybe smaller attachment
    set because of iCloud eviction between runs).

You can keep the fat attachments tar + sqlite while overlaying the
correct text column from the fresh archive. This script does exactly
that, safely.

Safety properties:
  - Read-only access to --source (the fresh bundle).
  - Only writes UPDATE messages SET text=... on rows where the target's
    text is currently NULL or empty AND the source has real text.
  - No DELETE, no DROP, no schema changes, no attachment touch.
  - Snapshots the target sqlite to <target>.sqlite.bak before any write
    so the operation is reversible.
  - Rebuilds messages_fts after the patch so FTS5 search reflects the
    new text content.

Usage:
  python scripts/patch-archive-text.py --target OLD.imarchive --source NEW.imarchive

This violates the project's "append-only / never UPDATE user data" rule
on purpose — it's a one-time repair tool, not part of the production
archive pipeline. Do not call it from the CLI.
"""

from __future__ import annotations

import argparse
import shutil
import sqlite3
import sys
from pathlib import Path


def patch(target_bundle: Path, source_bundle: Path) -> int:
    target_db = target_bundle / "archive.sqlite"
    source_db = source_bundle / "archive.sqlite"

    if not target_db.exists():
        print(f"ERROR: target sqlite not found: {target_db}", file=sys.stderr)
        return 1
    if not source_db.exists():
        print(f"ERROR: source sqlite not found: {source_db}", file=sys.stderr)
        return 1

    backup = target_db.with_suffix(".sqlite.bak")
    if backup.exists():
        print(f"NOTE: existing backup at {backup} will be overwritten.")
    print(f"Backing up target sqlite → {backup}")
    shutil.copy2(target_db, backup)

    # Counts before
    print("\nBEFORE:")
    with sqlite3.connect(str(target_db)) as t_pre:
        before_with = t_pre.execute(
            "SELECT COUNT(*) FROM messages WHERE text IS NOT NULL AND text != ''"
        ).fetchone()[0]
        before_without = t_pre.execute(
            "SELECT COUNT(*) FROM messages WHERE text IS NULL OR text = ''"
        ).fetchone()[0]
        print(f"  with text:    {before_with:>8,}")
        print(f"  without text: {before_without:>8,}")

    # Patch
    conn = sqlite3.connect(str(target_db))
    try:
        conn.execute(f"ATTACH DATABASE '{source_db}' AS src;")

        # 1. UPDATE rows in target where target.text is empty and source has text.
        cur = conn.execute("""
            UPDATE messages AS t
            SET text = (
                SELECT s.text FROM src.messages AS s
                WHERE s.message_guid = t.message_guid
                  AND s.text IS NOT NULL AND s.text != ''
            )
            WHERE (t.text IS NULL OR t.text = '')
              AND EXISTS (
                SELECT 1 FROM src.messages AS s
                WHERE s.message_guid = t.message_guid
                  AND s.text IS NOT NULL AND s.text != ''
              );
        """)
        rows_patched = cur.rowcount
        conn.commit()

        # 2. Rebuild messages_fts so FTS5 search reflects the new text.
        print("\nRebuilding FTS5 index…")
        conn.execute("INSERT INTO messages_fts(messages_fts) VALUES('rebuild');")
        conn.commit()
        conn.execute("DETACH DATABASE src;")
    finally:
        conn.close()

    # Counts after
    print("\nAFTER:")
    with sqlite3.connect(str(target_db)) as t_post:
        after_with = t_post.execute(
            "SELECT COUNT(*) FROM messages WHERE text IS NOT NULL AND text != ''"
        ).fetchone()[0]
        after_without = t_post.execute(
            "SELECT COUNT(*) FROM messages WHERE text IS NULL OR text = ''"
        ).fetchone()[0]
        print(f"  with text:    {after_with:>8,}")
        print(f"  without text: {after_without:>8,}")
        print(f"\n  rows patched: {rows_patched:>8,}")
        recovered_pct = (after_with - before_with) / max(1, before_without) * 100
        print(f"  recovered:    {recovered_pct:>7.1f}% of previously-empty rows")

    # Update manifest's last_updated_at to reflect that we touched the bundle.
    manifest_path = target_bundle / "manifest.json"
    if manifest_path.exists():
        import json
        from datetime import UTC, datetime

        try:
            m = json.loads(manifest_path.read_text())
            m["last_updated_at"] = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
            m["repaired"] = {
                "tool": "scripts/patch-archive-text.py",
                "rows_patched": rows_patched,
            }
            manifest_path.write_text(json.dumps(m, indent=2))
        except Exception as e:
            print(f"  (manifest update skipped: {e})")

    print(f"\nBackup at {backup} — delete after you've confirmed everything looks right.")
    print("Run 'imessage-archiver verify' on the target to sanity-check attachments.")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--target", type=Path, required=True, help="Bundle to patch in place")
    p.add_argument("--source", type=Path, required=True, help="Bundle to read text from (read-only)")
    args = p.parse_args()
    return patch(args.target.expanduser(), args.source.expanduser())


if __name__ == "__main__":
    sys.exit(main())
