"""Unit tests for schema constants and tapback helpers."""

from imessage_archiver.db.schema import (
    is_tapback,
    tapback_base_type,
    tapback_is_remove,
    TAPBACK_TYPE_NAMES,
)


def test_regular_message_not_tapback() -> None:
    assert not is_tapback(0)


def test_tapback_add_range() -> None:
    for t in range(2000, 2006):
        assert is_tapback(t)


def test_tapback_remove_range() -> None:
    for t in range(3000, 3006):
        assert is_tapback(t)


def test_outside_range_not_tapback() -> None:
    assert not is_tapback(1999)
    assert not is_tapback(2006)
    assert not is_tapback(2999)
    assert not is_tapback(3006)


def test_tapback_base_type_add() -> None:
    assert tapback_base_type(2000) == 2000
    assert tapback_base_type(2003) == 2003


def test_tapback_base_type_remove() -> None:
    assert tapback_base_type(3000) == 2000
    assert tapback_base_type(3005) == 2005


def test_tapback_is_remove() -> None:
    assert tapback_is_remove(3000)
    assert not tapback_is_remove(2000)
    assert not tapback_is_remove(0)


def test_tapback_type_names_complete() -> None:
    for t in range(2000, 2006):
        assert t in TAPBACK_TYPE_NAMES
        assert TAPBACK_TYPE_NAMES[t]  # non-empty string
