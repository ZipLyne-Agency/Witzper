"""Placeholder: floating 'listening' pill UI.

The production implementation should be a tiny SwiftUI overlay driven by the
Swift helper, reading state from the same Unix socket used for hotkey events.
For now, we just log state transitions to the terminal.
"""

from __future__ import annotations

from rich.console import Console

console = Console()


class Pill:
    def show_listening(self) -> None:
        console.print("[cyan]● listening[/]", end="\r")

    def show_processing(self) -> None:
        console.print("[yellow]● processing[/]", end="\r")

    def hide(self) -> None:
        console.print(" " * 20, end="\r")
