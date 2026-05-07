import json
import socket
import threading
import uuid
from pathlib import Path
from types import SimpleNamespace

from flow.config import InsertionCfg
from flow.insert import inserter
from flow.insert.inserter import Inserter


def _capture_insert_rpc(
    monkeypatch,
    cfg: InsertionCfg,
    app_ctx=None,
    response: bytes = b'{"ok":true}\n',
) -> tuple[dict, bool]:
    socket_path = Path(f"/tmp/witzper-test-{uuid.uuid4().hex}.sock")
    received = {}
    ready = threading.Event()

    def server() -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.bind(str(socket_path))
            sock.listen(1)
            ready.set()
            conn, _addr = sock.accept()
            with conn:
                data = conn.recv(4096)
                received.update(json.loads(data.decode()))
                conn.sendall(response)

    try:
        thread = threading.Thread(target=server)
        thread.start()
        assert ready.wait(timeout=1)
        monkeypatch.setattr(inserter, "CONTEXT_SOCKET", socket_path)

        ok = Inserter(cfg)._insert_via_helper(
            "Hello from Witzper.",
            Inserter(cfg)._strategy_for(app_ctx),
            cfg.restore_clipboard_after_ms,
        )

        thread.join(timeout=1)
        return received, ok
    finally:
        socket_path.unlink(missing_ok=True)


def test_inserter_sends_default_insert_rpc(monkeypatch) -> None:
    received, ok = _capture_insert_rpc(monkeypatch, InsertionCfg())
    assert ok
    assert received == {
        "op": "insert",
        "text": "Hello from Witzper.",
        "strategy": "paste",
        "restore_clipboard_after_ms": 200,
    }


def test_inserter_uses_configured_default_strategy(monkeypatch) -> None:
    received, ok = _capture_insert_rpc(
        monkeypatch,
        InsertionCfg(default_strategy="type", restore_clipboard_after_ms=500),
    )
    assert ok
    assert received["strategy"] == "type"
    assert received["restore_clipboard_after_ms"] == 500


def test_inserter_uses_app_rule_strategy(monkeypatch) -> None:
    app_ctx = SimpleNamespace(rule=SimpleNamespace(insertion="type"))

    received, ok = _capture_insert_rpc(monkeypatch, InsertionCfg(), app_ctx=app_ctx)

    assert ok
    assert received["strategy"] == "type"


def test_inserter_treats_helper_error_response_as_failure(monkeypatch) -> None:
    _received, ok = _capture_insert_rpc(
        monkeypatch,
        InsertionCfg(),
        response=b'{"ok":false,"error":"accessibility_missing"}\n',
    )

    assert not ok
