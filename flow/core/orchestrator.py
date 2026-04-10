"""The main pipeline: hotkey → audio → VAD → ASR → cleanup → insert → edit-watch."""

from __future__ import annotations

import asyncio
import threading
import time

from rich.console import Console

from flow.config import Config
from flow.context.app_context import AppContextProvider
from flow.context.dictionary import Dictionary
from flow.context.few_shot import FewShotRetriever
from flow.context.styles import StyleResolver
from flow.core.audio import AudioCapture
from flow.core.command_mode import CommandModeController
from flow.core.hotkey import HotkeyRouter
from flow.core.vad import make_vad
from flow.insert.inserter import Inserter
from flow.models.asr_base import ASRBackend, ASRResult
from flow.models.cleanup import CleanupLLM
from flow.models.command import CommandLLM
from flow.models.parakeet import ParakeetASR
from flow.models.qwen3_asr import Qwen3ASR
from flow.models.whisper_mlx import WhisperASR
from flow.personalize.edit_watch import EditWatcher
from flow.personalize.snippets import SnippetStore
from flow.personalize.store import CorrectionStore
from flow.ui import stream


def _make_asr(model_id: str) -> ASRBackend:
    """Pick ASR backend based on model id substring."""
    lower = model_id.lower()
    if "whisper" in lower:
        return WhisperASR(model_id)
    if "qwen3-asr" in lower:
        return Qwen3ASR(model_id)
    return ParakeetASR(model_id)

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
        self.style_resolver = StyleResolver()
        self.snippets = SnippetStore.open_default()
        self.inserter = Inserter(cfg.insertion)
        self.corrections = CorrectionStore.open_default()
        self.edit_watcher = EditWatcher(
            window_seconds=cfg.personalization.edit_watch_window_seconds,
            store=self.corrections,
            dictionary=self.dictionary,
            auto_add=cfg.personalization.auto_add_to_dictionary,
        )

        console.print(f"[dim]loading ASR ({cfg.asr.speed.model})...[/]")
        self.asr_speed: ASRBackend = _make_asr(cfg.asr.speed.model)
        self.asr_accuracy: ASRBackend | None = None  # lazy
        console.print("[dim]loading cleanup LLM...[/]")
        self.cleanup = CleanupLLM(cfg.cleanup)

        # Command Mode shares audio + speed ASR with the dictate path. The
        # transform LLM is lazy-loaded on first invocation so it costs no
        # RAM until the user actually triggers it.
        self.command_llm = CommandLLM(cfg.command)
        self.command_ctrl = CommandModeController(
            cfg=cfg,
            audio=self.audio,
            asr=self.asr_speed,
            llm=self.command_llm,
            verbose=verbose,
        )

        # Pipeline state — initialized here, not in _emit_stats.
        self._busy = asyncio.Lock()
        self._utterance_task: asyncio.Task | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._recording_active = False
        self._prefetched_app_ctx = None

        # Streaming / pre-flight ASR state
        self._stream_stop = threading.Event()
        self._stream_thread: threading.Thread | None = None
        self._last_partial_text: str = ""
        self._last_partial_samples: int = 0
        self._stream_lock = threading.Lock()

        # Wire up the max-duration auto-stop so AudioCapture can trigger
        # the same pipeline as a normal key-up when the limit is hit.
        self.audio.set_on_max_reached(self._on_max_duration_reached)

        # Start the dashboard event stream socket
        stream.get_server()
        self._emit_stats()
        stream.emit({"type": "ready"})

    def _emit_stats(self) -> None:
        stream.emit({
            "type": "stats",
            "dict_size": len(self.dictionary.boost_terms()) + len(self.dictionary.replacements()),
            "snippet_count": self.snippets.count(),
            "correction_count": 0,
            "styles": {
                "personal_messages": self.cfg.styles.personal_messages,
                "work_messages": self.cfg.styles.work_messages,
                "email": self.cfg.styles.email,
                "other": self.cfg.styles.other,
            },
        })

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

    # ---- Max-duration auto-stop ------------------------------------------

    def _on_max_duration_reached(self) -> None:
        """Called from AudioCapture's timer thread when max_seconds expires.

        Schedules on_up() on the event loop so the full pipeline runs just
        as if the user released the hotkey.
        """
        if self._loop is not None:
            self._loop.call_soon_threadsafe(self.on_up)

    # ---- Hotkey callbacks -------------------------------------------------

    def on_down(self) -> None:
        if self.verbose:
            console.print("[cyan]⏺ recording[/]")
        self._recording_active = True
        self.audio.start()
        stream.emit({"type": "recording", "state": "start"})
        # Capture app context NOW — the focused app won't change while the
        # user holds the hotkey, and this saves ~100ms of socket RPC from
        # the latency-critical _process() path after key release.
        self._prefetched_app_ctx = self.app_context.snapshot()
        # Reset partial state and launch the streaming ASR loop.
        with self._stream_lock:
            self._last_partial_text = ""
            self._last_partial_samples = 0
        if self.cfg.asr.streaming:
            self._stream_stop = threading.Event()
            self._stream_thread = threading.Thread(
                target=self._stream_partials_loop, daemon=True
            )
            self._stream_thread.start()

    def on_up(self) -> None:
        if not self._recording_active:
            return  # guard against double-fire (max-duration + key release)
        self._recording_active = False
        if self.verbose:
            console.print("[cyan]⏹ processing[/]")
        # Signal the streaming loop to stop, then drain the trailing audio
        # window. audio.stop() sleeps cfg.trailing_ms before snapshotting,
        # which gives the partial thread time to wind down in parallel.
        self._stream_stop.set()
        audio = self.audio.stop()
        stream.emit({"type": "recording", "state": "stop"})
        if self._stream_thread is not None:
            # The streaming loop checks _stream_stop every interval (~200ms).
            # audio.stop() already slept trailing_ms (250ms) so the thread
            # should have exited by now. Short timeout for safety.
            self._stream_thread.join(timeout=0.3)
            self._stream_thread = None
        if audio.size == 0:
            return
        # No final ASR here — _process() uses pre-flight reuse for long
        # recordings (partial covers >99% of audio) and runs a fast fresh
        # ASR for short ones. This eliminates 80-500ms of event-loop blocking.
        self._utterance_task = asyncio.create_task(self._process(audio))

    # ---- Streaming partial ASR loop --------------------------------------

    def _stream_partials_loop(self) -> None:
        """Run speed ASR against the growing audio buffer while recording.

        Emits `partial` events to the dashboard/HUD and caches the latest
        transcript so `_process` can skip the final ASR pass when the
        partial already covers ~all of the final audio (pre-flight ASR).
        """
        sr = self.cfg.audio.sample_rate
        interval = max(0.05, self.cfg.asr.streaming_interval_ms / 1000.0)
        min_samples = int(sr * self.cfg.asr.streaming_min_audio_ms / 1000.0)
        while not self._stream_stop.is_set():
            if self._stream_stop.wait(interval):
                break
            snap = self.audio.snapshot()
            if snap.size < min_samples:
                continue
            try:
                result = self.asr_speed.transcribe(snap, sample_rate=sr)
            except Exception as e:  # noqa: BLE001
                if self.verbose:
                    console.print(f"[yellow]partial asr failed: {e}[/]")
                continue
            text = (result.text or "").strip()
            with self._stream_lock:
                self._last_partial_text = text
                self._last_partial_samples = int(snap.size)
            stream.emit({"type": "partial", "text": text})

    # ---- Main per-utterance pipeline -------------------------------------

    async def _process(self, audio) -> None:
        async with self._busy:
            t0 = time.perf_counter()

            # 1. Use app context captured at key-down (saves ~100ms socket RPC).
            app_ctx = self._prefetched_app_ctx

            # 2. VAD trim
            trimmed = self.vad.trim(audio, sr=self.cfg.audio.sample_rate)
            t_vad = time.perf_counter()

            # 3. ASR (mode chosen per-app). If the streaming loop already
            #    transcribed ~all of this audio in the background, skip the
            #    final ASR pass entirely (pre-flight — IDEAS #2).
            mode = self._choose_mode(app_ctx)
            asr = self._get_asr(mode)
            boost_terms = self.dictionary.boost_terms()

            raw: ASRResult | None = None
            if (
                mode == "speed"
                and self.cfg.asr.streaming
                and trimmed.size > 0
            ):
                with self._stream_lock:
                    partial_text = self._last_partial_text
                    partial_samples = self._last_partial_samples
                # Compare partial coverage against the raw (pre-VAD) audio
                # size — that's what the partial was transcribed from. Using
                # trimmed.size here was apples-to-oranges and could silently
                # drop tail words when VAD shrank the final buffer.
                if (
                    partial_text
                    and partial_samples
                    >= int(audio.size * self.cfg.asr.streaming_reuse_ratio)
                ):
                    raw = ASRResult(text=partial_text, alternatives=[], language=None)
                    if self.verbose:
                        console.print("[dim magenta]pre-flight reuse ✓[/]")

            if raw is None:
                raw = asr.transcribe(
                    trimmed,
                    sample_rate=self.cfg.audio.sample_rate,
                    context_prompt=self._asr_context_prompt(app_ctx, boost_terms),
                )
            t_asr = time.perf_counter()

            if not raw.text.strip():
                return

            # 4. LLM cleanup with dynamic few-shots + per-app style instruction
            few_shots = self.few_shot.retrieve(raw.text, n=self.cfg.cleanup.few_shot_n)
            style_instr = self.style_resolver.instruction_for(
                self.cfg.styles,
                app_ctx.app_name if app_ctx else None,
                app_ctx.bundle_id if app_ctx else None,
            )
            cleaned = self.cleanup.clean(
                raw_transcript=raw.text,
                alt_hypotheses=raw.alternatives,
                app_context=app_ctx,
                dictionary_boost=boost_terms,
                few_shots=few_shots,
                style_instruction=style_instr,
            )
            t_llm = time.perf_counter()

            # 5. Deterministic dictionary replacements
            final = self.dictionary.apply_replacements(cleaned)
            # 6. Snippet expansion (post-cleanup, pre-insertion)
            final = self.snippets.apply(
                final,
                strip_punct_on_solo=self.cfg.snippets.strip_trailing_punct_on_solo_trigger,
            )

            # 7. Insert — everything above this line is latency-critical.
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

            # Emit to dashboard
            stream.emit({
                "type": "transcript",
                "raw": raw.text,
                "cleaned": final,
                "app": (app_ctx.app_name if app_ctx else "") or "",
                "vad_ms": (t_vad - t0) * 1000,
                "asr_ms": (t_asr - t_vad) * 1000,
                "llm_ms": (t_llm - t_asr) * 1000,
                "total_ms": (t_insert - t0) * 1000,
            })

            # ---- Post-insert (not latency-critical) ----
            # These run after the text is already pasted, so they don't
            # affect perceived speed. Release the _busy lock first so a
            # rapid follow-up dictation isn't blocked by WAV I/O.

        # Outside _busy lock: crash-recovery cleanup + edit watcher.
        # edit_watcher.arm() writes the audio WAV to disk which can take
        # tens of ms for long recordings — keeping it outside the lock
        # means the next dictation can start processing immediately.
        self.audio.cleanup_recovery()
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
            if len(boost_terms) > 200 and self.verbose:
                console.print(
                    f"[yellow]dictionary boost truncated: {len(boost_terms)} → 200 terms[/]"
                )
            parts.append("Vocabulary: " + ", ".join(boost_terms[:200]))
        return " ".join(parts) or None

    # ---- Main loop --------------------------------------------------------

    async def run_forever(self) -> None:
        self._loop = asyncio.get_running_loop()
        router = HotkeyRouter()
        router.register("dictate", self.on_down, self.on_up)
        if self.cfg.command.enabled:
            router.register(
                "command", self.command_ctrl.on_down, self.command_ctrl.on_up
            )
        actions = ", ".join(router.actions())
        console.print(f"[green]ready.[/] actions: {actions}")
        await router.run()
