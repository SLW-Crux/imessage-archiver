"""Archive controls panel — destination picker, progress, post-archive actions."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QFileDialog,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from imessage_archiver.core.archive import RunStats
from imessage_archiver.db.reader import ChatRow
from imessage_archiver.gui.workers import ArchiveWorker

_DEFAULT_DEST = (
    Path.home()
    / "Library"
    / "Mobile Documents"
    / "com~apple~CloudDocs"
    / "iMessage Archive"
    / "archive.imarchive"
)
_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"


class ArchivePanel(QWidget):
    """Right-side panel with archive destination, progress, and controls."""

    archive_completed = Signal(object)  # RunStats

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._worker: ArchiveWorker | None = None
        self._build_ui()

    def _build_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setSpacing(12)
        layout.setContentsMargins(12, 12, 12, 12)

        # --- Destination ---
        dest_group = QGroupBox("Archive Destination")
        dest_layout = QHBoxLayout(dest_group)
        self._dest_edit = QLineEdit(str(_DEFAULT_DEST))
        browse_btn = QPushButton("Browse…")
        browse_btn.clicked.connect(self._browse_dest)
        dest_layout.addWidget(self._dest_edit, 1)
        dest_layout.addWidget(browse_btn)
        layout.addWidget(dest_group)

        # --- Progress ---
        self._status_label = QLabel("Ready")
        layout.addWidget(self._status_label)

        self._progress = QProgressBar()
        self._progress.setRange(0, 100)
        self._progress.setTextVisible(True)
        self._progress.hide()
        layout.addWidget(self._progress)

        # --- Archive button ---
        self._archive_btn = QPushButton("Archive All Messages")
        self._archive_btn.setDefault(True)
        self._archive_btn.clicked.connect(self._start_archive)
        layout.addWidget(self._archive_btn)

        layout.addStretch()

        # --- Post-archive actions ---
        self._post_group = QGroupBox("After Archiving")
        post_layout = QVBoxLayout(self._post_group)

        cal_btn = QPushButton("Add Yearly Reminder to Calendar")
        cal_btn.clicked.connect(self._add_calendar_reminder)
        post_layout.addWidget(cal_btn)

        messages_btn = QPushButton("Open Messages Settings (Enable 1-Year Limit)")
        messages_btn.clicked.connect(self._open_messages_settings)
        post_layout.addWidget(messages_btn)

        self._post_group.hide()
        layout.addWidget(self._post_group)

    def _browse_dest(self) -> None:
        path = QFileDialog.getExistingDirectory(
            self, "Select Archive Destination", str(_DEFAULT_DEST.parent)
        )
        if path:
            self._dest_edit.setText(str(Path(path) / "archive.imarchive"))

    def _start_archive(self) -> None:
        if self._worker and self._worker.isRunning():
            return

        dest = Path(self._dest_edit.text())
        self._archive_btn.setEnabled(False)
        self._progress.show()
        self._progress.setValue(0)
        self._status_label.setText("Starting…")

        self._worker = ArchiveWorker(source_db=_CHAT_DB, bundle_path=dest)
        self._worker.progress.connect(self._on_progress)
        self._worker.finished.connect(self._on_finished)
        self._worker.error.connect(self._on_error)
        self._worker.start()

    def _on_progress(self, description: str, completed: int, total: int) -> None:
        self._status_label.setText(f"Archiving: {description}")
        if total > 0:
            self._progress.setValue(int(completed / total * 100))

    def _on_finished(self, stats: RunStats) -> None:
        self._archive_btn.setEnabled(True)
        self._progress.hide()
        self._status_label.setText(
            f"Done — {stats.messages_seen:,} messages, "
            f"{stats.attachments_written:,} new attachments"
        )
        self._post_group.show()
        self.archive_completed.emit(stats)

    def _on_error(self, message: str) -> None:
        self._archive_btn.setEnabled(True)
        self._progress.hide()
        self._status_label.setText(f"Error: {message}")
        QMessageBox.critical(self, "Archive Error", message)

    def _add_calendar_reminder(self) -> None:
        """Add a yearly archive reminder via EventKit (PyObjC) or AppleScript fallback."""
        try:
            _add_eventkit_reminder()
            QMessageBox.information(
                self, "Reminder Added",
                "A yearly iMessage archive reminder has been added to your Calendar."
            )
        except Exception as e:
            QMessageBox.warning(
                self, "Calendar",
                f"Could not add reminder automatically: {e}\n\n"
                "Please add a yearly reminder manually to your Calendar."
            )

    def _open_messages_settings(self) -> None:
        subprocess.Popen([
            "open",
            "x-apple.systempreferences:com.apple.Messages-Settings.extension"
        ])


def _add_eventkit_reminder() -> None:
    """Add a yearly 'Archive iMessages' reminder using EventKit via PyObjC."""
    import datetime
    try:
        import EventKit  # type: ignore[import]
    except ImportError:
        raise ImportError("EventKit framework not available (PyObjC required)")

    store = EventKit.EKEventStore.alloc().init()

    # Request calendar access (synchronous in older macOS; async in newer)
    granted = [False]
    error_box = [None]

    def handler(g, e):
        granted[0] = g
        error_box[0] = e

    store.requestAccessToEntityType_completion_(
        EventKit.EKEntityTypeEvent, handler
    )

    if not granted[0]:
        raise PermissionError("Calendar access not granted")

    calendar = store.defaultCalendarForNewEvents()
    event = EventKit.EKEvent.eventWithEventStore_(store)
    event.setTitle_("Archive iMessages")
    now = datetime.datetime.now()
    next_year = now.replace(year=now.year + 1)
    event.setStartDate_(next_year)
    event.setEndDate_(next_year + datetime.timedelta(hours=1))
    event.setCalendar_(calendar)

    rule = EventKit.EKRecurrenceRule.alloc().initRecurrenceWithFrequency_interval_end_(
        EventKit.EKRecurrenceFrequencyYearly, 1, None
    )
    event.setRecurrenceRules_([rule])

    success, err = store.saveEvent_span_commit_error_(
        event, EventKit.EKSpanThisEvent, True, None
    )
    if not success:
        raise RuntimeError(f"Could not save event: {err}")
