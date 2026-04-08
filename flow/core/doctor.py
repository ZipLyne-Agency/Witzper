"""`flow doctor` — check models, permissions, socket, audio device."""

from __future__ import annotations

import shutil
from pathlib import Path

from rich.console import Console
from rich.table import Table

from flow.config import load_config
from flow.core.hotkey import SOCKET_PATH

console = Console()


def _check(label: str, ok: bool, detail: str = "") -> tuple[str, str, str]:
    mark = "[green]✓[/]" if ok else "[red]✗[/]"
    return (mark, label, detail)


def run_doctor() -> None:
    cfg = load_config()
    rows: list[tuple[str, str, str]] = []

    # Swift helper socket
    rows.append(
        _check(
            "Swift helper socket",
            SOCKET_PATH.exists(),
            str(SOCKET_PATH) if SOCKET_PATH.exists() else "not running (pynput fallback will be used)",
        )
    )

    # Audio
    try:
        import sounddevice as sd
        _ = sd.query_devices(kind="input")
        rows.append(_check("Microphone access", True))
    except Exception as e:
        rows.append(_check("Microphone access", False, str(e)))

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
            any(hf_home.glob(f"**/{cfg.asr.speed.model.replace('/', '--')}*"))
            if hf_home.exists()
            else False,
        )
    )
    rows.append(
        _check(
            f"HF cache: {cfg.cleanup.model}",
            any(hf_home.glob(f"**/{cfg.cleanup.model.replace('/', '--')}*"))
            if hf_home.exists()
            else False,
        )
    )

    # pbcopy for clipboard paste fallback
    rows.append(_check("pbcopy on PATH", shutil.which("pbcopy") is not None))

    table = Table(show_header=False, box=None)
    for mark, label, detail in rows:
        table.add_row(mark, label, detail)
    console.print(table)
