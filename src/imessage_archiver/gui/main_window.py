"""Main three-panel window for iMessage Archiver."""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QCloseEvent
from PySide6.QtWidgets import (
    QLabel,
    QLineEdit,
    QListView,
    QMainWindow,
    QSplitter,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from imessage_archiver.db.reader import ChatRow, MessageRow
from imessage_archiver.gui.archive_panel import ArchivePanel
from imessage_archiver.gui.message_view import MessageView
from imessage_archiver.gui.models import ChatListModel
from imessage_archiver.gui.setup_screen import SetupScreen, _has_full_disk_access
from imessage_archiver.gui.workers import (
    LoadChatsWorker,
    LoadMessagesWorker,
    SnapshotWorker,
)

_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"
_WINDOW_TITLE = "iMessage Archiver"


class MainWindow(QMainWindow):
    """Three-panel main window: chat list | message preview | archive controls."""

    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(_WINDOW_TITLE)
        self.setMinimumSize(900, 600)
        self.resize(1200, 750)

        self._chat_db: Path = _CHAT_DB
        # Snapshot of chat.db taken once at startup. The Reader uses
        # immutable=1 which is unsafe against a live WAL — Messages.app
        # may be checkpointing — so we always read from the snapshot.
        self._snapshot_path: Path | None = None
        self._workers: list = []
        # Last chat_guid the user clicked. Used to drop stale
        # LoadMessagesWorker callbacks when the user clicks rapidly.
        self._current_chat_guid: str | None = None

        self._stack = QStackedWidget()
        self.setCentralWidget(self._stack)

        if _has_full_disk_access():
            self._show_main()
        else:
            self._show_setup()

    # ------------------------------------------------------------------
    # Window lifecycle
    # ------------------------------------------------------------------

    def closeEvent(self, event: QCloseEvent) -> None:  # noqa: N802 (Qt override)
        """Tear down all running worker threads before the window dies.

        Without this, in-flight QThreads would emit signals after their
        targets had been deleted, and shutdown would block until they
        finished naturally.
        """
        for worker in list(self._workers):
            try:
                worker.quit()
                worker.wait(3000)
            except RuntimeError:
                # Worker already dead — Qt raises on already-deleted objects.
                pass
        self._workers.clear()
        super().closeEvent(event)

    # ------------------------------------------------------------------
    # Setup screen
    # ------------------------------------------------------------------

    def _show_setup(self) -> None:
        screen = SetupScreen()
        screen.access_granted.connect(self._on_access_granted)
        self._stack.addWidget(screen)
        self._stack.setCurrentWidget(screen)

    def _on_access_granted(self) -> None:
        self._show_main()

    # ------------------------------------------------------------------
    # Main three-panel layout
    # ------------------------------------------------------------------

    def _show_main(self) -> None:
        splitter = QSplitter(Qt.Horizontal)
        splitter.setHandleWidth(1)

        # --- Left: chat list + search ---
        left_widget = QWidget()
        left_layout = QVBoxLayout(left_widget)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.setSpacing(0)

        self._search_box = QLineEdit()
        self._search_box.setPlaceholderText("Search conversations…")
        self._search_box.textChanged.connect(self._on_search)
        left_layout.addWidget(self._search_box)

        self._chat_model = ChatListModel()
        self._chat_list = QListView()
        self._chat_list.setModel(self._chat_model)
        self._chat_list.selectionModel().currentChanged.connect(self._on_chat_selected)
        left_layout.addWidget(self._chat_list, 1)

        self._chat_status = QLabel("Snapshotting chat.db…")
        self._chat_status.setAlignment(Qt.AlignCenter)
        left_layout.addWidget(self._chat_status)

        # --- Centre: message preview ---
        self._message_view = MessageView()

        # --- Right: archive controls ---
        self._archive_panel = ArchivePanel()

        splitter.addWidget(left_widget)
        splitter.addWidget(self._message_view)
        splitter.addWidget(self._archive_panel)
        splitter.setSizes([250, 550, 300])

        self._stack.addWidget(splitter)
        self._stack.setCurrentWidget(splitter)

        # Take the snapshot first. _on_snapshot_ready will kick off the
        # chat-list load against the snapshot path.
        self._take_snapshot()

    # ------------------------------------------------------------------
    # Snapshot → chat list load
    # ------------------------------------------------------------------

    def _take_snapshot(self) -> None:
        worker = SnapshotWorker(source_db=self._chat_db)
        worker.finished.connect(self._on_snapshot_ready)
        worker.error.connect(self._on_load_error)
        self._track(worker)
        worker.start()

    def _on_snapshot_ready(self, snap_path: Path, _sha: str) -> None:
        self._snapshot_path = snap_path
        self._chat_status.setText("Loading conversations…")
        self._load_chats()

    def _load_chats(self) -> None:
        assert self._snapshot_path is not None, "snapshot must precede chat load"
        worker = LoadChatsWorker(db_path=self._snapshot_path)
        worker.finished.connect(self._on_chats_loaded)
        worker.error.connect(self._on_load_error)
        self._track(worker)
        worker.start()

    def _on_chats_loaded(self, chats: list[ChatRow]) -> None:
        self._chat_model.load(chats)
        n = len(chats)
        self._chat_status.setText(f"{n} conversation{'s' if n != 1 else ''}")

    def _on_load_error(self, message: str) -> None:
        self._chat_status.setText(f"Error: {message}")

    # ------------------------------------------------------------------
    # Chat selection → message loading (with last-write-wins protection)
    # ------------------------------------------------------------------

    def _on_chat_selected(self, index, _prev) -> None:
        chat = self._chat_model.chat_at(index.row())
        if chat is None:
            return
        self._current_chat_guid = chat.chat_guid
        self._message_view.clear()
        self._load_messages(chat.chat_guid)

    def _load_messages(self, chat_guid: str) -> None:
        if self._snapshot_path is None:
            return
        worker = LoadMessagesWorker(db_path=self._snapshot_path, chat_guid=chat_guid)
        worker.finished.connect(self._on_messages_loaded)
        worker.error.connect(self._on_load_error)
        self._track(worker)
        worker.start()

    def _on_messages_loaded(self, chat_guid: str, msgs: list[MessageRow]) -> None:
        # Drop stale results: only render messages for the chat the user
        # is currently viewing. The slower worker for a previously-selected
        # chat will silently noop.
        if chat_guid != self._current_chat_guid:
            return
        self._message_view.load_messages(msgs)

    # ------------------------------------------------------------------
    # Worker bookkeeping
    # ------------------------------------------------------------------

    def _track(self, worker) -> None:
        """Add *worker* to the cleanup list with a self-removing callback.

        Uses weakref-like indirection (capture by name only) to avoid the
        closure holding a strong reference that survives the QThread.
        """
        self._workers.append(worker)
        worker_id = id(worker)

        def _remove(*_args, _id=worker_id) -> None:
            self._workers[:] = [w for w in self._workers if id(w) != _id]

        worker.finished.connect(_remove)
        worker.error.connect(_remove)

    # ------------------------------------------------------------------
    # Search
    # ------------------------------------------------------------------

    def _on_search(self, text: str) -> None:
        self._chat_model.set_filter(text)
