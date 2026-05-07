"""First-run interactive setup: pick hotkey, write user config."""

from __future__ import annotations

from pathlib import Path

import tomli
from rich.console import Console
from rich.prompt import Prompt
from rich.table import Table

from flow.config import USER_CONFIG_PATH
from flow.core.user_config import load_user_config, write_user_config_dict

console = Console()

HOTKEYS: list[tuple[str, str, str]] = [
    ("right_option", "Right ⌥ Option", "recommended — big key, rarely used alone"),
    ("right_cmd", "Right ⌘ Command", "big key near space bar"),
    ("right_shift", "Right ⇧ Shift", "huge target, but may conflict with shift-click"),
    ("caps_lock", "⇪ Caps Lock", "perfect if you don't use caps lock"),
    ("fn", "fn (Function)", "lowest conflict; Wispr Flow default"),
]


def pick_hotkey(current: str | None = None) -> str:
    table = Table(title="Choose your push-to-talk hotkey", show_lines=False)
    table.add_column("#", style="cyan", no_wrap=True)
    table.add_column("key")
    table.add_column("label")
    table.add_column("notes", style="dim")
    for i, (key, label, note) in enumerate(HOTKEYS, 1):
        marker = "  ←  current" if key == current else ""
        table.add_row(str(i), key, label, note + marker)
    console.print(table)

    default_idx = "1"
    if current:
        for i, (k, _, _) in enumerate(HOTKEYS, 1):
            if k == current:
                default_idx = str(i)
                break

    choice = Prompt.ask(
        "pick one",
        choices=[str(i) for i in range(1, len(HOTKEYS) + 1)],
        default=default_idx,
    )
    return HOTKEYS[int(choice) - 1][0]


def write_user_config(hotkey: str) -> Path:
    existing = load_user_config(USER_CONFIG_PATH)
    existing.setdefault("hotkey", {})["key"] = hotkey
    existing["hotkey"]["toggle_mode"] = False
    existing.setdefault("hotkeys", {})
    existing["hotkeys"]["dictate"] = {"key": hotkey, "mode": "hold"}
    return write_user_config_dict(USER_CONFIG_PATH, existing)


def run_wizard() -> None:
    console.print("[bold cyan]Witzper setup[/]\n")

    current = None
    if USER_CONFIG_PATH.exists():
        try:
            with USER_CONFIG_PATH.open("rb") as f:
                current = tomli.load(f).get("hotkey", {}).get("key")
        except Exception:
            pass

    hotkey = pick_hotkey(current=current)
    path = write_user_config(hotkey)
    console.print(f"\n[green]✓[/] saved {path}")
    console.print(f"[green]✓[/] hotkey: [bold]{hotkey}[/]")
    console.print(
        "\n[dim]run './scripts/run.sh' to start the daemon.[/]"
        "\n[dim]hold your hotkey to talk, release to insert the text.[/]"
    )
