"""CLI entry point: `flow run`, `flow dict`, `flow train`, `flow doctor`."""

from __future__ import annotations

import asyncio
from pathlib import Path

import typer
from rich.console import Console

from flow.config import load_config
from flow.core.orchestrator import Orchestrator

app = typer.Typer(add_completion=False, no_args_is_help=True, help="Witzper — local dictation")
console = Console()


@app.command()
def run(
    config: Path = typer.Option(None, "--config", "-c", help="Path to config TOML"),
    verbose: bool = typer.Option(False, "--verbose", "-v"),
) -> None:
    """Start the dictation daemon."""
    import os
    import signal as _sig

    # Rename the process so `ps`, `top`, and Activity Monitor's Command
    # column show "Witzper" instead of "Python". Activity Monitor's
    # "Process Name" column is fixed by the kernel to the exec'd binary
    # basename (still "Python") — see the launcher shim in scripts/run.sh
    # for the full rename.
    try:
        import setproctitle
        setproctitle.setproctitle("Witzper")
    except Exception:
        pass

    pid_path = Path("/tmp/Witzper.pid")
    if pid_path.exists():
        try:
            old_pid = int(pid_path.read_text().strip())
            try:
                os.kill(old_pid, 0)  # check alive
                console.print(
                    f"[red]Witzper daemon already running (pid {old_pid})[/] — "
                    f"kill it first: kill {old_pid}"
                )
                raise typer.Exit(1)
            except ProcessLookupError:
                pid_path.unlink()  # stale
        except (ValueError, FileNotFoundError):
            pid_path.unlink(missing_ok=True)
    pid_path.write_text(str(os.getpid()))

    def _cleanup(*_args):
        pid_path.unlink(missing_ok=True)
        raise SystemExit(0)

    _sig.signal(_sig.SIGTERM, _cleanup)
    _sig.signal(_sig.SIGINT, _cleanup)

    cfg = load_config(config)
    console.print(f"[bold cyan]Witzper[/] starting ({cfg.asr.mode} mode)")
    orch = Orchestrator(cfg, verbose=verbose)
    try:
        asyncio.run(orch.run_forever())
    except KeyboardInterrupt:
        console.print("\n[dim]shutting down[/]")
    finally:
        pid_path.unlink(missing_ok=True)


@app.command("dict")
def dictionary_cmd(
    add: str = typer.Option(None, "--add", help="Add a word or phrase to the dictionary"),
    replace: str = typer.Option(None, "--replace", help="wrong=right replacement rule"),
    remove: str = typer.Option(None, "--remove", help="Remove a boost word or replacement key"),
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
    if remove:
        d._conn.execute("DELETE FROM boost WHERE term = ?", (remove,))
        d._conn.execute("DELETE FROM replacement WHERE wrong = ?", (remove,))
        d._conn.commit()
        console.print(f"[yellow]removed[/] {remove}")
    if list_all or not (add or replace or remove):
        for entry in d.all():
            console.print(entry)


@app.command()
def snippet(
    add: str = typer.Option(None, "--add", help="Trigger phrase"),
    text: str = typer.Option(None, "--text", help="Expansion text"),
    remove: str = typer.Option(None, "--remove", help="Remove trigger"),
    list_all: bool = typer.Option(False, "--list", "-l"),
) -> None:
    """Manage snippets (voice → text expansion)."""
    from flow.personalize.snippets import SnippetStore

    s = SnippetStore.open_default()
    if add:
        if not text:
            raise typer.BadParameter("--text required when --add is given")
        s.add(add, text)
        console.print(f"[green]added[/] {add!r} → {text[:60]!r}")
    if remove:
        if s.remove(remove):
            console.print(f"[yellow]removed[/] {remove!r}")
        else:
            console.print(f"[red]not found[/] {remove!r}")
    if list_all or not (add or remove):
        all_snippets = s.all()
        if not all_snippets:
            console.print("[dim]no snippets yet — add one with: flow snippet --add 'my address' --text '123 Main St'[/]")
        for sn in all_snippets:
            console.print(f"[cyan]{sn.trigger}[/] → {sn.expansion[:80]}")


@app.command()
def style(
    category: str = typer.Argument(None, help="personal_messages | work_messages | email | other"),
    name: str = typer.Argument(None, help="formal | casual | very_casual | excited"),
) -> None:
    """View or set Flow Styles per app category."""
    import tomli

    from flow.config import USER_CONFIG_PATH
    from flow.context.styles import CATEGORIES, STYLE_INSTRUCTIONS, StyleResolver  # noqa: F401

    cfg = load_config()

    if not category:
        console.print("[bold cyan]Flow Styles (current)[/]")
        for cat in CATEGORIES:
            val = getattr(cfg.styles, cat)
            console.print(f"  {cat}: [green]{val}[/]")
        console.print()
        console.print("Set with:  [dim]flow style <category> <style>[/]")
        console.print("Categories: personal_messages | work_messages | email | other")
        console.print("Styles:     formal | casual | very_casual | excited")
        return

    if category not in CATEGORIES:
        raise typer.BadParameter(f"category must be one of: {', '.join(CATEGORIES)}")
    if name not in STYLE_INSTRUCTIONS:
        raise typer.BadParameter(f"style must be one of: {', '.join(STYLE_INSTRUCTIONS)}")

    USER_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    existing: dict = {}
    if USER_CONFIG_PATH.exists():
        with USER_CONFIG_PATH.open("rb") as f:
            existing = tomli.load(f)
    existing.setdefault("styles", {})[category] = name

    lines = ["# Witzper user config", ""]
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
    console.print(f"[green]✓[/] {category} → [bold]{name}[/]")
    console.print("[dim]restart the daemon for the change to take effect[/]")


@app.command()
def train(
    what: str = typer.Argument("cleanup", help="cleanup | asr"),
) -> None:
    """Run a LoRA fine-tune cycle against local corrections."""
    from flow.personalize.train_lora import train_asr, train_cleanup

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


@app.command()
def setup() -> None:
    """Interactive first-run: pick your push-to-talk hotkey."""
    from flow.core.setup_wizard import run_wizard

    run_wizard()


if __name__ == "__main__":
    app()
