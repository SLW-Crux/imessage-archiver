"""Message preview panel — shows the last 50 messages for a selected chat."""

from __future__ import annotations

import datetime

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame,
    QLabel,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from imessage_archiver.db.reader import MessageRow

_MAX_MESSAGES = 50


class MessageBubble(QFrame):
    """Single message bubble (sent/received style)."""

    def __init__(self, msg: MessageRow, parent=None) -> None:
        super().__init__(parent)
        self._build(msg)

    def _build(self, msg: MessageRow) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 4, 8, 4)
        layout.setSpacing(2)

        # Sender + timestamp header
        sender = "Me" if msg.is_from_me else (msg.sender_name or msg.sender_handle or "?")
        ts_str = _fmt_ts(msg.timestamp)
        header = QLabel(f"<small><b>{sender}</b> — {ts_str}</small>")
        header.setTextFormat(Qt.RichText)
        layout.addWidget(header)

        # Message text
        text = msg.text or "[attachment]"
        if msg.date_retracted:
            text = "<i>[message unsent]</i>"
        elif msg.date_edited:
            text = f"{text} <small><i>(edited)</i></small>"

        body = QLabel(text)
        body.setWordWrap(True)
        body.setTextFormat(Qt.RichText)
        body.setTextInteractionFlags(Qt.TextSelectableByMouse)
        layout.addWidget(body)

        # Reactions
        if msg.reactions_json:
            import json

            try:
                reactions = json.loads(msg.reactions_json)
                rtext = "  ".join(
                    f"{_reaction_emoji(r.get('type', ''))} {r.get('from', '')}" for r in reactions
                )
                rlabel = QLabel(f"<small>{rtext}</small>")
                rlabel.setTextFormat(Qt.RichText)
                layout.addWidget(rlabel)
            except Exception:
                pass

        # Style by direction
        self.setFrameShape(QFrame.StyledPanel)
        if msg.is_from_me:
            self.setProperty("sent", True)
        self.setStyleSheet(
            "QFrame[sent='true'] { background: #DCF8C6; border-radius: 8px; }"
            "QFrame { background: #F1F0F0; border-radius: 8px; }"
        )


class MessageView(QWidget):
    """Scrollable list of message bubbles for a chat thread."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._scroll = QScrollArea()
        self._scroll.setWidgetResizable(True)
        self._scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)

        self._container = QWidget()
        self._vbox = QVBoxLayout(self._container)
        self._vbox.setAlignment(Qt.AlignTop)
        self._vbox.setSpacing(4)
        self._scroll.setWidget(self._container)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(self._scroll)

    def load_messages(self, msgs: list[MessageRow]) -> None:
        # Clear existing
        while self._vbox.count():
            item = self._vbox.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        recent = msgs[-_MAX_MESSAGES:]
        for msg in recent:
            bubble = MessageBubble(msg)
            self._vbox.addWidget(bubble)

        # Scroll to bottom
        self._scroll.verticalScrollBar().setValue(self._scroll.verticalScrollBar().maximum())

    def clear(self) -> None:
        while self._vbox.count():
            item = self._vbox.takeAt(0)
            if item.widget():
                item.widget().deleteLater()


def _fmt_ts(ts: int) -> str:
    try:
        dt = datetime.datetime.fromtimestamp(ts)
        return dt.strftime("%b %d, %Y %H:%M")
    except Exception:
        return str(ts)


def _reaction_emoji(reaction_type: str) -> str:
    return {
        "love": "❤️",
        "like": "👍",
        "dislike": "👎",
        "laugh": "😂",
        "emphasize": "‼️",
        "question": "❓",
    }.get(reaction_type, "•")
