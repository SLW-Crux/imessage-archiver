"""Qt data models for the conversation list and message preview."""

from __future__ import annotations

from typing import Any

from PySide6.QtCore import QAbstractListModel, QModelIndex, Qt, QObject, Signal
from PySide6.QtGui import QColor

from imessage_archiver.db.reader import ChatRow, MessageRow


class ChatListModel(QAbstractListModel):
    """List model backed by a list of ChatRow objects.

    Supports filtering via :meth:`set_filter`.
    """

    ChatGuidRole = Qt.UserRole + 1
    LastMessageAtRole = Qt.UserRole + 2
    MessageCountRole = Qt.UserRole + 3

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._all_chats: list[ChatRow] = []
        self._filtered: list[ChatRow] = []
        self._filter_text = ""

    def load(self, chats: list[ChatRow]) -> None:
        self.beginResetModel()
        self._all_chats = chats
        self._apply_filter()
        self.endResetModel()

    def set_filter(self, text: str) -> None:
        self.beginResetModel()
        self._filter_text = text.lower()
        self._apply_filter()
        self.endResetModel()

    def _apply_filter(self) -> None:
        if not self._filter_text:
            self._filtered = list(self._all_chats)
        else:
            self._filtered = [
                c for c in self._all_chats
                if self._filter_text in (c.display_name or "").lower()
                or self._filter_text in (c.chat_identifier or "").lower()
            ]

    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return len(self._filtered)

    def data(self, index: QModelIndex, role: int = Qt.DisplayRole) -> Any:
        if not index.isValid() or index.row() >= len(self._filtered):
            return None
        chat = self._filtered[index.row()]
        if role == Qt.DisplayRole:
            return chat.display_name or chat.chat_identifier or chat.chat_guid
        if role == Qt.ToolTipRole:
            return f"{chat.chat_identifier} — {chat.message_count} messages"
        if role == self.ChatGuidRole:
            return chat.chat_guid
        if role == self.LastMessageAtRole:
            return chat.last_message_at
        if role == self.MessageCountRole:
            return chat.message_count
        return None

    def chat_at(self, row: int) -> ChatRow | None:
        if 0 <= row < len(self._filtered):
            return self._filtered[row]
        return None
