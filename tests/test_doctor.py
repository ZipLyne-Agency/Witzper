from __future__ import annotations

import socket
import threading
import uuid
from pathlib import Path

from flow.core.doctor import _permission_status, _socket_accepts


def _short_socket_path(name: str) -> Path:
    return Path(f"/tmp/witzper-{name}-{uuid.uuid4().hex}.sock")


def test_permission_status_reports_all_granted(monkeypatch) -> None:
    monkeypatch.setattr(
        "flow.core.doctor._context_rpc",
        lambda op: {
            "accessibility": True,
            "input_monitoring": True,
            "microphone": True,
            "missing": [],
        },
    )

    assert _permission_status() == (
        True,
        "Accessibility, Input Monitoring, Microphone",
    )


def test_permission_status_reports_missing_permissions(monkeypatch) -> None:
    monkeypatch.setattr(
        "flow.core.doctor._context_rpc",
        lambda op: {
            "accessibility": True,
            "input_monitoring": False,
            "microphone": False,
            "missing": ["Input Monitoring", "Microphone"],
        },
    )

    ok, detail = _permission_status()

    assert ok is False
    assert "missing: Input Monitoring, Microphone" in detail
    assert "Open Witzper menu" in detail
    assert "quit and relaunch" in detail


def test_permission_status_handles_missing_helper(monkeypatch) -> None:
    monkeypatch.setattr("flow.core.doctor._context_rpc", lambda op: None)

    assert _permission_status() == (False, "helper unavailable")


def test_socket_accepts_reports_listening_unix_socket() -> None:
    path = _short_socket_path("healthy")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    server.listen(1)

    accepted: list[socket.socket] = []

    def accept_once() -> None:
        client, _ = server.accept()
        accepted.append(client)

    thread = threading.Thread(target=accept_once)
    thread.start()
    try:
        assert _socket_accepts(path) == (True, str(path))
    finally:
        thread.join(timeout=1)
        for client in accepted:
            client.close()
        server.close()
        path.unlink(missing_ok=True)


def test_socket_accepts_reports_stale_socket_file() -> None:
    path = _short_socket_path("stale")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(str(path))
    finally:
        server.close()

    ok, detail = _socket_accepts(path)

    assert ok is False
    assert "exists but is not accepting connections" in detail
    path.unlink(missing_ok=True)
