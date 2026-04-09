"""Voice activity detection + endpoint trimming.

Default backend is Silero via the `silero-vad` pip package running under
onnxruntime — no torch dependency. Pyannote remains available as an optional
backend for users who install the `[pyannote]` extras (pulls in torch).
Both trim leading/trailing silence from a full utterance and return a clean
waveform.
"""

from __future__ import annotations

from typing import Protocol

import numpy as np

from flow.config import VadCfg

# Keep this much audio after the last detected speech sample. Stop consonants
# (/t/, /k/, /p/) and final fricatives have low energy that VAD often marks
# as silence — trimming to the exact boundary clips them and hurts ASR on the
# last word. 150 ms is below perceptual latency and well inside the ASR's
# tolerance for trailing silence.
_TRAIL_PAD_MS = 150
_LEAD_PAD_MS = 60


class VADBackend(Protocol):
    def trim(self, audio: np.ndarray, sr: int) -> np.ndarray: ...


class SileroVAD:
    """Silero VAD running on onnxruntime.

    Uses the `silero-vad` pip package with `onnx=True` so we don't pull in
    torch (~900 MB). Quality is identical — same checkpoint, different
    runtime. onnxruntime adds ~15 MB vs torch's ~900 MB.
    """

    def __init__(self):
        try:
            from silero_vad import get_speech_timestamps, load_silero_vad
        except ImportError as e:
            raise RuntimeError(
                "silero-vad not installed — pip install silero-vad onnxruntime"
            ) from e
        # onnx=True routes through onnxruntime instead of torch.
        self._model = load_silero_vad(onnx=True)
        self._get_speech_timestamps = get_speech_timestamps

    def trim(self, audio: np.ndarray, sr: int) -> np.ndarray:
        if audio.size == 0:
            return audio
        # The ONNX path accepts a numpy float32 array directly.
        wav = np.ascontiguousarray(audio, dtype=np.float32)
        ts = self._get_speech_timestamps(wav, self._model, sampling_rate=sr)
        if not ts:
            return audio  # fall through; let ASR handle silence
        start = max(0, ts[0]["start"] - int(sr * _LEAD_PAD_MS / 1000))
        end = min(audio.shape[0], ts[-1]["end"] + int(sr * _TRAIL_PAD_MS / 1000))
        return audio[start:end]


class PyannoteVAD:
    """pyannote segmentation 3.1 — optional, requires the [pyannote] extras."""

    def __init__(self, model_id: str = "pyannote/segmentation-3.1"):
        try:
            from pyannote.audio import Model
            from pyannote.audio.pipelines import VoiceActivityDetection
        except ImportError as e:
            raise RuntimeError(
                "pyannote.audio not installed — install with: "
                "uv pip install 'witzper[pyannote]' (pulls in torch)"
            ) from e
        model = Model.from_pretrained(model_id)
        self._pipeline = VoiceActivityDetection(segmentation=model)
        self._pipeline.instantiate({"min_duration_on": 0.1, "min_duration_off": 0.1})

    def trim(self, audio: np.ndarray, sr: int) -> np.ndarray:
        if audio.size == 0:
            return audio
        import torch  # local import — only reachable if extras are installed

        waveform = torch.from_numpy(audio).unsqueeze(0)
        vad = self._pipeline({"waveform": waveform, "sample_rate": sr})
        timeline = vad.get_timeline().support()
        if not timeline:
            return audio
        start = int(timeline[0].start * sr) - int(sr * _LEAD_PAD_MS / 1000)
        end = int(timeline[-1].end * sr) + int(sr * _TRAIL_PAD_MS / 1000)
        return audio[max(0, start) : min(len(audio), end)]


def make_vad(cfg: VadCfg) -> VADBackend:
    if cfg.backend == "silero":
        return SileroVAD()
    return PyannoteVAD(cfg.model)
