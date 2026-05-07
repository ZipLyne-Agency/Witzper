import json
import socket
import time
import uuid
from pathlib import Path

from flow.ui import stream


def test_stream_server_broadcasts_line_delimited_json(monkeypatch) -> None:
    socket_path = Path(f"/tmp/witzper-stream-{uuid.uuid4().hex}.sock")
    monkeypatch.setattr(stream, "SOCKET_PATH", socket_path)
    server = stream.StreamServer()
    try:
        server.start()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(1)
            client.connect(str(socket_path))
            time.sleep(0.05)

            server.emit({"type": "ready", "value": 1})
            line = client.recv(4096)

        assert json.loads(line.decode()) == {"type": "ready", "value": 1}
    finally:
        server.close()
        socket_path.unlink(missing_ok=True)


def test_stream_server_removes_dead_clients(monkeypatch) -> None:
    socket_path = Path(f"/tmp/witzper-stream-{uuid.uuid4().hex}.sock")
    monkeypatch.setattr(stream, "SOCKET_PATH", socket_path)
    server = stream.StreamServer()
    try:
        server.start()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(str(socket_path))
        time.sleep(0.05)
        client.close()

        server.emit({"type": "ready"})
        server.emit({"type": "ready"})

        assert len(server._clients) == 0
    finally:
        server.close()
        socket_path.unlink(missing_ok=True)
