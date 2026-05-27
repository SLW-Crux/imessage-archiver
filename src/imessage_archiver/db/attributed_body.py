"""Parser for the attributedBody BLOB column in chat.db.

On macOS 10.13+ many messages store their text in the ``attributedBody``
column as a bplist-wrapped NSAttributedString (NSKeyedArchiver format) rather
than the plain ``text`` column.  This module extracts the raw UTF-8 string.

Strategy
--------
We use a pure-Python bplist parser followed by a recursive scan for the
``NSString`` value inside the NSKeyedArchiver graph.  We do NOT rely on
PyObjC here so the code works in CI and in unit tests without a macOS GUI
session.  If we cannot decode the blob we return ``None`` and the caller
treats the message as attachment-only.
"""

from __future__ import annotations

import plistlib
import struct
from typing import Any


def extract_text(blob: bytes) -> str | None:
    """Extract the plain-text string from an attributedBody blob.

    Returns ``None`` if the blob is empty, malformed, or contains no text.
    """
    if not blob:
        return None

    # The blob is either raw bplist data or a typedstream.
    # Modern macOS (Ventura+) uses NSKeyedArchiver bplist format.
    # Older macOS used the legacy typedstream format.
    if blob[:6] == b"bplist":
        return _from_bplist(blob)

    # Legacy typedstream: simpler binary format — scan for UTF-8 runs
    return _from_typedstream(blob)


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
