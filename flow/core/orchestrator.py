"""The main pipeline: hotkey → audio → VAD → ASR → cleanup → insert → edit-watch."""

from __future__ import annotations

import asyncio
import time

from rich.console import Console

from flow.config import Config
from flow.context.app_context import AppContextProvider
from flow.context.dictionary import Dictionary
from flow.context.few_shot import FewShotRetriever
from flow.core.audio import AudioCapture
from flow.core.hotkey import HotkeyListener
from flow.core.vad import make_vad
from flow.insert.inserter import Inserter
from flow.models.asr_base import ASRBackend
from flow.models.cleanup import CleanupLLM
from flow.models.parakeet import ParakeetASR
from flow.models.qwen3_asr import Qwen3ASR
from flow.personalize.edit_watch import EditWatcher
from flow.personalize.store import CorrectionStore

console = Console()


class Orchestrator:
    def __init__(self, cfg: Config, verbose: bool = False):
        self.cfg = cfg
        self.verbose = verbose

        # Hot components — load upfront so first utterance isn't cold.
        self.audio = AudioCapture(cfg.audio)
        self.vad = make_vad(cfg.vad)
        self.dictionary = Dictionary.open_default()
        self.app_context = AppContextProvider()
        self.few_shot = FewShotRetriever.open_default()
        self.inserter = Inserter(cfg.insertion)
        self.corrections = CorrectionStore.open_default()
        self.edit_watcher = EditWatcher(
            window_seconds=cfg.personalization.edit_watch_window_seconds,
            store=self.corrections,
            dictionary=self.dictionary,
            auto_add=cfg.personalization.auto_add_to_dictionary,
        )

        console.print("[dim]loading ASR models...[/]")
        self.asr_speed: ASRBackend = ParakeetASR(cfg.asr.speed.model)
        self.asr_accuracy: ASRBackend | None = None  # lazy
        console.print("[dim]loading cleanup LLM...[/]")
        self.cleanup = CleanupLLM(cfg.cleanup)

        self._busy = asyncio.Lock()
        self._utterance_task: asyncio.Task | None = None

    def _get_asr(self, mode: str) -> ASRBackend:
        if mode == "accuracy":
            if self.asr_accuracy is None:
                console.print("[dim]lazy-loading Qwen3-ASR...[/]")
                self.asr_accuracy = Qwen3ASR(self.cfg.asr.accuracy.model)
            return self.asr_accuracy
        return self.asr_speed

    def _choose_mode(self, app_ctx) -> str:
        if self.cfg.asr.mode in ("speed", "accuracy"):
            return self.cfg.asr.mode
        return app_ctx.rule.asr_mode if app_ctx and app_ctx.rule else "speed"

    # ---- Hotkey callbacks -------------------------------------------------

    def on_down(self) -> None:
        if self.verbose:
            console.print("[cyan]⏺ recording[/]")
        self.audio.start()

    def on_up(self) -> None:
        if self.verbose:
            console.print("[cyan]⏹ processing[/]")
        audio = self.audio.stop()
        if audio.size == 0:
            return
        self._utterance_task = asyncio.create_task(self._process(audio))

    # ---- Main per-utterance pipeline -------------------------------------

    async def _process(self, audio) -> None:
        async with self._busy:
            t0 = time.perf_counter()

            # 1. Focused app context (bundle id, window title, surrounding text)
            app_ctx = self.app_context.snapshot()

            # 2. VAD trim
            trimmed = self.vad.trim(audio, sr=self.cfg.audio.sample_rate)
            t_vad = time.perf_counter()

            # 3. ASR (mode chosen per-app)
            mode = self._choose_mode(app_ctx)
            asr = self._get_asr(mode)
            boost_terms = self.dictionary.boost_terms()
            raw = asr.transcribe(
                trimmed,
                sample_rate=self.cfg.audio.sample_rate,
                context_prompt=self._asr_context_prompt(app_ctx, boost_terms),
            )
            t_asr = time.perf_counter()

            if not raw.text.strip():
                return

            # 4. LLM cleanup with dynamic few-shots + focused-app tone priming
            few_shots = self.few_shot.retrieve(raw.text, n=self.cfg.cleanup.few_shot_n)
            cleaned = self.cleanup.clean(
                raw_transcript=raw.text,
                alt_hypotheses=raw.alternatives,
                app_context=app_ctx,
                dictionary_boost=boost_terms,
                few_shots=few_shots,
            )
            t_llm = time.perf_counter()

            # 5. Deterministic dictionary replacement rules post-pass
            final = self.dictionary.apply_replacements(cleaned)

            # 6. Insert
            self.inserter.insert(final, app_ctx=app_ctx)
            t_insert = time.perf_counter()

            if self.verbose:
                console.print(
                    f"[dim]vad {(t_vad-t0)*1000:.0f}ms · "
                    f"asr {(t_asr-t_vad)*1000:.0f}ms · "
                    f"llm {(t_llm-t_asr)*1000:.0f}ms · "
                    f"insert {(t_insert-t_llm)*1000:.0f}ms · "
                    f"total {(t_insert-t0)*1000:.0f}ms[/]"
                )
                console.print(f"[green]›[/] {final}")

            # 7. Arm the edit watcher so later edits become training signal
            self.edit_watcher.arm(
                raw_transcript=raw.text,
                inserted_text=final,
                app_ctx=app_ctx,
                audio=trimmed,
                sample_rate=self.cfg.audio.sample_rate,
            )

    def _asr_context_prompt(self, app_ctx, boost_terms: list[str]) -> str | None:
        if not app_ctx:
            return None
        parts: list[str] = []
        if app_ctx.app_name:
            parts.append(f"App: {app_ctx.app_name}.")
        if app_ctx.window_title:
            parts.append(f"Window: {app_ctx.window_title}.")
        if app_ctx.surrounding_text:
            parts.append(f"Context: {app_ctx.surrounding_text[:500]}")
        if boost_terms:
            parts.append("Vocabulary: " + ", ".join(boost_terms[:200]))
        return " ".join(parts) or None

    # ---- Main loop --------------------------------------------------------

    async def run_forever(self) -> None:
        listener = HotkeyListener(
            key=self.cfg.hotkey.key, on_down=self.on_down, on_up=self.on_up
        )
        console.print("[green]ready.[/] hold the hotkey to dictate.")
        await listener.run()
