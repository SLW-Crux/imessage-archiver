"""Full Disk Access setup screen shown when chat.db is inaccessible."""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

_FDA_INSTRUCTIONS = """
<h2>Full Disk Access Required</h2>
<p>iMessage Archiver needs <b>Full Disk Access</b> to read your messages.</p>
<ol>
  <li>Open <b>System Settings</b></li>
  <li>Go to <b>Privacy &amp; Security → Full Disk Access</b></li>
  <li>Click the lock and authenticate</li>
  <li>Toggle on <b>Terminal</b> (or your current app)</li>
  <li>Click <b>Check Again</b> below</li>
</ol>
"""

_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"


class SetupScreen(QWidget):
    """Shown in place of the main window when FDA is not granted."""

    access_granted = Signal()

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._build_ui()

    def _build_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignCenter)
        layout.setSpacing(16)
        layout.setContentsMargins(48, 48, 48, 48)

        label = QLabel(_FDA_INSTRUCTIONS)
        label.setWordWrap(True)
        label.setTextFormat(Qt.RichText)
        label.setAlignment(Qt.AlignLeft)
        layout.addWidget(label)

        open_btn = QPushButton("Open Privacy Settings")
        open_btn.clicked.connect(self._open_privacy_settings)
        layout.addWidget(open_btn)

        check_btn = QPushButton("Check Again")
        check_btn.setDefault(True)
        check_btn.clicked.connect(self._check_again)
        layout.addWidget(check_btn)

    def _open_privacy_settings(self) -> None:
        QDesktopServices.openUrl(
            QUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        )

    def _check_again(self) -> None:
        if _has_full_disk_access():
            self.access_granted.emit()


def _has_full_disk_access() -> bool:
    """Return True if chat.db is accessible.

    On Macs where Messages is not configured at all, chat.db does not
    exist — that's a different situation from FDA-denied. Both currently
    fall through this False return; callers can use :func:`fda_state`
    to distinguish them.
    """
    return fda_state() == "ok"


def fda_state() -> str:
    """Distinguish 'ok' / 'denied' / 'missing' for Full Disk Access.

    - ``"ok"``: chat.db opens for reading.
    - ``"denied"``: chat.db exists but cannot be read (FDA not granted).
    - ``"missing"``: chat.db doesn't exist (Messages not configured).
    """
    import os

    try:
        # os.stat tells PermissionError from FileNotFoundError reliably.
        os.stat(_CHAT_DB)
    except FileNotFoundError:
        return "missing"
    except PermissionError:
        return "denied"
    except OSError:
        return "denied"

    try:
        _CHAT_DB.open("rb").close()
        return "ok"
    except PermissionError:
        return "denied"
    except OSError:
        return "denied"
