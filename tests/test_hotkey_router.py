import json
import socket
import threading
import uuid
from pathlib import Path

import pytest

from flow.core import hotkey
from flow.core.hotkey import HotkeyRouter


def _start_hotkey_server(socket_path: Path, events: list[dict]) -> threading.Thread:
    ready = threading.Event()

    def server() -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.bind(str(socket_path))
            sock.listen(1)
            ready.set()
            conn, _addr = sock.accept()
            with conn:
                for event in events:
                    conn.sendall(json.dumps(event).encode() + b"\n")

    thread = threading.Thread(target=server)
    thread.start()
    assert ready.wait(timeout=1)
    return thread


@pytest.mark.asyncio
async def test_hotkey_router_dispatches_action_events(tmp_path, monkeypatch) -> None:
    del tmp_path
    socket_path = Path(f"/tmp/witzper-hotkey-{uuid.uuid4().hex}.sock")
    monkeypatch.setattr(hotkey, "SOCKET_PATH", socket_path)
    seen: list[str] = []
    router = HotkeyRouter()
    router.register(
        "dictate",
        lambda: seen.append("dictate_down"),
        lambda: seen.append("dictate_up"),
    )
    router.register(
        "command",
        lambda: seen.append("command_down"),
        lambda: seen.append("command_up"),
    )

    try:
        thread = _start_hotkey_server(
            socket_path,
            [
                {"type": "hotkey_down", "action": "dictate"},
                {"type": "hotkey_up", "action": "dictate"},
                {"type": "hotkey_down", "action": "command"},
                {"type": "hotkey_up", "action": "command"},
            ],
        )

        await router._run_swift_socket()
        thread.join(timeout=1)
    finally:
        socket_path.unlink(missing_ok=True)

    assert seen == ["dictate_down", "dictate_up", "command_down", "command_up"]


@pytest.mark.asyncio
async def test_hotkey_router_maps_legacy_untagged_events_to_dictate(
    tmp_path,
    monkeypatch,
) -> None:
    del tmp_path
    socket_path = Path(f"/tmp/witzper-hotkey-{uuid.uuid4().hex}.sock")
    monkeypatch.setattr(hotkey, "SOCKET_PATH", socket_path)
    seen: list[str] = []
    router = HotkeyRouter()
    router.register("dictate", lambda: seen.append("down"), lambda: seen.append("up"))

    try:
        thread = _start_hotkey_server(
            socket_path,
            [
                {"type": "hotkey_down"},
                {"type": "hotkey_up"},
                {"type": "ignored"},
            ],
        )

        await router._run_swift_socket()
        thread.join(timeout=1)
    finally:
        socket_path.unlink(missing_ok=True)

    assert seen == ["down", "up"]


def test_is_stale_socket_detects_dead_socket_path(tmp_path) -> None:
    del tmp_path
    socket_path = Path(f"/tmp/witzper-dead-{uuid.uuid4().hex}.sock")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.bind(str(socket_path))

        assert hotkey._is_stale_socket(socket_path)
    finally:
        socket_path.unlink(missing_ok=True)
