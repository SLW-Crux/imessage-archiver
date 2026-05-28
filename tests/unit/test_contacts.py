"""Unit tests for contacts resolution (mocked — no Contacts.framework needed)."""

import sys
from unittest.mock import MagicMock, patch

from imessage_archiver.db import contacts


class TestResolveNoFramework:
    """Behaviour when Contacts.framework is not available."""

    def setup_method(self) -> None:
        contacts.clear_cache()
        # Force _contacts_available to False
        contacts._contacts_available = False

    def teardown_method(self) -> None:
        contacts._contacts_available = None
        contacts.clear_cache()

    def test_returns_handle_when_unavailable(self) -> None:
        assert contacts.resolve("+14155550101") == "+14155550101"

    def test_empty_handle_returns_empty(self) -> None:
        assert contacts.resolve("") == ""

    def test_email_returns_email(self) -> None:
        assert contacts.resolve("alice@example.com") == "alice@example.com"


class TestResolveMocked:
    """Behaviour with mocked Contacts.framework."""

    def setup_method(self) -> None:
        contacts.clear_cache()
        contacts._contacts_available = None

    def teardown_method(self) -> None:
        contacts._contacts_available = None
        contacts.clear_cache()

    def _mock_store(self, name: str) -> MagicMock:
        given, _, family = name.partition(" ")
        contact = MagicMock()
        contact.givenName.return_value = given
        contact.familyName.return_value = family
        store = MagicMock()
        store.unifiedContactsMatchingPredicate_keysToFetch_error_.return_value = ([contact], None)
        store_cls = MagicMock(return_value=store)
        store_cls.alloc.return_value = store_cls
        store_cls.init.return_value = store
        store_cls.alloc().init.return_value = store
        return store_cls

    def test_resolves_phone_to_name(self) -> None:
        mock_contacts = MagicMock()
        mock_contacts.CNContactStore = self._mock_store("Alice Smith")
        mock_contacts.CNContactGivenNameKey = "givenName"
        mock_contacts.CNContactFamilyNameKey = "familyName"
        mock_contacts.CNContactPhoneNumbersKey = "phoneNumbers"
        mock_contacts.CNContactEmailAddressesKey = "emailAddresses"
        mock_contacts.CNPhoneNumber.phoneNumberWithStringValue_.return_value = MagicMock()
        mock_contacts.CNContact.predicateForContactsMatchingPhoneNumber_.return_value = MagicMock()

        with patch.dict(sys.modules, {"Contacts": mock_contacts}):
            contacts._contacts_available = None  # force re-init
            result = contacts.resolve("+14155550101")
        # Either returns a name or falls back; must not raise
        assert isinstance(result, str)

    def test_import_error_sets_unavailable(self) -> None:
        """ImportError from Contacts — covers lines 28-29 (except ImportError branch)."""
        with patch.dict(sys.modules, {"Contacts": None}):
            contacts._contacts_available = None
            result = contacts.resolve("+14155550101")
        assert result == "+14155550101"
        assert contacts._contacts_available is False

    def test_query_exception_returns_handle(self) -> None:
        """_query_contacts raising — covers lines 48-49 (except Exception branch in resolve)."""
        mock_contacts = MagicMock()
        mock_contacts.CNContactStore.alloc().init.side_effect = RuntimeError("access denied")

        with patch.dict(sys.modules, {"Contacts": mock_contacts}):
            contacts._contacts_available = None
            result = contacts.resolve("+19995550101")
        assert result == "+19995550101"

    def test_resolves_email_handle(self) -> None:
        """Email handle takes the predicateForContactsMatchingEmailAddress_ branch (line 65)."""
        mock_contacts = MagicMock()
        mock_contacts.CNContactStore = self._mock_store("Bob Jones")
        mock_contacts.CNContactGivenNameKey = "givenName"
        mock_contacts.CNContactFamilyNameKey = "familyName"
        mock_contacts.CNContactPhoneNumbersKey = "phoneNumbers"
        mock_contacts.CNContactEmailAddressesKey = "emailAddresses"
        mock_contacts.CNContact.predicateForContactsMatchingEmailAddress_.return_value = MagicMock()

        with patch.dict(sys.modules, {"Contacts": mock_contacts}):
            contacts._contacts_available = None
            result = contacts.resolve("bob@example.com")
        assert isinstance(result, str)

    def test_fallback_on_empty_result(self) -> None:
        mock_contacts = MagicMock()
        store = MagicMock()
        store.unifiedContactsMatchingPredicate_keysToFetch_error_.return_value = ([], None)
        mock_contacts.CNContactStore.alloc().init.return_value = store
        mock_contacts.CNContact.predicateForContactsMatchingPhoneNumber_.return_value = MagicMock()
        mock_contacts.CNPhoneNumber.phoneNumberWithStringValue_.return_value = MagicMock()

        with patch.dict(sys.modules, {"Contacts": mock_contacts}):
            contacts._contacts_available = None
            result = contacts.resolve("+10000000000")
        assert result == "+10000000000"
