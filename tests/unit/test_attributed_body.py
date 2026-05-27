"""Unit tests for attributedBody parser."""

import plistlib
from imessage_archiver.db.attributed_body import extract_text


def _make_bplist_attributed_string(text: str) -> bytes:
    """Build a minimal NSKeyedArchiver bplist with NS.string = text."""
    root = {
        "$version": 100000,
        "$archiver": "NSKeyedArchiver",
        "$top": {"root": plistlib.UID(1)},
        "$objects": [
            "$null",
            {"$class": plistlib.UID(2), "NS.string": text},
            {"$classname": "NSAttributedString", "$classes": ["NSAttributedString", "NSObject"]},
        ],
    }
    return plistlib.dumps(root, fmt=plistlib.FMT_BINARY)


class TestExtractText:
    def test_none_returns_none(self) -> None:
        assert extract_text(None) is None  # type: ignore[arg-type]

    def test_empty_bytes_returns_none(self) -> None:
        assert extract_text(b"") is None

    def test_garbage_bytes_returns_none(self) -> None:
        result = extract_text(b"\x00\x01\x02\x03")
        # May return None or empty; must not raise
        assert result is None or result == ""

    def test_bplist_simple_string(self) -> None:
        blob = _make_bplist_attributed_string("Hello, World!")
        result = extract_text(blob)
        assert result == "Hello, World!"

    def test_bplist_emoji(self) -> None:
        blob = _make_bplist_attributed_string("Hello 👋 World 🌍")
        result = extract_text(blob)
        assert result == "Hello 👋 World 🌍"

    def test_bplist_rtl(self) -> None:
        blob = _make_bplist_attributed_string("مرحبا كيف حالك")
        result = extract_text(blob)
        assert result == "مرحبا كيف حالك"

    def test_bplist_long_message(self) -> None:
        long_text = "A" * 10001
        blob = _make_bplist_attributed_string(long_text)
        result = extract_text(blob)
        assert result == long_text

    def test_bplist_non_dict_root_returns_none(self) -> None:
        # A bplist whose root is a list, not a dict
        blob = plistlib.dumps(["not", "a", "dict"], fmt=plistlib.FMT_BINARY)
        assert extract_text(blob) is None

    def test_bplist_no_objects_key_returns_none(self) -> None:
        blob = plistlib.dumps({"key": "value"}, fmt=plistlib.FMT_BINARY)
        assert extract_text(blob) is None

    def test_bplist_ns_string_as_bytes(self) -> None:
        """NS.string stored as bytes rather than str."""
        root = {
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": {"root": plistlib.UID(1)},
            "$objects": [
                "$null",
                {"$class": plistlib.UID(2), "NS.string": b"bytes string"},
                {"$classname": "NSAttributedString", "$classes": ["NSAttributedString"]},
            ],
        }
        blob = plistlib.dumps(root, fmt=plistlib.FMT_BINARY)
        result = extract_text(blob)
        assert result == "bytes string"

    def test_typedstream_fallback(self) -> None:
        """Legacy typedstream: craft bytes with a length-prefixed UTF-8 run."""
        import struct
        text = "Hello typedstream"
        encoded = text.encode("utf-8")
        # Build a fake typedstream: 2-byte big-endian length + data
        blob = b"\x04\x0b\x00\x00" + struct.pack(">H", len(encoded)) + encoded
        result = extract_text(blob)
        assert result == text

    def test_typedstream_no_valid_runs_returns_none(self) -> None:
        """Bytes that don't contain valid UTF-8 length-prefixed runs."""
        blob = bytes(range(50))  # arbitrary non-bplist bytes
        result = extract_text(blob)
        # Result is None or empty string — must not raise
        assert result is None or result == ""

    def test_malformed_bplist_returns_none(self) -> None:
        """bplist header present but corrupt body — hits the except branch."""
        blob = b"bplist00" + b"\xff\xfe" * 20
        result = extract_text(blob)
        assert result is None

    def test_bplist_ns_bytes_on_nsstring_class(self) -> None:
        """NS.bytes path inside the $class / integer branch."""
        root = {
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": {"root": plistlib.UID(1)},
            "$objects": [
                "$null",
                {
                    "$class": plistlib.UID(2),
                    # No NS.string here — only NS.bytes
                    "NS.bytes": "via bytes".encode("utf-8"),
                },
                {"$classname": "NSMutableString", "$classes": ["NSMutableString", "NSString"]},
            ],
        }
        blob = plistlib.dumps(root, fmt=plistlib.FMT_BINARY)
        result = extract_text(blob)
        assert result == "via bytes"

    def test_bplist_ns_string_bytes_invalid_utf8_returns_none(self) -> None:
        """NS.string stored as bytes with invalid UTF-8 — hits UnicodeDecodeError on line 74."""
        root = {
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": {"root": plistlib.UID(1)},
            "$objects": [
                "$null",
                {"$class": plistlib.UID(2), "NS.string": b"\xff\xfe\xfd"},
                {"$classname": "NSAttributedString", "$classes": ["NSAttributedString"]},
            ],
        }
        blob = plistlib.dumps(root, fmt=plistlib.FMT_BINARY)
        result = extract_text(blob)
        assert result is None

    def test_bplist_ns_bytes_invalid_utf8_returns_none(self) -> None:
        """NS.bytes with invalid UTF-8 and no fallback — hits except+return None path."""
        root = {
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": {"root": plistlib.UID(1)},
            "$objects": [
                "$null",
                {"$class": plistlib.UID(2), "NS.bytes": b"\xff\xfe\xfd"},
                {"$classname": "NSMutableString", "$classes": ["NSMutableString", "NSString"]},
            ],
        }
        blob = plistlib.dumps(root, fmt=plistlib.FMT_BINARY)
        result = extract_text(blob)
        assert result is None

    def test_typedstream_invalid_utf8_skipped(self) -> None:
        """Length-prefixed run that is not valid UTF-8 — hits UnicodeDecodeError branch."""
        import struct
        # Valid UTF-8 text we want found
        good = "found me".encode("utf-8")
        # Invalid UTF-8 bytes (lone 0xFF byte) with a valid length prefix
        bad = b"\xff\xfe\xfd\xfc"
        blob = (
            b"\x00" * 4
            + struct.pack(">H", len(bad)) + bad
            + struct.pack(">H", len(good)) + good
        )
        result = extract_text(blob)
        assert result == "found me"
