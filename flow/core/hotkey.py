"""Hotkey listener / router.

The Swift helper (see swift-helper/) owns the global event tap and posts
newline-delimited JSON events over a Unix socket. Each event carries an
`action` name (e.g. "dictate", "command") so multiple bindings can share
one transport.

Event shape:
    {"type":"hotkey_down","action":"dictate"}
    {"type":"hotkey_up","action":"command"}

For dev machines without the Swift helper, a pynput fallback handles a
single key for the `dictate` action only. Chords and multi-action setups
require the helper.
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import Callable
from pathlib import Path

SOCKET_PATH = Path(os.environ.get("FLOW_SOCKET", "/tmp/Witzper.sock"))

Handler = tuple[Callable[[], None], Callable[[], None]]


class HotkeyRouter:
    """Dispatch hotkey events from the Swift helper to per-action handlers.

    Use ``register(action, on_down, on_up)`` for each action you care about,
    then ``await run()`` from the asyncio loop. Untagged events from older
    helpers map to the ``dictate`` action.
    """

    def __init__(self) -> None:
        self._handlers: dict[str, Handler] = {}
        self._fallback_action: str = "dictate"

    def register(
        self,
        action: str,
        on_down: Callable[[], None],
        on_up: Callable[[], None],
    ) -> None:
        self._handlers[action] = (on_down, on_up)

    def actions(self) -> list[str]:
        return list(self._handlers.keys())

    def _dispatch(self, etype: str, action: str) -> None:
        handler = self._handlers.get(action)
        if handler is None:
            return
        on_down, on_up = handler
        if etype == "hotkey_down":
            on_down()
        elif etype == "hotkey_up":
            on_up()

    async def run(self) -> None:
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
            if etype not in ("hotkey_down", "hotkey_up"):
                continue
            action = evt.get("action") or self._fallback_action
            self._dispatch(etype, action)

    async def _run_pynput_fallback(self) -> None:
        """Single-key fallback for the dictate action only.

        pynput cannot reliably observe Fn or chorded modifiers on modern
        macOS — so this path always binds to right_option as a hard-coded
        substitute and only fires the `dictate` handler.
        """
        if "dictate" not in self._handlers:
            print("[flow] no `dictate` handler registered — fallback idle")
            while True:
                await asyncio.sleep(3600)

        from pynput import keyboard

        target = keyboard.Key.alt_r
        on_down, on_up = self._handlers["dictate"]
        loop = asyncio.get_running_loop()

        def on_press(k):
            if k == target:
                loop.call_soon_threadsafe(on_down)

        def on_release(k):
            if k == target:
                loop.call_soon_threadsafe(on_up)

        listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        listener.start()
        try:
            while True:
                await asyncio.sleep(3600)
        finally:
            listener.stop()


# Back-compat alias for any external callers still importing the old name.
HotkeyListener = HotkeyRouter
