"""Archive controls panel — destination picker, progress, post-archive actions."""

from __future__ import annotations

import datetime
import subprocess
from pathlib import Path

from PySide6.QtCore import Signal
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
from imessage_archiver.gui.workers import ArchiveWorker

# Must mirror cli.commands._DEFAULT_DEST. The iOS reader's NSMetadataQuery
# only sees files under its own ubiquity container Documents/ folder, so the
# Mac archiver writes there (not generic iCloud Drive).
_IOS_BUNDLE_ID = "com.slw.imessage-archiver"
_ICLOUD_CONTAINER = f"iCloud~{_IOS_BUNDLE_ID.replace('.', '~')}"
_DEFAULT_DEST = (
    Path.home() / "Library" / "Mobile Documents" / _ICLOUD_CONTAINER / "Documents" / "archive.imarchive"
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
        self._post_group = QGroupBox("Next steps — set up the yearly workflow")
        post_layout = QVBoxLayout(self._post_group)

        intro = QLabel(
            "Your messages are now safely archived. "
            "To keep your Mac fast, enable Messages → Keep Messages: 1 Year, "
            "then set a yearly reminder to re-run this archiver."
        )
        intro.setWordWrap(True)
        intro.setStyleSheet("color: gray;")
        post_layout.addWidget(intro)

        cal_btn = QPushButton("Add Yearly Reminder to Calendar")
        cal_btn.clicked.connect(self._add_calendar_reminder)
        post_layout.addWidget(cal_btn)

        messages_btn = QPushButton("Open Messages Settings…")
        messages_btn.clicked.connect(self._open_messages_settings)
        post_layout.addWidget(messages_btn)

        self._post_group.hide()
        layout.addWidget(self._post_group)

    def _browse_dest(self) -> None:
        path = QFileDialog.getExistingDirectory(self, "Select Archive Destination", str(_DEFAULT_DEST.parent))
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
            f"Done — {stats.messages_seen:,} messages, " f"{stats.attachments_written:,} new attachments"
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
                self, "Reminder Added", "A yearly iMessage archive reminder has been added to your Calendar."
            )
        except Exception as e:
            QMessageBox.warning(
                self,
                "Calendar",
                f"Could not add reminder automatically: {e}\n\n"
                "Please add a yearly reminder manually to your Calendar.",
            )

    def _open_messages_settings(self) -> None:
        subprocess.Popen(["open", "x-apple.systempreferences:com.apple.Messages-Settings.extension"])


_REMINDER_TITLE = "Archive iMessages (yearly)"
_REMINDER_NOTES = (
    "Run iMessage Archiver to capture this year's conversations and "
    "attachments before they age out of the 1-year Keep Messages window. "
    "App: https://github.com/SLW-Crux/imessage-archiver"
)
_REMINDER_HOUR = 10  # 10am local time — sensible default, not "right now"


def _next_year_same_day(now: datetime.datetime) -> datetime.datetime:
    """Return ``now`` shifted one year forward, snapped to 10am.

    Handles the Feb 29 → Feb 28 edge case (a Feb 29 reminder on a non-leap
    year falls back to Feb 28; the EKRecurrenceRule then handles future
    instances per Apple's standard yearly recurrence rules).
    """
    target_year = now.year + 1
    try:
        return now.replace(year=target_year, hour=_REMINDER_HOUR, minute=0, second=0, microsecond=0)
    except ValueError:
        # Feb 29 in a leap year → snap to Feb 28 next year
        return now.replace(
            year=target_year,
            month=2,
            day=28,
            hour=_REMINDER_HOUR,
            minute=0,
            second=0,
            microsecond=0,
        )


def _add_eventkit_reminder() -> None:
    """Add a yearly archive reminder via EventKit (PyObjC)."""
    try:
        import EventKit  # type: ignore[import]
    except ImportError:
        raise ImportError("EventKit framework not available (PyObjC required)")

    store = EventKit.EKEventStore.alloc().init()

    granted = [False]
    error_box = [None]

    def handler(g, e):
        granted[0] = g
        error_box[0] = e

    store.requestAccessToEntityType_completion_(EventKit.EKEntityTypeEvent, handler)

    if not granted[0]:
        raise PermissionError("Calendar access not granted")

    calendar = store.defaultCalendarForNewEvents()
    event = EventKit.EKEvent.eventWithEventStore_(store)
    event.setTitle_(_REMINDER_TITLE)
    event.setNotes_(_REMINDER_NOTES)

    start = _next_year_same_day(datetime.datetime.now())
    event.setStartDate_(start)
    event.setEndDate_(start + datetime.timedelta(minutes=30))
    event.setCalendar_(calendar)

    rule = EventKit.EKRecurrenceRule.alloc().initRecurrenceWithFrequency_interval_end_(
        EventKit.EKRecurrenceFrequencyYearly, 1, None
    )
    event.setRecurrenceRules_([rule])

    success, err = store.saveEvent_span_commit_error_(event, EventKit.EKSpanThisEvent, True, None)
    if not success:
        raise RuntimeError(f"Could not save event: {err}")
