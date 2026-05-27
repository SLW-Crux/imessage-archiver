"""Unit tests for the DB reader against synthetic fixtures."""

from __future__ import annotations

from unittest.mock import patch
import pytest
from pathlib import Path

from imessage_archiver.db.reader import Reader, _resolve_attachment_path

FIXTURES = Path(__file__).parent.parent / "fixtures"


def fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not generated — run tests/fixtures/generate.py")
    return p


class TestTinyDb:
    def setup_method(self) -> None:
        self.reader = Reader(fixture("tiny.db"))

    def teardown_method(self) -> None:
        self.reader.close()

    def test_list_chats_count(self) -> None:
        chats = self.reader.list_chats()
        assert len(chats) == 2

    def test_chats_have_guids(self) -> None:
        for c in self.reader.list_chats():
            assert c.chat_guid
            assert c.chat_guid.startswith("CHAT-")

    def test_message_count(self) -> None:
        chats = self.reader.list_chats()
        total = sum(c.message_count for c in chats)
        assert total == 8

    def test_messages_in_first_chat(self) -> None:
        chats = self.reader.list_chats()
        # Sort by first_message_at to get deterministic order
        chats.sort(key=lambda c: c.first_message_at or 0)
        msgs = self.reader.messages_in_chat(chats[0].chat_guid)
        assert len(msgs) == 5

    def test_messages_have_timestamps(self) -> None:
        chats = self.reader.list_chats()
        for c in chats:
            for m in self.reader.messages_in_chat(c.chat_guid):
                assert m.timestamp > 0

    def test_attachments_on_first_messages(self) -> None:
        chats = self.reader.list_chats()
        chats.sort(key=lambda c: c.first_message_at or 0)
        msgs = self.reader.messages_in_chat(chats[0].chat_guid)
        assert msgs[0].has_attachments
        atts = self.reader.attachments_for_message(msgs[0].message_guid)
        assert len(atts) == 1

    def test_is_from_me_alternates(self) -> None:
        chats = self.reader.list_chats()
        chats.sort(key=lambda c: c.first_message_at or 0)
        msgs = self.reader.messages_in_chat(chats[0].chat_guid)
        # Messages alternate is_from_me (0=even, 1=odd index)
        for i, m in enumerate(msgs):
            assert m.is_from_me == (i % 2 == 1)

    def test_context_manager(self) -> None:
        with Reader(fixture("tiny.db")) as r:
            assert len(r.list_chats()) == 2


class TestMediumDb:
    def setup_method(self) -> None:
        self.reader = Reader(fixture("medium.db"))

    def teardown_method(self) -> None:
        self.reader.close()

    def test_chat_count(self) -> None:
        chats = self.reader.list_chats()
        assert len(chats) == 50

    def test_total_message_count(self) -> None:
        msgs = list(self.reader.all_messages())
        assert len(msgs) == 5000

    def test_all_messages_have_chat_guid(self) -> None:
        for chat_guid, msg in self.reader.all_messages():
            assert chat_guid
            assert msg.chat_guid == chat_guid

    def test_chats_sorted_by_last_message(self) -> None:
        chats = self.reader.list_chats()
        timestamps = [c.last_message_at or 0 for c in chats]
        assert timestamps == sorted(timestamps, reverse=True)

    def test_message_counts_sum_to_5000(self) -> None:
        total = sum(c.message_count for c in self.reader.list_chats())
        assert total == 5000


