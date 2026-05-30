"""Parser for the attributedBody BLOB column in chat.db.

On macOS 10.13+ many messages store their text in the ``attributedBody``
column as a typedstream- or bplist-wrapped NSAttributedString rather than
the plain ``text`` column.  This module extracts the raw UTF-8 string.

Strategy
--------
1. **PyObjC NSUnarchiver** (preferred — handles both typedstream and
   NSKeyedArchiver formats natively, exactly as Messages.app does).
   Only available on macOS at runtime.
2. **Pure-Python bplist parser** (fallback for NSKeyedArchiver-format
   bodies on non-macOS systems).
3. **Pure-Python typedstream heuristic scan** (last-resort fallback for
   typedstream-format bodies on non-macOS systems — known to miss text
   for ~75% of real-world messages, but better than nothing).

The pure-Python paths exist so CI runs on Linux runners can still parse
synthetic bplist fixtures; production runs on macOS use the PyObjC path
and recover the full text content.
"""

from __future__ import annotations

import plistlib
import struct
from typing import Any

# Hard cap on the attributedBody size we attempt to parse. A pathologically
# large blob (corrupted row, or one synthesised by a tampered chat.db) would
# otherwise stall the archive process for minutes in the O(n²) typedstream
# scan. 2 MiB is far above any legitimate message body.
_MAX_BLOB_SIZE = 2 * 1024 * 1024

# Try to set up the PyObjC-based decoder at import time. NSUnarchiver requires
# AppKit to be imported so NSMutableAttributedString class registrations occur.
_PYOBJC_AVAILABLE = False
try:
    import AppKit  # noqa: F401  registers NSAttributedString and friends
    from Foundation import NSData, NSUnarchiver

    _PYOBJC_AVAILABLE = True
except Exception:
    _PYOBJC_AVAILABLE = False


def extract_text(blob: bytes) -> str | None:
    """Extract the plain-text string from an attributedBody blob.

    Returns ``None`` if the blob is empty, oversized, malformed, or
    contains no text.
    """
    if not blob:
        return None
    if len(blob) > _MAX_BLOB_SIZE:
        # Refuse to scan a multi-megabyte blob — almost certainly garbage
        # and the typedstream scan is O(n) per byte (Sec-M3).
        return None

    # 1. Preferred path: Apple's own NSUnarchiver. Handles BOTH the legacy
    #    typedstream format and the NSKeyedArchiver bplist format. Solves
    #    the truncation/None-return bugs in the pure-Python heuristic.
    if _PYOBJC_AVAILABLE:
        out = _from_pyobjc(blob)
        if out is not None:
            return out
        # Fall through to pure-Python on PyObjC failure (e.g., malformed blob)

    # 2. Pure-Python fallbacks. bplist for modern, typedstream for legacy.
    if blob[:6] == b"bplist":
        return _from_bplist(blob)
    return _from_typedstream(blob)


def _from_pyobjc(blob: bytes) -> str | None:
    """Decode via Apple's NSUnarchiver. Returns the .string of the
    NSAttributedString or None if decode fails. Only called when PyObjC
    is available."""
    try:
        data = NSData.dataWithBytes_length_(blob, len(blob))
        unarchiver = NSUnarchiver.alloc().initForReadingWithData_(data)
        obj = unarchiver.decodeObject()
    except Exception:
        return None
    if obj is None:
        return None
    # NSAttributedString.string() returns the plain text. Some encoded objects
    # may be plain NSString — guard with hasattr.
    try:
        s = obj.string() if hasattr(obj, "string") else obj
    except Exception:
        return None
    if not s:
        return None
    out = str(s)
    return out if out else None


def _from_bplist(blob: bytes) -> str | None:
    """Decode an NSKeyedArchiver bplist attributedBody."""
    try:
        root = plistlib.loads(blob)
    except Exception:
        return None

    if not isinstance(root, dict):
        return None

    # NSKeyedArchiver layout:
    # root["$objects"] is a list; root["$top"]["root"] is an UID pointing into it.
    objects = root.get("$objects")
    if not isinstance(objects, list):
        return None

    # Walk every object looking for NSString values
    return _find_nsstring(objects)


def _find_nsstring(objects: list[Any]) -> str | None:
    """Recursively search the $objects array for the NSAttributedString's NS.string."""
    for obj in objects:
        if not isinstance(obj, dict):
            continue
        # NSAttributedString stores the string under "NS.string"
        if "NS.string" in obj:
            val = obj["NS.string"]
            if isinstance(val, str) and val:
                return val
            if isinstance(val, bytes):
                try:
                    return val.decode("utf-8")
                except UnicodeDecodeError:
                    pass
        # NSMutableString / NSString stored directly
        if "$class" in obj:
            class_ref = obj["$class"]
            idx = class_ref.data if isinstance(class_ref, plistlib.UID) else None
            if idx is not None:
                class_obj = objects[idx] if idx < len(objects) else None
                if isinstance(class_obj, dict):
                    class_name = class_obj.get("$classname", "")
                    if "NSString" in class_name or "NSMutableString" in class_name:
                        # The string data may be in NS.bytes or NS.string on the same object
                        ns_bytes = obj.get("NS.bytes")
                        if isinstance(ns_bytes, bytes) and ns_bytes:
                            try:
                                return ns_bytes.decode("utf-8")
                            except UnicodeDecodeError:
                                pass
    return None


def _from_typedstream(blob: bytes) -> str | None:
    """Heuristic scan of legacy typedstream data for UTF-8 text.

    A typedstream encodes an NSAttributedString.  The string content is
    stored as a length-prefixed UTF-8 sequence somewhere in the blob.
    We scan for the longest valid UTF-8 run that looks like real text.
    """
    best: str = ""
    i = 0
    n = len(blob)
    while i < n - 4:
        # Look for a 2-byte big-endian length prefix followed by that many bytes
        length = struct.unpack_from(">H", blob, i)[0]
        if 4 <= length <= min(n - i - 2, 65535):
            candidate = blob[i + 2 : i + 2 + length]
            try:
                text = candidate.decode("utf-8")
                # Keep the longest candidate that contains printable chars
                if len(text) > len(best) and any(c.isprintable() for c in text):
                    best = text
            except UnicodeDecodeError:
                pass
        i += 1
    return best if best else None
