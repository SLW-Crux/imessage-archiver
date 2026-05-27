"""Apple Epoch ↔ Unix timestamp conversion."""

from __future__ import annotations

APPLE_EPOCH_OFFSET: int = 978307200  # 2001-01-01 00:00:00 UTC as Unix epoch
# Apple seconds for dates through 2100 top out at ~3.1×10^9.
# Apple nanoseconds for any message after 2001-01-02 are ≥8.64×10^13.
# A threshold of 10^13 cleanly separates the two formats for all real iMessages.
_NS_THRESHOLD: int = 10_000_000_000_000  # 10^13


def apple_to_unix(value: int) -> int:
    """Convert an Apple chat.db date value to a Unix epoch (seconds).

    chat.db stores dates as seconds since 2001-01-01 (Apple epoch).
    macOS 10.13+ (High Sierra) and later store nanoseconds instead.
    We detect nanoseconds by magnitude: any value >= 10^18 is nanoseconds.
    """
    if value >= _NS_THRESHOLD:
        return value // 1_000_000_000 + APPLE_EPOCH_OFFSET
    return value + APPLE_EPOCH_OFFSET


def unix_to_apple(unix: int) -> int:
    """Convert a Unix epoch (seconds) to Apple epoch seconds."""
    return unix - APPLE_EPOCH_OFFSET


def unix_to_apple_ns(unix: float) -> int:
    """Convert a Unix epoch (float seconds) to Apple epoch nanoseconds."""
    return int((unix - APPLE_EPOCH_OFFSET) * 1_000_000_000)
