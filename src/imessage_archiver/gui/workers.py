"""Background worker threads for long-running operations."""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QThread, Signal

from imessage_archiver.core.archive import ArchiveWriter, RunStats
from imessage_archiver.core.lock import ArchiveLock, LockError
from imessage_archiver.db.reader import ChatRow, Reader
from imessage_archiver.db.snapshot import snapshot


class ArchiveWorker(QThread):
    """Runs a full archive in a background thread.

    Emits progress updates and a final done/error signal.
    """

    progress = Signal(str, int, int)  # (description, completed, total)
    finished = Signal(object)  # RunStats
    error = Signal(str)  # error message

    _LOCK = Path.home() / ".imessage-archiver" / "archive.lock"

    def __init__(
        self,
        source_db: Path,
        bundle_path: Path,
        parent=None,
    ) -> None:
        super().__init__(parent)
        self._source_db = source_db
        self._bundle_path = bundle_path

    def run(self) -> None:
        try:
            with ArchiveLock(self._LOCK):
                snap_path, sha = snapshot(source=self._source_db)

                with Reader(snap_path) as r:
                    chats = r.list_chats()
                    total = sum(c.message_count for c in chats)

                def on_progress(chat: ChatRow, stats: RunStats) -> None:
                    label = chat.display_name or chat.chat_identifier or chat.chat_guid
                    self.progress.emit(label, stats.messages_seen, total)

                with Reader(snap_path) as r:
                    with ArchiveWriter(self._bundle_path) as w:
                        stats = w.run(
                            r,
                            source_sha256=sha,
                            source_db_path=str(self._source_db),
                            progress=on_progress,
                        )

            self.finished.emit(stats)
        except LockError as e:
            self.error.emit(str(e))
        except Exception as e:
            self.error.emit(f"Archive failed: {e}")


class LoadChatsWorker(QThread):
    """Loads the chat list from a Reader in the background."""

    finished = Signal(list)  # list[ChatRow]
    error = Signal(str)

    def __init__(self, db_path: Path, parent=None) -> None:
        super().__init__(parent)
        self._db_path = db_path

    def run(self) -> None:
        try:
            with Reader(self._db_path) as r:
                chats = r.list_chats()
            self.finished.emit(chats)
        except Exception as e:
            self.error.emit(str(e))


class LoadMessagesWorker(QThread):
    """Loads messages for a single chat in the background."""

    finished = Signal(str, list)  # (chat_guid, list[MessageRow])
    error = Signal(str)

    def __init__(self, db_path: Path, chat_guid: str, parent=None) -> None:
        super().__init__(parent)
        self._db_path = db_path
        self._chat_guid = chat_guid

    def run(self) -> None:
        try:
            with Reader(self._db_path) as r:
                msgs = r.messages_in_chat(self._chat_guid)
            self.finished.emit(self._chat_guid, msgs)
        except Exception as e:
            self.error.emit(str(e))
