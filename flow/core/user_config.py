"""Helpers for reading and writing Witzper's user TOML config."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import Any

import tomli


def load_user_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("rb") as f:
        data = tomli.load(f)
    return data if isinstance(data, dict) else {}


def write_user_config_dict(path: Path, data: dict[str, Any]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# Witzper user config (overrides configs/default.toml)", ""]
    for section, value in data.items():
        if isinstance(value, dict):
            _emit_section(section, value, lines)
    path.write_text("\n".join(lines))
    return path


def update_user_config(path: Path, mutator: Callable[[dict[str, Any]], None]) -> Path:
    data = load_user_config(path)
    mutator(data)
    return write_user_config_dict(path, data)


def _format_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int | float):
        return str(value)
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _emit_section(prefix: str, data: dict[str, Any], lines: list[str]) -> None:
    scalars = {k: v for k, v in data.items() if not isinstance(v, dict)}
    nested = {k: v for k, v in data.items() if isinstance(v, dict)}
    if scalars:
        lines.append(f"[{prefix}]")
        for key, value in scalars.items():
            lines.append(f"{key} = {_format_value(value)}")
        lines.append("")
    for key, value in nested.items():
        _emit_section(f"{prefix}.{key}", value, lines)
