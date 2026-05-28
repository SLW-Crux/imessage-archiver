"""Tests for archive_panel helpers (calendar reminder date calculation)."""

from __future__ import annotations

import datetime
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from imessage_archiver.gui.archive_panel import _next_year_same_day, _REMINDER_HOUR


class TestNextYearSameDay:
    def test_basic_shift(self):
        now = datetime.datetime(2026, 5, 28, 15, 30)
        result = _next_year_same_day(now)
        assert result.year == 2027
        assert result.month == 5
        assert result.day == 28
        assert result.hour == _REMINDER_HOUR
        assert result.minute == 0
        assert result.second == 0
        assert result.microsecond == 0

    def test_leap_day_falls_back_to_feb_28(self):
        # Feb 29 2024 is a Wednesday; 2025 is not a leap year.
        now = datetime.datetime(2024, 2, 29, 9, 0)
        result = _next_year_same_day(now)
        assert result.year == 2025
        assert result.month == 2
        assert result.day == 28
        assert result.hour == _REMINDER_HOUR

    def test_dec_31_rollover(self):
        now = datetime.datetime(2026, 12, 31, 23, 59)
        result = _next_year_same_day(now)
        assert result.year == 2027
        assert result.month == 12
        assert result.day == 31

    def test_time_normalised_regardless_of_input(self):
        # Input at 11:59pm, output should snap to 10:00am.
        now = datetime.datetime(2026, 6, 15, 23, 59, 59, 999_999)
        result = _next_year_same_day(now)
        assert result.hour == _REMINDER_HOUR
        assert (result.minute, result.second, result.microsecond) == (0, 0, 0)

    def test_jan_1_works(self):
        now = datetime.datetime(2026, 1, 1, 0, 0)
        result = _next_year_same_day(now)
        assert result == datetime.datetime(2027, 1, 1, _REMINDER_HOUR, 0)
