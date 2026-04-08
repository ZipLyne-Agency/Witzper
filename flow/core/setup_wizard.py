"""First-run interactive setup: pick hotkey, write user config."""

from __future__ import annotations

from pathlib import Path

import tomli
from rich.console import Console
from rich.prompt import Prompt
from rich.table import Table

from flow.config import USER_CONFIG_PATH

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
    USER_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    existing: dict = {}
    if USER_CONFIG_PATH.exists():
        with USER_CONFIG_PATH.open("rb") as f:
            existing = tomli.load(f)
    existing.setdefault("hotkey", {})["key"] = hotkey
    existing["hotkey"]["toggle_mode"] = False

    lines = ["# Witzper user config (overrides configs/default.toml)", ""]
    for section, kv in existing.items():
        lines.append(f"[{section}]")
        for k, v in kv.items():
            if isinstance(v, bool):
                lines.append(f"{k} = {'true' if v else 'false'}")
            elif isinstance(v, (int, float)):
                lines.append(f"{k} = {v}")
            else:
                lines.append(f'{k} = "{v}"')
        lines.append("")
    USER_CONFIG_PATH.write_text("\n".join(lines))
    return USER_CONFIG_PATH


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
