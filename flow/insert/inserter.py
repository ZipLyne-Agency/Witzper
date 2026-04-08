"""Text insertion — clipboard paste (default) or synthesized keystrokes."""

from __future__ import annotations

import subprocess
import threading
import time

import pyperclip

from flow.config import InsertionCfg


class Inserter:
    def __init__(self, cfg: InsertionCfg):
        self.cfg = cfg

    def insert(self, text: str, app_ctx=None) -> None:
        if not text:
            return
        strategy = self.cfg.default_strategy
        if app_ctx and app_ctx.rule:
            strategy = app_ctx.rule.insertion
        if strategy == "type":
            self._type(text)
        else:
            self._paste(text)

    # ------------------------------------------------------------------

    def _paste(self, text: str) -> None:
        old = ""
        try:
            old = pyperclip.paste()
        except Exception:
            pass
        pyperclip.copy(text)
        self._send_cmd_v()
        if old:
            threading.Timer(
                self.cfg.restore_clipboard_after_ms / 1000.0,
                lambda: self._safe_restore_clipboard(old),
            ).start()

    @staticmethod
    def _safe_restore_clipboard(old: str) -> None:
        try:
            pyperclip.copy(old)
        except Exception:
            pass

    @staticmethod
    def _send_cmd_v() -> None:
        # Use osascript — the most reliable path that respects the active app
        subprocess.run(
            [
                "osascript",
                "-e",
                'tell application "System Events" to keystroke "v" using command down',
            ],
            check=False,
        )

    def _type(self, text: str) -> None:
        # Slow but works in terminals and password fields that block paste
        from pynput.keyboard import Controller

        kb = Controller()
        for ch in text:
            kb.type(ch)
            time.sleep(0.002)
