"""Hotkey listener.

Primary path: the Swift helper posts hotkey events over a Unix socket (see
swift-helper/). Fallback path for dev: pynput listens for a chosen key globally.
The pynput fallback works for keys like right_option/right_cmd/caps_lock but
cannot reliably intercept Fn on modern macOS — hence the Swift helper for prod.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Callable

SOCKET_PATH = Path(os.environ.get("FLOW_SOCKET", "/tmp/Witzper.sock"))


class HotkeyListener:
    def __init__(self, key: str, on_down: Callable[[], None], on_up: Callable[[], None]):
        self.key = key
        self.on_down = on_down
        self.on_up = on_up
        self._task: asyncio.Task | None = None

    async def run(self) -> None:
        # Keep reconnecting to the Swift helper socket if it drops.
        # If the socket never appears, use the pynput fallback.
        while True:
            if SOCKET_PATH.exists():
                try:
                    await self._run_swift_socket()
                except Exception as e:  # noqa: BLE001
                    print(f"[flow] hotkey socket error: {e} — reconnecting in 2s")
                await asyncio.sleep(2)
            else:
                print(f"[flow] {SOCKET_PATH} not found — using pynput fallback")
                await self._run_pynput_fallback()
                return

    async def _run_swift_socket(self) -> None:
        """Consume newline-delimited JSON events from the Swift helper."""
        reader, _writer = await asyncio.open_unix_connection(str(SOCKET_PATH))
        print("[flow] connected to Swift helper socket")
        while True:
            line = await reader.readline()
            if not line:
                print("[flow] socket EOF — will reconnect")
                return
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            etype = evt.get("type")
            if etype == "hotkey_down":
                self.on_down()
            elif etype == "hotkey_up":
                self.on_up()

    async def _run_pynput_fallback(self) -> None:
        from pynput import keyboard

        key_map = {
            "right_option": keyboard.Key.alt_r,
            "right_cmd": keyboard.Key.cmd_r,
            "caps_lock": keyboard.Key.caps_lock,
            "fn": None,  # pynput cannot see Fn reliably on macOS
        }
        target = key_map.get(self.key)
        if target is None:
            print(f"[flow] WARNING: pynput fallback cannot listen for {self.key!r}; "
                  f"install the Swift helper. Falling back to right_option.")
            target = keyboard.Key.alt_r

        loop = asyncio.get_running_loop()

        def on_press(k):
            if k == target:
                loop.call_soon_threadsafe(self.on_down)

        def on_release(k):
            if k == target:
                loop.call_soon_threadsafe(self.on_up)

        listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        listener.start()
        try:
            while True:
                await asyncio.sleep(3600)
        finally:
            listener.stop()
