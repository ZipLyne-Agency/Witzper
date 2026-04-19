"""Parakeet TDT 0.6B v3 via parakeet-mlx — speed-mode ASR.

Fast path: we convert the incoming float32 numpy audio directly to an mx.array
and feed it through `get_logmel` + `model.generate`, skipping the tempfile
write/read that parakeet-mlx's `transcribe(path)` helper performs. This saves
a few milliseconds per utterance and, more importantly, removes disk I/O from
the latency-critical path.

We also expose a lightweight `start_stream()` for incremental partial ASR so
the orchestrator doesn't have to re-transcribe the full buffer every
streaming tick.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import numpy as np

from flow.models.asr_base import ASRResult

if TYPE_CHECKING:  # keep mlx import out of the cold-load path
    import mlx.core as mx


class ParakeetASR:
    """Thin wrapper around senstella/parakeet-mlx.

    Keeps the model loaded on the GPU. Every call flows numpy → mx.array →
    log-mel → generate, with no disk intermediate.
    """

    def __init__(self, model_id: str):
        try:
            from parakeet_mlx import from_pretrained
        except ImportError as e:
            raise RuntimeError("pip install parakeet-mlx") from e
        self._model = from_pretrained(model_id)
        self._preprocess = self._model.preprocessor_config
        self._sample_rate = self._preprocess.sample_rate

        # Warm up the kernels so the very first user utterance isn't cold.
        # A 100ms silence is enough to JIT-compile all the mx kernels used
        # by the encoder / joint / predictor; subsequent calls drop to
        # steady-state latency (~50-100ms on M-series for a 3s utterance).
        try:
            import mlx.core as mx

            silence = mx.zeros(int(self._sample_rate * 0.1), dtype=mx.float32)
            from parakeet_mlx.audio import get_logmel

            mel = get_logmel(silence, self._preprocess)
            self._model.generate(mel)
        except Exception:  # noqa: BLE001 — warmup is best-effort
            pass

    # ------------------------------------------------------------------

    def transcribe(
        self,
        audio: np.ndarray,
        sample_rate: int,
        context_prompt: str | None = None,  # noqa: ARG002 — reserved for future use
    ) -> ASRResult:
        """One-shot transcription of a completed utterance.

        Parakeet doesn't support initial-prompt biasing the way Whisper does,
        so the caller-provided `context_prompt` is ignored here. Boost terms
        are applied downstream in `flow/context/dictionary.py` via the cleanup
        LLM + deterministic replacements path, which gives more reliable
        results than soft-biasing the acoustic decoder anyway.
        """
        if audio.size == 0:
            return ASRResult(text="")
        from parakeet_mlx.audio import get_logmel

        arr = _to_mx(audio, sample_rate, self._sample_rate)
        mel = get_logmel(arr, self._preprocess)
        results = self._model.generate(mel)
        text = (results[0].text if results else "").strip()
        return ASRResult(text=text, alternatives=[], language=None)

    # ------------------------------------------------------------------
    # Streaming helpers — used by the orchestrator's partial-ASR loop so
    # we don't pay O(N²) work re-transcribing the full buffer every tick.
    # ------------------------------------------------------------------

    def supports_streaming(self) -> bool:
        return hasattr(self._model, "transcribe_stream")

    def open_stream(self):
        """Open a streaming transcription context.

        Returns a `StreamingParakeet` object (from parakeet-mlx). The caller
        feeds audio chunks via `add_audio(chunk_mx_array)` and reads
        `transcriber.result.text` to get the current transcript.

        The caller is responsible for closing the context when done — use
        it as a context manager.
        """
        if not self.supports_streaming():
            raise RuntimeError("parakeet-mlx does not expose transcribe_stream")
        return self._model.transcribe_stream()


def _to_mx(audio: np.ndarray, sample_rate: int, target_sr: int) -> mx.array:
    """Convert a numpy float32 buffer into an mx.array at the model's sample
    rate. We assume the AudioCapture layer already matches target_sr (16 kHz
    for Parakeet), which it does by default, so this is just a dtype cast.
    """
    import mlx.core as mx

    if sample_rate != target_sr:
        # Resample. Rare path — only triggered if the user reconfigures
        # audio.sample_rate away from the default.
        import librosa

        audio = librosa.resample(audio.astype(np.float32), orig_sr=sample_rate, target_sr=target_sr)
    if audio.dtype != np.float32:
        audio = audio.astype(np.float32)
    return mx.array(audio)
