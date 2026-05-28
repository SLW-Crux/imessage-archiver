"""CLI entry point for iMessage Archiver.

Commands
--------
archive  -- snapshot chat.db and write/update an archive bundle
verify   -- verify SHA-256 integrity of all archived attachments
stats    -- print summary statistics for an archive bundle
merge    -- merge a specific chat.db snapshot into an existing archive
info     -- print archive manifest and run history
setup    -- check Full Disk Access and guide the user through first-run setup
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

import click
from rich.console import Console
from rich.progress import BarColumn, Progress, SpinnerColumn, TextColumn, TimeElapsedColumn
from rich.table import Table

from imessage_archiver import __version__
from imessage_archiver.core.archive import ArchiveWriter, RunStats
from imessage_archiver.core.lock import ArchiveLock, LockError
from imessage_archiver.core.merge import _default_chat_db
from imessage_archiver.core.verify import verify_bundle
from imessage_archiver.db.reader import ChatRow, Reader
from imessage_archiver.db.snapshot import snapshot

console = Console()
err_console = Console(stderr=True, style="bold red")

# Bundle ID for the iOS reader app. The Mac archiver writes into the iOS app's
# iCloud ubiquity container so the iOS app's NSMetadataQueryUbiquitousDocumentsScope
# can discover the bundle. Writing to generic iCloud Drive (com~apple~CloudDocs)
# would put the bundle in a scope iOS cannot enumerate.
_IOS_BUNDLE_ID = "com.slw.imessage-archiver"
_ICLOUD_CONTAINER = f"iCloud~{_IOS_BUNDLE_ID.replace('.', '~')}"  # iCloud~com~slw~imessage-archiver
_DEFAULT_DEST = (
    Path.home() / "Library" / "Mobile Documents" / _ICLOUD_CONTAINER / "Documents" / "archive.imarchive"
)
_LOCK_PATH = Path.home() / ".imessage-archiver" / "archive.lock"


@click.group()
@click.version_option(__version__)
def cli() -> None:
    """iMessage Archiver — archive your messages to a portable bundle."""


# ---------------------------------------------------------------------------
# archive
# ---------------------------------------------------------------------------


@cli.command()
@click.option(
    "--dest",
    type=click.Path(),
    default=str(_DEFAULT_DEST),
    show_default=True,
    help="Path to the .imarchive bundle directory.",
)
@click.option(
    "--source",
    type=click.Path(exists=False),
    default=None,
    help="Path to chat.db (default: ~/Library/Messages/chat.db).",
)
@click.option("--dry-run", is_flag=True, help="Snapshot and count messages without writing archive.")
def archive(dest: str, source: str | None, dry_run: bool) -> None:
    """Snapshot chat.db and write/update the archive bundle."""
    source_db = Path(source) if source else _default_chat_db()
    bundle_path = Path(dest)

    _check_full_disk_access(source_db)

    if dry_run:
        console.print("[yellow]Dry run — snapshotting and counting only[/yellow]")
        snap_path, sha = snapshot(source=source_db)
        with Reader(snap_path) as r:
            chats = r.list_chats()
            total = sum(c.message_count for c in chats)
        console.print(f"[green]Found {len(chats)} chats, {total} messages[/green]")
        console.print(f"Source SHA-256: {sha[:16]}…")
        return

    try:
        with ArchiveLock(_LOCK_PATH):
            _run_archive(source_db, bundle_path)
    except LockError as e:
        err_console.print(str(e))
        sys.exit(1)


def _run_archive(source_db: Path, bundle_path: Path) -> None:
    snap_path, sha = _snapshot_with_progress(source_db)

    stats_holder: list[RunStats] = []

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TextColumn("{task.completed}/{task.total}"),
        TimeElapsedColumn(),
        console=console,
        transient=True,
    ) as progress:
        task = progress.add_task("Archiving messages…", total=None)

        def on_progress(chat: ChatRow, stats: RunStats) -> None:
            progress.update(
                task, description=f"[cyan]{chat.chat_guid[:30]}[/cyan]", completed=stats.messages_seen
            )

        with Reader(snap_path) as r:
            total_msgs = sum(c.message_count for c in r.list_chats())
            progress.update(task, total=total_msgs)

        with Reader(snap_path) as r:
            with ArchiveWriter(bundle_path) as w:
                stats = w.run(r, source_sha256=sha, source_db_path=str(source_db), progress=on_progress)
        stats_holder.append(stats)

    s = stats_holder[0]
    console.print(
        f"[green]Done![/green] {s.messages_seen:,} messages, "
        f"{s.attachments_written:,} new attachments archived "
        f"({s.attachments_missing:,} missing)."
    )
    console.print(f"Bundle: [blue]{bundle_path}[/blue]")


# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------


@cli.command()
@click.option(
    "--archive",
    "archive_path",
    type=click.Path(exists=True),
    default=None,
    help="Path to .imarchive bundle (default: iCloud location).",
)
def verify(archive_path: str | None) -> None:
    """Verify SHA-256 integrity of all archived attachments."""
    bundle = Path(archive_path) if archive_path else _DEFAULT_DEST

    if not bundle.exists():
        err_console.print(f"Bundle not found: {bundle}")
        sys.exit(1)

    with console.status("Verifying attachments…"):
        result = verify_bundle(bundle)

    if result.ok:
        console.print(
            f"[green]PASS[/green] — {result.checked:,} attachments verified " f"in {result.duration_s:.1f}s"
        )
    else:
        console.print(f"[red]FAIL[/red] — {len(result.failures)} failures out of {result.checked}")
        for f in result.failures:
            console.print(f"  [red]{f}[/red]")
        sys.exit(1)


# ---------------------------------------------------------------------------
# stats
# ---------------------------------------------------------------------------


@cli.command()
@click.option("--archive", "archive_path", type=click.Path(), default=None)
def stats(archive_path: str | None) -> None:
    """Print summary statistics for an archive bundle."""
    bundle = Path(archive_path) if archive_path else _DEFAULT_DEST
    _require_bundle(bundle)

    manifest_path = bundle / "manifest.json"

    try:
        manifest = json.loads(manifest_path.read_text())
    except Exception:
        manifest = {}

    table = Table(title=f"Archive stats — {bundle.name}")
    table.add_column("Field", style="bold")
    table.add_column("Value")

    table.add_row("Schema version", str(manifest.get("schema_version", "?")))
    table.add_row("Archiver version", manifest.get("archiver_version", "?"))
    table.add_row("Created", manifest.get("created_at", "?"))
    table.add_row("Last updated", manifest.get("last_updated_at", "?"))
    table.add_row(
        "Chats",
        f"{manifest.get('chat_count', '?'):,}" if isinstance(manifest.get("chat_count"), int) else "?",
    )
    table.add_row(
        "Messages",
        f"{manifest.get('message_count', '?'):,}" if isinstance(manifest.get("message_count"), int) else "?",
    )
    table.add_row(
        "Attachments",
        (
            f"{manifest.get('attachment_count', '?'):,}"
            if isinstance(manifest.get("attachment_count"), int)
            else "?"
        ),
    )
    table.add_row(
        "Missing attachments",
        (
            f"{manifest.get('missing_attachment_count', '?'):,}"
            if isinstance(manifest.get("missing_attachment_count"), int)
            else "?"
        ),
    )
    size_bytes = manifest.get("archive_size_bytes", 0)
    table.add_row("Archive size", _fmt_bytes(size_bytes) if isinstance(size_bytes, int) else "?")

    console.print(table)


# ---------------------------------------------------------------------------
# merge
# ---------------------------------------------------------------------------


@cli.command()
@click.option(
    "--source",
    type=click.Path(exists=False),
    required=False,
    default=None,
    help="Path to chat.db to merge from.",
)
@click.option(
    "--archive",
    "archive_path",
    type=click.Path(),
    required=True,
    help="Path to .imarchive bundle to merge into.",
)
def merge(source: str | None, archive_path: str) -> None:
    """Merge a chat.db snapshot into an existing archive bundle."""
    source_db = Path(source) if source else _default_chat_db()
    bundle = Path(archive_path)

    _check_full_disk_access(source_db)

    try:
        with ArchiveLock(_LOCK_PATH):
            _run_archive(source_db, bundle)
    except LockError as e:
        err_console.print(str(e))
        sys.exit(1)


# ---------------------------------------------------------------------------
# info
# ---------------------------------------------------------------------------


@cli.command()
@click.option("--archive", "archive_path", type=click.Path(), default=None)
def info(archive_path: str | None) -> None:
    """Print archive manifest and run history."""
    bundle = Path(archive_path) if archive_path else _DEFAULT_DEST
    _require_bundle(bundle)

    manifest_path = bundle / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
        console.print_json(json.dumps(manifest, indent=2))
    except Exception as e:
        err_console.print(f"Could not read manifest: {e}")
        sys.exit(1)

    sqlite_path = bundle / "archive.sqlite"
    if sqlite_path.exists():
        conn = sqlite3.connect(f"file:{sqlite_path}?mode=ro&immutable=1", uri=True)
        runs = conn.execute("""SELECT run_id, started_at, completed_at, message_count, archiver_version
               FROM archive_runs ORDER BY started_at DESC LIMIT 10""").fetchall()
        conn.close()

        if runs:
            t = Table(title="Recent archive runs (newest first)")
            t.add_column("Run ID", style="dim")
            t.add_column("Started")
            t.add_column("Messages")
            t.add_column("Version")
            import datetime

            for run_id, started, completed, msg_count, ver in runs:
                ts = datetime.datetime.fromtimestamp(started).strftime("%Y-%m-%d %H:%M")
                t.add_row(run_id[:8] + "…", ts, str(msg_count or "?"), ver or "?")
            console.print(t)


# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------


@cli.command()
def setup() -> None:
    """Check Full Disk Access and guide first-run setup."""
    console.rule("[bold blue]iMessage Archiver Setup[/bold blue]")
    chat_db = _default_chat_db()

    console.print(f"\nChecking Full Disk Access for [bold]{chat_db}[/bold]…")

    if chat_db.exists():
        try:
            chat_db.open("rb").close()
            console.print("[green]✓ Full Disk Access granted[/green]")
        except PermissionError:
            _print_fda_instructions()
            sys.exit(1)
    else:
        console.print("[yellow]⚠ chat.db not found — Messages may not be set up on this Mac.[/yellow]")
        return

    console.print("\nDefault archive destination:")
    console.print(f"  [blue]{_DEFAULT_DEST}[/blue]")
    console.print("\nRun [bold]imessage-archiver archive[/bold] to create your first archive.")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _check_full_disk_access(chat_db: Path) -> None:
    if not chat_db.exists():
        err_console.print(f"[red]chat.db not found:[/red] {chat_db}")
        sys.exit(1)
    try:
        chat_db.open("rb").close()
    except PermissionError:
        _print_fda_instructions()
        sys.exit(1)


def _print_fda_instructions() -> None:
    err_console.print("\n[red]Full Disk Access required.[/red]")
    err_console.print(
        "Open [bold]System Settings → Privacy & Security → Full Disk Access[/bold]\n"
        "and grant access to Terminal (or your shell app), then try again."
    )


def _require_bundle(bundle: Path) -> None:
    if not bundle.exists():
        err_console.print(f"Bundle not found: {bundle}")
        sys.exit(1)


def _fmt_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n //= 1024
    return f"{n:.1f} PB"


def _snapshot_with_progress(source_db: Path) -> tuple[Path, str]:
    with console.status(f"[cyan]Snapshotting {source_db.name}…[/cyan]"):
        return snapshot(source=source_db)
