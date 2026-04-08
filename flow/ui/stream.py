"""Unix socket broadcaster — daemon → dashboard event stream.

The dashboard (Swift) connects to /tmp/flow-stream.sock and reads
newline-delimited JSON events. This module is fire-and-forget: if no
client is connected, events are dropped silently.
"""

from __future__ import annotations

import json
import os
import socket
import threading
from pathlib import Path
from typing import Any

SOCKET_PATH = Path(os.environ.get("FLOW_STREAM_SOCKET", "/tmp/flow-stream.sock"))


class StreamServer:
    def __init__(self):
        self._lock = threading.Lock()
        self._clients: list[socket.socket] = []
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if SOCKET_PATH.exists():
            try:
                SOCKET_PATH.unlink()
            except OSError:
                pass
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(str(SOCKET_PATH))
        self._sock.listen(4)
        os.chmod(SOCKET_PATH, 0o600)
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    def _accept_loop(self) -> None:
        assert self._sock is not None
        while True:
            try:
                client, _ = self._sock.accept()
            except OSError:
                return
            with self._lock:
                self._clients.append(client)

    def emit(self, event: dict[str, Any]) -> None:
        line = (json.dumps(event) + "\n").encode("utf-8")
        with self._lock:
            dead: list[socket.socket] = []
            for c in self._clients:
                try:
                    c.sendall(line)
                except OSError:
                    dead.append(c)
            for c in dead:
                self._clients.remove(c)
                try:
                    c.close()
                except OSError:
                    pass


# Singleton — orchestrator just imports `stream` and calls stream.emit(...)
_server: StreamServer | None = None


def get_server() -> StreamServer:
    global _server
    if _server is None:
        _server = StreamServer()
        _server.start()
    return _server


def emit(event: dict[str, Any]) -> None:
    try:
        get_server().emit(event)
    except Exception:
        pass
