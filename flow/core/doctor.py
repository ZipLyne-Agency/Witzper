"""`flow doctor` — check models, permissions, socket, audio device."""

from __future__ import annotations

import json
import os
import shutil
import socket
from pathlib import Path

from rich.console import Console
from rich.table import Table

from flow.config import load_config
from flow.core.hotkey import SOCKET_PATH
from flow.insert.inserter import CONTEXT_SOCKET
from flow.ui.stream import SOCKET_PATH as STREAM_SOCKET

console = Console()


def _hf_has(hf_home: Path, repo_id: str) -> bool:
    if not hf_home.exists():
        return False
    return (hf_home / f"models--{repo_id.replace('/', '--')}").exists()


def _check(label: str, ok: bool, detail: str = "") -> tuple[str, str, str]:
    mark = "[green]✓[/]" if ok else "[red]✗[/]"
    return (mark, label, detail)


def _pid_alive(pid_path: Path = Path("/tmp/Witzper.pid")) -> tuple[bool, str]:
    if not pid_path.exists():
        return False, "pid file missing"
    try:
        pid = int(pid_path.read_text().strip())
    except Exception:
        return False, "pid file unreadable"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False, f"stale pid file ({pid})"
    except PermissionError:
        return True, f"pid {pid} exists, permission denied"
    return True, f"pid {pid}"


def _socket_accepts(path: Path) -> tuple[bool, str]:
    if not path.exists():
        return False, "missing"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.2)
            s.connect(str(path))
        return True, str(path)
    except Exception as e:  # noqa: BLE001
        return False, f"{path} exists but is not accepting connections: {e}"


def _context_rpc(op: str) -> dict | None:
    if not CONTEXT_SOCKET.exists():
        return None
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            s.connect(str(CONTEXT_SOCKET))
            s.sendall((json.dumps({"op": op}) + "\n").encode("utf-8"))
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
        obj = json.loads(data or b"{}")
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


def _permission_status() -> tuple[bool, str]:
    obj = _context_rpc("permission_status")
    if not obj:
        return False, "helper unavailable"
    missing = obj.get("missing")
    if isinstance(missing, list):
        if not missing:
            return True, "Accessibility, Input Monitoring, Microphone"
        return (
            False,
            "missing: "
            + ", ".join(str(item) for item in missing)
            + ". Open Witzper menu settings for each missing permission, then quit and relaunch.",
        )
    granted = [
        name
        for key, name in (
            ("accessibility", "Accessibility"),
            ("input_monitoring", "Input Monitoring"),
            ("microphone", "Microphone"),
        )
        if obj.get(key) is True
    ]
    if len(granted) == 3:
        return True, ", ".join(granted)
    return False, "incomplete permission response"


def run_doctor() -> None:
    cfg = load_config()
    rows: list[tuple[str, str, str]] = []

    # Daemon pid
    ok, detail = _pid_alive()
    rows.append(_check("Python daemon pid", ok, detail))

    # Swift helper socket
    ok, detail = _socket_accepts(SOCKET_PATH)
    rows.append(
        _check(
            "Swift helper socket",
            ok,
            detail if ok else f"{detail} (hotkey events will not arrive)",
        )
    )

    # AX/insertion context socket
    ok, detail = _socket_accepts(CONTEXT_SOCKET)
    rows.append(
        _check(
            "Insertion/context socket",
            ok,
            detail if ok else f"{detail} (text insertion will fail)",
        )
    )

    ok, detail = _socket_accepts(STREAM_SOCKET)
    rows.append(
        _check(
            "Dashboard stream socket",
            ok,
            detail if ok else f"{detail} (dashboard updates will not arrive)",
        )
    )

    ok, detail = _permission_status()
    rows.append(_check("macOS permissions", ok, detail))

    # Audio
    try:
        import sounddevice as sd
        configured = cfg.audio.device or "default"
        if configured.lower() in ("", "default", "system default"):
            device = sd.query_devices(kind="input")
            detail = f"default: {device.get('name', 'unknown')}"
        else:
            matches = [
                (i, dev)
                for i, dev in enumerate(sd.query_devices())
                if dev.get("max_input_channels", 0) > 0
                and (
                    dev.get("name") == configured
                    or configured.lower() in dev.get("name", "").lower()
                )
            ]
            if not matches:
                raise RuntimeError(f"{configured!r} not found")
            idx, dev = matches[0]
            sd.check_input_settings(
                device=idx,
                samplerate=cfg.audio.sample_rate,
                channels=cfg.audio.channels,
                dtype="float32",
            )
            detail = f"{dev.get('name')} (device {idx})"
        rows.append(_check("Configured microphone", True, detail))
    except Exception as e:
        rows.append(_check("Configured microphone", False, str(e)))

    # MLX
    try:
        import mlx.core as mx  # noqa: F401
        rows.append(_check("MLX installed", True))
    except Exception as e:
        rows.append(_check("MLX installed", False, str(e)))

    # Model cache presence (HF hub default)
    hf_home = Path.home() / ".cache" / "huggingface" / "hub"
    rows.append(
        _check(
            f"HF cache: {cfg.asr.speed.model}",
            _hf_has(hf_home, cfg.asr.speed.model),
        )
    )
    rows.append(
        _check(
            f"HF cache: {cfg.cleanup.model}",
            _hf_has(hf_home, cfg.cleanup.model),
        )
    )

    # pbcopy for clipboard paste fallback
    rows.append(_check("pbcopy on PATH", shutil.which("pbcopy") is not None))

    table = Table(show_header=False, box=None)
    for mark, label, detail in rows:
        table.add_row(mark, label, detail)
    console.print(table)
