"""Unit tests for epoch conversion."""

import pytest
from imessage_archiver.db.epoch import apple_to_unix, unix_to_apple, unix_to_apple_ns, APPLE_EPOCH_OFFSET


class TestAppleToUnix:
    def test_zero_is_apple_epoch(self) -> None:
        assert apple_to_unix(0) == APPLE_EPOCH_OFFSET

    def test_known_date_seconds(self) -> None:
        # 2026-01-01 00:00:00 UTC = Unix 1767225600
        # Apple seconds = 1767225600 - 978307200 = 788918400
        assert apple_to_unix(788918400) == 1767225600

    def test_nanoseconds_detection(self) -> None:
        # Nanosecond value for 2026-01-01 00:00:00 UTC
        ns = 788918400 * 1_000_000_000
        assert apple_to_unix(ns) == 1767225600

    def test_value_below_threshold_treated_as_seconds(self) -> None:
        # Apple seconds for year 2026 ≈ 7.89×10^8, well below 10^13
        apple_secs = 788_918_400
        assert apple_to_unix(apple_secs) == apple_secs + APPLE_EPOCH_OFFSET

    def test_value_at_threshold_treated_as_nanoseconds(self) -> None:
        # 10^13 ns ÷ 10^9 = 10^4 Apple seconds (just after Apple epoch)
        at = 10 ** 13
        expected = at // 1_000_000_000 + APPLE_EPOCH_OFFSET
        assert apple_to_unix(at) == expected


class TestUnixToApple:
    def test_round_trip(self) -> None:
        unix = 1716800000
        assert apple_to_unix(unix_to_apple(unix)) == unix

    def test_known_value(self) -> None:
        assert unix_to_apple(APPLE_EPOCH_OFFSET) == 0


class TestUnixToAppleNs:
    def test_known_value(self) -> None:
        # APPLE_EPOCH_OFFSET Unix seconds → 0 Apple nanoseconds
        assert unix_to_apple_ns(float(APPLE_EPOCH_OFFSET)) == 0

    def test_one_second_after(self) -> None:
        assert unix_to_apple_ns(float(APPLE_EPOCH_OFFSET) + 1.0) == 1_000_000_000
