"""Tests for GUI model layer (no display required)."""

from __future__ import annotations

import os
import sys

import pytest

# Must set QT_QPA_PLATFORM before any PySide6 import so Qt doesn't try to open a display.
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import Qt, QModelIndex
from PySide6.QtWidgets import QApplication

from imessage_archiver.db.reader import ChatRow
from imessage_archiver.gui.models import ChatListModel


@pytest.fixture(scope="module")
def app():
    instance = QApplication.instance() or QApplication(sys.argv[:1])
    yield instance


def _chat(guid: str, name: str | None = None, ident: str | None = None, count: int = 1) -> ChatRow:
    return ChatRow(
        chat_guid=guid,
        chat_identifier=ident or f"+1555{guid[-4:]}",
        display_name=name,
        service_name="iMessage",
        message_count=count,
        first_message_at=None,
        last_message_at=0,
        is_group=False,
        participants=[],
    )


class TestChatListModel:
    def test_empty_model(self, app):
        m = ChatListModel()
        assert m.rowCount() == 0
        assert m.chat_at(0) is None

    def test_load_populates_rows(self, app):
        m = ChatListModel()
        chats = [_chat("A", name="Alice"), _chat("B", name="Bob")]
        m.load(chats)
        assert m.rowCount() == 2

    def test_display_role_uses_display_name(self, app):
        m = ChatListModel()
        m.load([_chat("X", name="Carol")])
        idx = m.index(0, 0)
        assert m.data(idx, Qt.DisplayRole) == "Carol"

    def test_display_role_falls_back_to_identifier(self, app):
        m = ChatListModel()
        m.load([_chat("X", name=None, ident="+15551234")])
        idx = m.index(0, 0)
        assert m.data(idx, Qt.DisplayRole) == "+15551234"

    def test_display_role_falls_back_to_guid(self, app):
        m = ChatListModel()
        chat = ChatRow(
            chat_guid="GUID-99",
            chat_identifier=None,
            display_name=None,
            service_name=None,
            message_count=0,
            first_message_at=None,
            last_message_at=0,
            is_group=False,
            participants=[],
        )
        m.load([chat])
        idx = m.index(0, 0)
        assert m.data(idx, Qt.DisplayRole) == "GUID-99"

    def test_tooltip_role(self, app):
        m = ChatListModel()
        m.load([_chat("X", ident="+15551234", count=42)])
        idx = m.index(0, 0)
        tip = m.data(idx, Qt.ToolTipRole)
        assert "+15551234" in tip
        assert "42" in tip

    def test_custom_roles(self, app):
        m = ChatListModel()
        m.load([_chat("GUID-1", count=7)])
        idx = m.index(0, 0)
        assert m.data(idx, ChatListModel.ChatGuidRole) == "GUID-1"
        assert m.data(idx, ChatListModel.MessageCountRole) == 7
        assert m.data(idx, ChatListModel.LastMessageAtRole) == 0

    def test_invalid_index_returns_none(self, app):
        m = ChatListModel()
        m.load([_chat("X")])
        invalid = QModelIndex()
        assert m.data(invalid) is None
        assert m.data(m.index(99, 0)) is None

    def test_unknown_role_returns_none(self, app):
        m = ChatListModel()
        m.load([_chat("X")])
        assert m.data(m.index(0, 0), 9999) is None

    def test_filter_by_name(self, app):
        m = ChatListModel()
        m.load([_chat("A", name="Alice"), _chat("B", name="Bob")])
        m.set_filter("ali")
        assert m.rowCount() == 1
        assert m.chat_at(0).chat_guid == "A"

    def test_filter_by_identifier(self, app):
        m = ChatListModel()
        m.load([_chat("A", ident="+15559876"), _chat("B", ident="+15554321")])
        m.set_filter("9876")
        assert m.rowCount() == 1
        assert m.chat_at(0).chat_guid == "A"

    def test_filter_empty_string_shows_all(self, app):
        m = ChatListModel()
        m.load([_chat("A"), _chat("B"), _chat("C")])
        m.set_filter("Z")
        assert m.rowCount() == 0
        m.set_filter("")
        assert m.rowCount() == 3

    def test_chat_at_out_of_range(self, app):
        m = ChatListModel()
        m.load([_chat("X")])
        assert m.chat_at(-1) is None
        assert m.chat_at(1) is None