class TestEdgeDb:
    def setup_method(self) -> None:
        self.reader = Reader(fixture("edge.db"))

    def teardown_method(self) -> None:
        self.reader.close()

    def test_attachment_only_message_has_no_text(self) -> None:
        all_msgs = [m for _, m in self.reader.all_messages()]
        att_only = [m for m in all_msgs if m.has_attachments and not m.text
                    and not m.associated_message_type]
        assert len(att_only) >= 1

    def test_tapback_messages_detected(self) -> None:
        all_msgs = [m for _, m in self.reader.all_messages()]
        tapbacks = [m for m in all_msgs if m.associated_message_type != 0]
        assert len(tapbacks) >= 2  # love + like + remove

    def test_reply_messages_have_reply_to_guid(self) -> None:
        all_msgs = [m for _, m in self.reader.all_messages()]
        replies = [m for m in all_msgs if m.reply_to_guid]
        assert len(replies) >= 2

    def test_group_chat_present(self) -> None:
        chats = self.reader.list_chats()
        groups = [c for c in chats if c.is_group]
        assert len(groups) >= 1

    def test_emoji_messages_present(self) -> None:
        all_msgs = [m for _, m in self.reader.all_messages()]
        emoji_msgs = [m for m in all_msgs if m.text and "👋" in m.text]
        assert len(emoji_msgs) >= 1

    def test_edited_message_has_date_edited(self) -> None:
        all_msgs = [m for _, m in self.reader.all_messages()]
        edited = [m for m in all_msgs if m.date_edited is not None]
        assert len(edited) >= 1

    def test_retracted_message_has_date_retracted(self) -> None:
        all_msgs = [m for _, m in self.reader.all_messages()]
        retracted = [m for m in all_msgs if m.date_retracted is not None]
        assert len(retracted) >= 1

    def test_all_messages_have_timestamps(self) -> None:
        for _, m in self.reader.all_messages():
            assert m.timestamp > 0, f"Zero timestamp on {m.message_guid}"

    def test_all_attachments_have_guids(self) -> None:
        for att in self.reader.all_attachments():
            assert att.attachment_guid
            assert att.message_guid


class TestAllFixtures:
    """Smoke tests across all generated fixtures."""

    @pytest.mark.parametrize(
        "db_name",
        ["tiny.db", "medium.db", "edge.db", "ventura.db", "sonoma.db", "sequoia.db"],
    )
    def test_opens_and_lists_chats(self, db_name: str) -> None:
        with Reader(fixture(db_name)) as r:
            chats = r.list_chats()
            assert len(chats) >= 1

    @pytest.mark.parametrize(
        "db_name",
        ["tiny.db", "medium.db", "edge.db", "ventura.db", "sonoma.db", "sequoia.db"],
    )
    def test_all_messages_decodable(self, db_name: str) -> None:
        with Reader(fixture(db_name)) as r:
            count = sum(1 for _ in r.all_messages())
            assert count >= 1


class TestReaderCoverageBranches:
    """Targeted tests to reach 100% coverage on reader.py."""

    def test_messages_in_chat_unknown_guid_returns_empty(self) -> None:
        """Unknown chat_guid → _chat_rowid returns None → line 133 `return []`."""
        with Reader(fixture("tiny.db")) as r:
            result = r.messages_in_chat("NONEXISTENT-GUID")
            assert result == []

    def test_attributed_body_message_decoded(self) -> None:
        """Message with null text but valid attributedBody — exercises _resolve_text line 301."""
        with Reader(fixture("edge.db")) as r:
            all_msgs = [m for _, m in r.all_messages()]
        ab_msgs = [m for m in all_msgs if m.text == "via attributedBody"]
        assert len(ab_msgs) >= 1

    def test_resolve_attachment_path_absolute(self) -> None:
        """Absolute filename path — exercises line 373-374."""
        result = _resolve_attachment_path("/var/mobile/Media/photo.jpg")
        assert result == Path("/var/mobile/Media/photo.jpg")

    def test_resolve_attachment_path_relative(self) -> None:
        """Relative filename — exercises line 375 fallback."""
        result = _resolve_attachment_path("relative/photo.jpg")
        assert result == Path.home() / "Library" / "Messages" / "relative/photo.jpg"

    def test_row_to_attachment_exception_caught(self) -> None:
        """_resolve_attachment_path raising is caught silently — exercises lines 356-357."""
        with Reader(fixture("edge.db")) as r:
            with patch("imessage_archiver.db.reader._resolve_attachment_path",
                       side_effect=ValueError("bad path")):
                atts = r.all_attachments()
                results = list(atts)
        assert len(results) >= 1
        for att in results:
            assert att.resolved_path is None
