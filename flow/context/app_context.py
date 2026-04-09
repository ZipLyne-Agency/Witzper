"""Focused-app context via the Swift helper over XPC/Unix socket.

Falls back to AppleScript for app name/window title if the helper isn't running.
Surrounding-text extraction only works when the helper is running (needs
AXUIElement API with accessibility permissions).
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

import tomli

HELPER_SOCKET = Path(os.environ.get("FLOW_CONTEXT_SOCKET", "/tmp/flow-context.sock"))
APP_RULES_PATH = Path(__file__).resolve().parent.parent.parent / "configs" / "app_rules.toml"


@dataclass
class AppRule:
    match: str
    name: str
    asr_mode: str
    insertion: str
    tone: str


@dataclass
class AppContext:
    app_name: str
    bundle_id: str | None
    window_title: str | None
    surrounding_text: str | None
    selected_text: str | None
    rule: AppRule | None


class AppContextProvider:
    def __init__(self, rules_path: Path = APP_RULES_PATH):
        self._rules = self._load_rules(rules_path)

    def _load_rules(self, path: Path) -> list[AppRule]:
        if not path.exists():
            return []
        with path.open("rb") as f:
            data = tomli.load(f)
        return [AppRule(**r) for r in data.get("rule", [])]

    def _match_rule(self, app_name: str, bundle_id: str | None) -> AppRule | None:
        for rule in self._rules:
            if rule.match == "*":
                continue
            if bundle_id and rule.match == bundle_id:
                return rule
            if rule.match.lower() == app_name.lower():
                return rule
        for rule in self._rules:
            if rule.match == "*":
                return rule
        return None

    def snapshot(self) -> AppContext | None:
        if HELPER_SOCKET.exists():
            data = self._query_helper()
            if data:
                rule = self._match_rule(data.get("app_name", ""), data.get("bundle_id"))
                return AppContext(
                    app_name=data.get("app_name", ""),
                    bundle_id=data.get("bundle_id"),
                    window_title=data.get("window_title"),
                    surrounding_text=data.get("surrounding_text"),
                    selected_text=data.get("selected_text"),
                    rule=rule,
                )

        # Fallback: AppleScript — app name + window title only
        app_name = self._applescript_app_name()
        if not app_name:
            return None
        rule = self._match_rule(app_name, None)
        return AppContext(
            app_name=app_name,
            bundle_id=None,
            window_title=self._applescript_window_title(app_name),
            surrounding_text=None,
            selected_text=None,
            rule=rule,
        )

    def read_focused_text(self) -> str | None:
        """Return the full value of the currently focused text field, via
        the Swift helper. Used by the edit watcher to diff post-insertion
        edits. Returns None if the helper isn't running or the field
        doesn't expose AXValue.
        """
        if not HELPER_SOCKET.exists():
            return None
        try:
            import socket

            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.15)
            s.connect(str(HELPER_SOCKET))
            s.sendall(b'{"op":"read_focused_text"}\n')
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            s.close()
            obj = json.loads(data or b"{}")
            text = obj.get("text")
            return text if isinstance(text, str) else None
        except Exception:
            return None

    def _query_helper(self) -> dict | None:
        try:
            import socket

            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.1)
            s.connect(str(HELPER_SOCKET))
            s.sendall(b'{"op":"snapshot"}\n')
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            s.close()
            return json.loads(data)
        except Exception:
            return None

    @staticmethod
    def _applescript_app_name() -> str | None:
        try:
            out = subprocess.check_output(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to get name of first process whose frontmost is true',
                ],
                timeout=0.5,
            )
            return out.decode().strip() or None
        except Exception:
            return None

    @staticmethod
    def _applescript_window_title(app_name: str) -> str | None:
        try:
            out = subprocess.check_output(
                [
                    "osascript",
                    "-e",
                    f'tell application "System Events" to tell process "{app_name}" '
                    f"to get name of front window",
                ],
                timeout=0.5,
            )
            return out.decode().strip() or None
        except Exception:
            return None
