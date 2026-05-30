"""Force-fetch cloud-only iMessage attachments by driving Messages.app
via AppleScript / UI scripting.

This is **experimental** and **brittle**:

- Requires the user to grant Accessibility AND AppleEvents permission
  to the controlling app (Terminal / your IDE).
- Depends on the Messages.app UI layout (chat list sidebar, message
  area) staying compatible. Apple changes this between macOS versions.
- Triggers attachment downloads by sending Cmd-Home (scroll to top of
  conversation), which makes Messages.app fetch attachments that
  appear on screen. There's no public "fetch all" API.

Strategy:

1. Activate Messages.app.
2. Use System Events to access the conversation sidebar (a list).
3. For each conversation row:
   a. Click / select the row.
   b. Wait briefly for the message area to populate.
   c. Send Cmd-Home (or Page Up repeatedly) to scroll to the top —
      this is what triggers CloudKit fetches of historical attachments.
   d. Sleep long enough for the network fetches to complete.
4. Report a count of conversations processed and let the caller decide
   whether to wait longer or re-run the archive.

This is a best-effort utility. If the AppleScript fails (permissions
not granted, Messages.app not installed, layout changed), it raises a
:exc:`PrefetchError` with a description. Callers should catch and
fall back to instructing the user to use System Settings manually.
"""

from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass


class PrefetchError(Exception):
    """Raised when AppleScript-based prefetching fails for any reason."""


@dataclass
class PrefetchResult:
    conversations_visited: int
    elapsed_seconds: float
    aborted: bool = False


def osascript(script: str, timeout_s: float = 30.0) -> str:
    """Run *script* via /usr/bin/osascript. Raise PrefetchError on failure."""
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as exc:
        raise PrefetchError(f"AppleScript timed out after {timeout_s}s") from exc
    if result.returncode != 0:
        raise PrefetchError(f"AppleScript failed (exit {result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def check_messages_app_available() -> None:
    """Raise PrefetchError if Messages.app is not installed or scriptable."""
    out = osascript(
        'tell application "System Events" to get exists application process "Messages"',
        timeout_s=10.0,
    )
    if out.lower() == "true":
        return
    # Try launching it
    osascript('tell application "Messages" to activate', timeout_s=10.0)
    # Wait for it to come up
    for _ in range(20):
        time.sleep(0.5)
        out = osascript(
            'tell application "System Events" to get exists application process "Messages"',
            timeout_s=5.0,
        )
        if out.lower() == "true":
            return
    raise PrefetchError(
        "Could not activate Messages.app. Is it installed? "
        "Have you granted Accessibility permission to Terminal in System Settings?"
    )


def count_conversations() -> int:
    """Return the number of conversation rows in Messages.app's sidebar.

    Raises PrefetchError if the UI scripting can't see the sidebar (e.g.
    Accessibility not granted, layout changed, or Messages.app not focused).
    """
    script = """
    tell application "System Events"
      tell process "Messages"
        set theWindow to first window
        set theList to first table of first scroll area of theWindow
        return count of rows of theList
      end tell
    end tell
    """
    out = osascript(script, timeout_s=15.0)
    try:
        return int(out)
    except ValueError as exc:
        raise PrefetchError(f"Could not read conversation count from Messages.app sidebar: {out!r}") from exc


def prefetch_conversation(index: int, scroll_wait_s: float = 3.0) -> None:
    """Select conversation at *index* (1-based) and trigger an attachment fetch.

    Sends Cmd-Home to scroll to the top of the conversation, which
    causes Messages.app to fetch attachments that come into view from
    CloudKit. Sleeps *scroll_wait_s* afterwards to let network fetches
    settle.
    """
    select_script = f"""
    tell application "System Events"
      tell process "Messages"
        tell first window
          tell first scroll area
            tell first table
              select row {index}
            end tell
          end tell
        end tell
      end tell
    end tell
    """
    osascript(select_script, timeout_s=10.0)

    # Brief pause so the message area renders
    time.sleep(0.5)

    scroll_script = """
    tell application "System Events"
      tell process "Messages"
        key code 115 using {command down}
      end tell
    end tell
    """
    # key code 115 = Home key; with cmd it's "scroll to top" in Messages
    osascript(scroll_script, timeout_s=10.0)

    # Wait for CloudKit fetches to complete
    time.sleep(scroll_wait_s)


def run(scroll_wait_s: float = 3.0, max_conversations: int | None = None) -> PrefetchResult:
    """Walk every conversation in Messages.app and trigger CloudKit fetches.

    Parameters
    ----------
    scroll_wait_s:
        How long to wait after scrolling each conversation. Longer = more
        downloads complete before moving on. Default 3s.
    max_conversations:
        Optional cap (mainly for testing or quick runs).

    Raises
    ------
    PrefetchError
        On any AppleScript failure — permissions, app missing, layout drift, etc.
    KeyboardInterrupt
        Propagated so a user Ctrl-C exits cleanly.
    """
    start = time.perf_counter()
    check_messages_app_available()
    n = count_conversations()
    if max_conversations is not None:
        n = min(n, max_conversations)
    if n == 0:
        return PrefetchResult(conversations_visited=0, elapsed_seconds=0.0)

    visited = 0
    aborted = False
    try:
        for i in range(1, n + 1):
            prefetch_conversation(i, scroll_wait_s=scroll_wait_s)
            visited = i
    except KeyboardInterrupt:
        aborted = True

    return PrefetchResult(
        conversations_visited=visited,
        elapsed_seconds=time.perf_counter() - start,
        aborted=aborted,
    )
