"""Main three-panel window for iMessage Archiver."""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, QTimer
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
from imessage_archiver.gui.workers import LoadChatsWorker, LoadMessagesWorker

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
        self._workers: list = []

        self._stack = QStackedWidget()
        self.setCentralWidget(self._stack)

        if _has_full_disk_access():
            self._show_main()
        else:
            self._show_setup()

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

        self._chat_status = QLabel("Loading…")
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

        self._load_chats()

    # ------------------------------------------------------------------
    # Chat loading
    # ------------------------------------------------------------------

    def _load_chats(self) -> None:
        worker = LoadChatsWorker(db_path=self._chat_db)
        worker.finished.connect(self._on_chats_loaded)
        worker.error.connect(self._on_load_error)
        self._workers.append(worker)
        worker.finished.connect(lambda _: self._workers.remove(worker))
        worker.start()

    def _on_chats_loaded(self, chats: list[ChatRow]) -> None:
        self._chat_model.load(chats)
        n = len(chats)
        self._chat_status.setText(f"{n} conversation{'s' if n != 1 else ''}")

    def _on_load_error(self, message: str) -> None:
        self._chat_status.setText(f"Error: {message}")

    # ------------------------------------------------------------------
    # Chat selection → message loading
    # ------------------------------------------------------------------

    def _on_chat_selected(self, index, _prev) -> None:
        chat = self._chat_model.chat_at(index.row())
        if chat is None:
            return
        self._message_view.clear()
        self._load_messages(chat.chat_guid)

    def _load_messages(self, chat_guid: str) -> None:
        worker = LoadMessagesWorker(db_path=self._chat_db, chat_guid=chat_guid)
        worker.finished.connect(self._on_messages_loaded)
        worker.error.connect(self._on_load_error)
        self._workers.append(worker)
        worker.finished.connect(lambda *_: self._workers.remove(worker))
        worker.start()

    def _on_messages_loaded(self, chat_guid: str, msgs: list[MessageRow]) -> None:
        self._message_view.load_messages(msgs)

    # ------------------------------------------------------------------
    # Search
    # ------------------------------------------------------------------

    def _on_search(self, text: str) -> None:
        self._chat_model.set_filter(text)
