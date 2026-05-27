"""PySide6 GUI application entry point."""

from __future__ import annotations

import sys

from PySide6.QtWidgets import QApplication

from imessage_archiver import __version__
from imessage_archiver.gui.main_window import MainWindow


def main() -> None:
    """Launch the iMessage Archiver GUI."""
    app = QApplication(sys.argv)
    app.setApplicationName("iMessage Archiver")
    app.setApplicationVersion(__version__)
    app.setOrganizationName("iMessage Archiver")
    app.setOrganizationDomain("org.imessagearchiver")

    window = MainWindow()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
