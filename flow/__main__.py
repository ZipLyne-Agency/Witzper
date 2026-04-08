"""CLI entry point: `flow run`, `flow dict`, `flow train`, `flow doctor`."""

from __future__ import annotations

import asyncio
from pathlib import Path

import typer
from rich.console import Console

from flow.config import load_config
from flow.core.orchestrator import Orchestrator

app = typer.Typer(add_completion=False, no_args_is_help=True, help="flow-local — local dictation")
console = Console()


@app.command()
def run(
    config: Path = typer.Option(None, "--config", "-c", help="Path to config TOML"),
    verbose: bool = typer.Option(False, "--verbose", "-v"),
) -> None:
    """Start the dictation daemon."""
    cfg = load_config(config)
    console.print(f"[bold cyan]flow-local[/] starting ({cfg.asr.mode} mode)")
    orch = Orchestrator(cfg, verbose=verbose)
    try:
        asyncio.run(orch.run_forever())
    except KeyboardInterrupt:
        console.print("\n[dim]shutting down[/]")


@app.command("dict")
def dictionary_cmd(
    add: str = typer.Option(None, "--add", help="Add a word or phrase to the dictionary"),
    replace: str = typer.Option(None, "--replace", help="wrong=right replacement rule"),
    list_all: bool = typer.Option(False, "--list", "-l"),
) -> None:
    """Manage the personal dictionary."""
    from flow.context.dictionary import Dictionary

    d = Dictionary.open_default()
    if add:
        d.add_boost(add)
        console.print(f"[green]added[/] boost: {add}")
    if replace:
        wrong, _, right = replace.partition("=")
        if not wrong or not right:
            raise typer.BadParameter("format: wrong=right")
        d.add_replacement(wrong.strip(), right.strip())
        console.print(f"[green]added[/] rule: {wrong!r} → {right!r}")
    if list_all:
        for entry in d.all():
            console.print(entry)


@app.command()
def train(
    what: str = typer.Argument("cleanup", help="cleanup | asr"),
) -> None:
    """Run a LoRA fine-tune cycle against local corrections."""
    from flow.personalize.train_lora import train_cleanup, train_asr

    if what == "cleanup":
        train_cleanup()
    elif what == "asr":
        train_asr()
    else:
        raise typer.BadParameter("what must be 'cleanup' or 'asr'")


@app.command()
def doctor() -> None:
    """Check system state: models, permissions, Swift helper, audio."""
    from flow.core.doctor import run_doctor

    run_doctor()


if __name__ == "__main__":
    app()
