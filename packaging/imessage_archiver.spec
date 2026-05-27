# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for iMessage Archiver macOS .app bundle."""

import sys
from pathlib import Path

ROOT = Path(SPECPATH).parent  # repo root

block_cipher = None

a = Analysis(
    [str(ROOT / "src" / "imessage_archiver" / "gui" / "app.py")],
    pathex=[str(ROOT / "src")],
    binaries=[],
    datas=[
        (str(ROOT / "assets"), "assets"),
    ],
    hiddenimports=[
        # PySide6 plugins needed at runtime
        "PySide6.QtCore",
        "PySide6.QtGui",
        "PySide6.QtWidgets",
        # PyObjC frameworks used optionally
        "Foundation",
        "Contacts",
        "EventKit",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="iMessage Archiver",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    target_arch="arm64",
    codesign_identity=None,
    entitlements_file=None,
    icon=str(ROOT / "assets" / "AppIcon.icns") if (ROOT / "assets" / "AppIcon.icns").exists() else None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="iMessage Archiver",
)

app = BUNDLE(
    coll,
    name="iMessage Archiver.app",
    icon=str(ROOT / "assets" / "AppIcon.icns") if (ROOT / "assets" / "AppIcon.icns").exists() else None,
    bundle_identifier="org.imessagearchiver.mac",
    version="0.4.0",
    info_plist={
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "13.0",
        "NSHumanReadableCopyright": "© 2026 iMessage Archiver. MIT License.",
        # FDA usage description
        "NSSystemAdministrationUsageDescription": (
            "iMessage Archiver needs Full Disk Access to read your messages database."
        ),
        "NSCalendarsUsageDescription": (
            "iMessage Archiver can add a yearly archive reminder to your Calendar."
        ),
        "NSContactsUsageDescription": (
            "iMessage Archiver uses your Contacts to display sender names."
        ),
    },
)
