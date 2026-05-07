from __future__ import annotations

import importlib.util
import json
import socket
import threading
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
LIVE_E2E_PATH = ROOT / "scripts" / "live_e2e.py"


def _load_live_e2e():
    spec = importlib.util.spec_from_file_location("live_e2e", LIVE_E2E_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _serve_context_responses(*responses: dict) -> tuple[Path, threading.Thread, list[dict]]:
    socket_path = Path(f"/tmp/witzper-live-e2e-{uuid.uuid4().hex}.sock")
    ready = threading.Event()
    requests: list[dict] = []

    def server() -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.bind(str(socket_path))
            sock.listen(len(responses))
            ready.set()
            for response in responses:
                conn, _addr = sock.accept()
                with conn:
                    data = conn.recv(4096)
                    requests.append(json.loads(data.decode()))
                    conn.sendall((json.dumps(response) + "\n").encode("utf-8"))

    thread = threading.Thread(target=server, daemon=True)
    thread.start()
    assert ready.wait(timeout=1)
    return socket_path, thread, requests


def _serve_context_response(response: dict) -> tuple[Path, threading.Thread]:
    socket_path, thread, _requests = _serve_context_responses(response)
    return socket_path, thread


def test_permission_preflight_blocks_when_tcc_permissions_are_missing() -> None:
    live_e2e = _load_live_e2e()
    socket_path, thread = _serve_context_response(
        {"missing": ["Accessibility", "Input Monitoring", "Microphone"]}
    )

    try:
        result = live_e2e.permission_preflight(socket_path)
    finally:
        thread.join(timeout=1)
        socket_path.unlink(missing_ok=True)

    assert result.ok is False
    assert result.missing == ["Accessibility", "Input Monitoring", "Microphone"]
    assert "quit and relaunch" in result.detail


def test_permission_preflight_passes_when_all_permissions_are_granted() -> None:
    live_e2e = _load_live_e2e()
    socket_path, thread = _serve_context_response({"missing": []})

    try:
        result = live_e2e.permission_preflight(socket_path)
    finally:
        thread.join(timeout=1)
        socket_path.unlink(missing_ok=True)

    assert result.ok is True
    assert result.missing == []
    assert "all required permissions granted" in result.detail


def test_open_permission_settings_opens_only_missing_panes() -> None:
    live_e2e = _load_live_e2e()
    calls = []

    def fake_run(cmd, check, capture_output, text, timeout):  # noqa: ANN001
        calls.append(
            {
                "cmd": cmd,
                "check": check,
                "capture_output": capture_output,
                "text": text,
                "timeout": timeout,
            }
        )
        return SimpleNamespace(stdout="")

    live_e2e.open_permission_settings(
        ["Accessibility", "Microphone", "Unknown"],
        runner=fake_run,
    )

    urls = [call["cmd"][1] for call in calls]
    assert urls == [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
    ]
    assert all(call["cmd"][0] == "open" for call in calls)


def test_expected_phrase_similarity_ignores_case_and_punctuation() -> None:
    live_e2e = _load_live_e2e()

    score = live_e2e.text_similarity(
        "hey are you free for lunch tomorrow",
        "Hey, are you free for lunch tomorrow?",
    )

    assert score >= 0.99


def test_expected_phrase_validation_rejects_unrelated_transcript() -> None:
    live_e2e = _load_live_e2e()

    with pytest.raises(RuntimeError, match="transcript similarity"):
        live_e2e.validate_expected_text(
            actual="The weather is cold and cloudy.",
            expected="hey are you free for lunch tomorrow",
            min_similarity=0.8,
        )


def test_insert_and_verify_confirms_focused_text_contains_inserted_text() -> None:
    live_e2e = _load_live_e2e()
    socket_path, thread, requests = _serve_context_responses(
        {"ok": True},
        {"text": "Existing text. Hey, are you free for lunch tomorrow?"},
    )

    try:
        assert live_e2e.insert_and_verify_text(
            socket_path=socket_path,
            text="Hey, are you free for lunch tomorrow?",
            strategy="paste",
            restore_clipboard_after_ms=200,
            verify=True,
        )
    finally:
        thread.join(timeout=1)
        socket_path.unlink(missing_ok=True)

    assert [request["op"] for request in requests] == ["insert", "read_focused_text"]


def test_insert_and_verify_rejects_missing_focused_text_after_insert() -> None:
    live_e2e = _load_live_e2e()
    socket_path, thread, _requests = _serve_context_responses(
        {"ok": True},
        {"text": "Something else entirely."},
    )

    try:
        with pytest.raises(RuntimeError, match="focused text does not contain insertion"):
            live_e2e.insert_and_verify_text(
                socket_path=socket_path,
                text="Hey, are you free for lunch tomorrow?",
                strategy="paste",
                restore_clipboard_after_ms=200,
                verify=True,
            )
    finally:
        thread.join(timeout=1)
        socket_path.unlink(missing_ok=True)


def test_open_textedit_target_creates_scratch_file(tmp_path: Path) -> None:
    live_e2e = _load_live_e2e()
    calls = []

    def fake_run(cmd, check, capture_output, text, timeout):  # noqa: ANN001
        calls.append(
            {
                "cmd": cmd,
                "check": check,
                "capture_output": capture_output,
                "text": text,
                "timeout": timeout,
            }
        )
        return SimpleNamespace(stdout="")

    path, marker = live_e2e.open_textedit_target(target_dir=tmp_path, runner=fake_run)

    assert marker.startswith("Witzper live E2E target")
    assert marker in path.read_text()
    assert calls
    assert calls[0]["cmd"][:3] == ["open", "-a", "TextEdit"]
    assert calls[0]["cmd"][3] == str(path)


def test_trigger_daemon_dictation_sends_down_then_up() -> None:
    live_e2e = _load_live_e2e()
    socket_path, thread, requests = _serve_context_responses(
        {"ok": True},
        {"ok": True},
    )
    sleeps: list[float] = []

    try:
        live_e2e.trigger_daemon_dictation(
            socket_path=socket_path,
            duration_s=1.25,
            sleeper=sleeps.append,
        )
    finally:
        thread.join(timeout=1)
        socket_path.unlink(missing_ok=True)

    assert sleeps == [1.25]
    assert requests == [
        {"op": "simulate_hotkey", "action": "dictate", "phase": "down"},
        {"op": "simulate_hotkey", "action": "dictate", "phase": "up"},
    ]


def test_wait_for_daemon_ready_requires_hotkey_client() -> None:
    live_e2e = _load_live_e2e()
    socket_path, thread, requests = _serve_context_responses(
        {"ok": True, "hotkey_clients": 0},
        {"ok": True, "hotkey_clients": 1},
    )
    sleeps: list[float] = []

    try:
        assert live_e2e.wait_for_daemon_ready(
            socket_path=socket_path,
            timeout_s=1,
            interval_s=0.1,
            sleeper=sleeps.append,
        )
    finally:
        thread.join(timeout=1)
        socket_path.unlink(missing_ok=True)

    assert sleeps == [0.1]
    assert requests == [
        {"op": "daemon_status"},
        {"op": "daemon_status"},
    ]
