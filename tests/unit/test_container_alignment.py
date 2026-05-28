"""Sanity test: the Mac archiver default destination must live inside the
iOS app's iCloud ubiquity container so the iOS NSMetadataQuery (which only
sees its own container's Documents folder) can discover the bundle.

If the bundle ID changes in one place and not the other, this test fails.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

# Set Qt platform before importing the GUI module.
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from imessage_archiver.cli.commands import (  # noqa: E402
    _DEFAULT_DEST as CLI_DEFAULT_DEST,
)
from imessage_archiver.cli.commands import (
    _ICLOUD_CONTAINER as CLI_CONTAINER,
)
from imessage_archiver.cli.commands import (
    _IOS_BUNDLE_ID as CLI_BUNDLE_ID,
)
from imessage_archiver.gui.archive_panel import (  # noqa: E402
    _DEFAULT_DEST as GUI_DEFAULT_DEST,
)
from imessage_archiver.gui.archive_panel import (
    _ICLOUD_CONTAINER as GUI_CONTAINER,
)
from imessage_archiver.gui.archive_panel import (
    _IOS_BUNDLE_ID as GUI_BUNDLE_ID,
)

# The iOS app's hardcoded bundle ID (see ios/project.yml and
# ios/Sources/Persistence/iCloudCoordinator.swift `kContainerID`).
EXPECTED_IOS_BUNDLE_ID = "com.slw.imessage-archiver"
EXPECTED_CONTAINER_DIR = "iCloud~com~slw~imessage-archiver"


def test_cli_default_dest_is_inside_ios_ubiquity_container() -> None:
    parts = CLI_DEFAULT_DEST.parts
    assert EXPECTED_CONTAINER_DIR in parts, (
        f"CLI default destination must include {EXPECTED_CONTAINER_DIR}; " f"got {CLI_DEFAULT_DEST}"
    )
    # And it must be under that container's Documents/ folder so the iOS
    # NSMetadataQueryUbiquitousDocumentsScope query can find it.
    idx = parts.index(EXPECTED_CONTAINER_DIR)
    assert parts[idx + 1] == "Documents", (
        f"Bundle must live under {EXPECTED_CONTAINER_DIR}/Documents; " f"got {CLI_DEFAULT_DEST}"
    )


def test_gui_default_dest_matches_cli() -> None:
    assert GUI_DEFAULT_DEST == CLI_DEFAULT_DEST, (
        "GUI and CLI must agree on the default destination; "
        f"GUI={GUI_DEFAULT_DEST}, CLI={CLI_DEFAULT_DEST}"
    )


def test_bundle_id_consistent_across_modules() -> None:
    assert CLI_BUNDLE_ID == GUI_BUNDLE_ID == EXPECTED_IOS_BUNDLE_ID
    assert CLI_CONTAINER == GUI_CONTAINER == EXPECTED_CONTAINER_DIR


def test_ios_project_yml_uses_same_container_id() -> None:
    repo_root = Path(__file__).parent.parent.parent
    project_yml = repo_root / "ios" / "project.yml"
    text = project_yml.read_text()
    # The iCloud capability declares the container with `iCloud.` prefix.
    assert (
        f"iCloud.{EXPECTED_IOS_BUNDLE_ID}" in text
    ), f"ios/project.yml must declare iCloud.{EXPECTED_IOS_BUNDLE_ID} as its container"


def test_ios_entitlements_uses_same_container_id() -> None:
    repo_root = Path(__file__).parent.parent.parent
    ent = repo_root / "ios" / "iMessageArchiver.entitlements"
    text = ent.read_text()
    assert f"iCloud.{EXPECTED_IOS_BUNDLE_ID}" in text


def test_ios_coordinator_uses_same_container_id() -> None:
    repo_root = Path(__file__).parent.parent.parent
    coord = repo_root / "ios" / "Sources" / "Persistence" / "iCloudCoordinator.swift"
    text = coord.read_text()
    # Look for kContainerID literal.
    match = re.search(r'kContainerID\s*=\s*"([^"]+)"', text)
    assert match, "iCloudCoordinator.swift must define kContainerID"
    assert match.group(1) == f"iCloud.{EXPECTED_IOS_BUNDLE_ID}", (
        f"kContainerID = {match.group(1)!r}, " f"expected iCloud.{EXPECTED_IOS_BUNDLE_ID!r}"
    )
