"""Command Mode: hotkey → capture selection → dictate instruction → LLM transform → popup.

Reuses the existing audio capture + speed ASR + a lazy-loaded transform LLM
(``CommandLLM``). The flow:

  1. on_down  — snapshot the user's text selection from the focused app via
                the Swift helper's AX bridge, then start audio capture so the
                user can dictate the instruction ("rewrite as an email").
  2. on_up    — stop audio, transcribe with the speed ASR, run the transform
                LLM with (instruction, selection) and forward the result to
                the Swift helper, which shows a small panel with
                Copy / Replace Selection / Dismiss buttons.

If no selection was captured (or AX failed), the popup hides the Replace
button and Copy is the default action — matching the user's intuition that
"I highlight something, the popup gives me a result to copy back".
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
from pathlib import Path

from rich.console import Console

from flow.config import Config
from flow.core.audio import AudioCapture
from flow.models.asr_base import ASRBackend
from flow.models.command import CommandLLM
from flow.ui import stream

console = Console()

CONTEXT_SOCKET = Path(os.environ.get("FLOW_CONTEXT_SOCKET", "/tmp/flow-context.sock"))


class CommandModeController:
    def __init__(
        self,
        cfg: Config,
        audio: AudioCapture,
        asr: ASRBackend,
        llm: CommandLLM,
        verbose: bool = False,
    ) -> None:
        self.cfg = cfg
        self.audio = audio
        self.asr = asr
        self.llm = llm
        self.verbose = verbose
        self._selection: str = ""
        self._task: asyncio.Task | None = None
        self._busy: bool = False

    # ---- Hotkey callbacks -------------------------------------------------

    def on_down(self) -> None:
        if self._busy:
            return
        # Capture selection FIRST so the keystroke doesn't shift focus.
        self._selection = self._capture_selection()
        if self.verbose:
            console.print(
                f"[magenta]⌘ command: listening "
                f"(selection {len(self._selection)} chars)[/]"
            )
        self.audio.start()
        stream.emit(
            {
                "type": "command",
                "state": "listening",
                "selection_chars": len(self._selection),
            }
        )

    def on_up(self) -> None:
        if not self._busy and self._task is not None and not self._task.done():
            return
        audio = self.audio.stop()
        stream.emit({"type": "command", "state": "processing"})
        if audio.size == 0:
            stream.emit({"type": "command", "state": "idle"})
            return
        self._task = asyncio.create_task(self._run(audio))

    # ---- Pipeline ---------------------------------------------------------

    async def _run(self, audio) -> None:
        self._busy = True
        try:
            loop = asyncio.get_running_loop()
            raw = await loop.run_in_executor(
                None,
                lambda: self.asr.transcribe(
                    audio, sample_rate=self.cfg.audio.sample_rate
                ),
            )
            instruction = (raw.text or "").strip()
            if not instruction:
                stream.emit(
                    {"type": "command", "state": "idle", "error": "empty_instruction"}
                )
                return
            if self.verbose:
                console.print(f"[magenta]⌘ instruction:[/] {instruction}")

            source = self._selection or ""
            result = await loop.run_in_executor(
                None, lambda: self.llm.run(instruction, source)
            )
            if self.verbose:
                console.print(f"[green]⌘ result:[/] {result}")

            stream.emit(
                {
                    "type": "command_result",
                    "instruction": instruction,
                    "result": result,
                    "had_selection": bool(source),
                }
            )
            self._show_result(instruction, result, had_selection=bool(source))
        except Exception as e:  # noqa: BLE001
            console.print(f"[red]command mode error: {e}[/]")
            stream.emit({"type": "command", "state": "idle", "error": str(e)})
        finally:
            self._busy = False
            stream.emit({"type": "command", "state": "idle"})

    # ---- Helper RPCs ------------------------------------------------------

    @staticmethod
    def _capture_selection() -> str:
        if not CONTEXT_SOCKET.exists():
            return ""
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(str(CONTEXT_SOCKET))
            s.sendall(b'{"op":"get_selection"}\n')
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            s.close()
            obj = json.loads(data or b"{}")
            return (obj.get("selected_text") or "").strip()
        except Exception:
            return ""

    @staticmethod
    def _show_result(instruction: str, result: str, had_selection: bool) -> None:
        if not CONTEXT_SOCKET.exists():
            console.print(f"[green]command result:[/] {result}")
            return
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(60.0)
            s.connect(str(CONTEXT_SOCKET))
            payload = (
                json.dumps(
                    {
                        "op": "command_result",
                        "instruction": instruction,
                        "result": result,
                        "had_selection": had_selection,
                    }
                )
                + "\n"
            )
            s.sendall(payload.encode("utf-8"))
            try:
                _ = s.recv(4096)
            except Exception:
                pass
            s.close()
        except Exception as e:  # noqa: BLE001
            console.print(f"[red]command popup RPC failed: {e}[/]")
