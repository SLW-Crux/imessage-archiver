"""Handle → display-name resolution via Contacts.framework (PyObjC).

Falls back gracefully to the raw handle string when:
- Contacts.framework is not available (non-macOS, CI)
- The user has not granted Contacts access
- No matching contact is found
"""

from __future__ import annotations

import functools
import re

_contacts_available: bool | None = None
_CNContactStore: object | None = None


def _init_contacts() -> bool:
    """Attempt to import PyObjC Contacts bindings. Cache the result."""
    global _contacts_available, _CNContactStore
    if _contacts_available is not None:
        return _contacts_available
    try:
        import Contacts  # type: ignore[import]

        _CNContactStore = Contacts.CNContactStore
        _contacts_available = True
    except ImportError:
        _contacts_available = False
    return _contacts_available


@functools.lru_cache(maxsize=2048)
def resolve(handle: str) -> str:
    """Return the display name for *handle*, or *handle* itself if not found.

    *handle* is a phone number (E.164 or local) or email address.
    Results are cached for the process lifetime.
    """
    if not handle:
        return handle

    if not _init_contacts():
        return handle

    try:
        return _query_contacts(handle)
    except Exception:
        return handle


def _query_contacts(handle: str) -> str:
    """Query CNContactStore for a matching contact name."""
    import Contacts  # type: ignore[import]

    store = Contacts.CNContactStore.alloc().init()
    keys = [
        Contacts.CNContactGivenNameKey,
        Contacts.CNContactFamilyNameKey,
        Contacts.CNContactPhoneNumbersKey,
        Contacts.CNContactEmailAddressesKey,
    ]

    if "@" in handle:
        predicate = Contacts.CNContact.predicateForContactsMatchingEmailAddress_(handle)
    else:
        # Normalise the phone number for matching
        phone = Contacts.CNPhoneNumber.phoneNumberWithStringValue_(handle)
        predicate = Contacts.CNContact.predicateForContactsMatchingPhoneNumber_(phone)

    contacts, error = store.unifiedContactsMatchingPredicate_keysToFetch_error_(
        predicate, keys, None
    )
    if error or not contacts:
        return handle

    contact = contacts[0]
    given = contact.givenName() or ""
    family = contact.familyName() or ""
    name = f"{given} {family}".strip()
    return name if name else handle


def clear_cache() -> None:
    """Clear the LRU cache (useful for testing)."""
    resolve.cache_clear()
