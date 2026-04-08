"""Voice activity detection + endpoint trimming.

Supports pyannote segmentation 3.1 (SOTA) and Silero (lighter fallback).
Both trim leading/trailing silence from a full utterance and return a clean waveform.
"""

from __future__ import annotations

from typing import Protocol

import numpy as np

from flow.config import VadCfg


class VADBackend(Protocol):
    def trim(self, audio: np.ndarray, sr: int) -> np.ndarray: ...


class SileroVAD:
    """Silero VAD via the torch hub checkpoint. CPU-friendly."""

    def __init__(self):
        import torch

        self._torch = torch
        model, utils = torch.hub.load(
            "snakers4/silero-vad", "silero_vad", trust_repo=True, verbose=False
        )
        self._model = model
        self._get_speech_timestamps = utils[0]

    def trim(self, audio: np.ndarray, sr: int) -> np.ndarray:
        if audio.size == 0:
            return audio
        wav = self._torch.from_numpy(audio)
        ts = self._get_speech_timestamps(wav, self._model, sampling_rate=sr)
        if not ts:
            return audio  # fall through; let ASR handle silence
        start = ts[0]["start"]
        end = ts[-1]["end"]
        return audio[start:end]


class PyannoteVAD:
    """pyannote segmentation 3.1 — more robust, handles sub-vocal speech better."""

    def __init__(self, model_id: str = "pyannote/segmentation-3.1"):
        try:
            from pyannote.audio import Model
            from pyannote.audio.pipelines import VoiceActivityDetection
        except ImportError as e:
            raise RuntimeError(
                "pyannote.audio not installed — pip install pyannote.audio"
            ) from e
        model = Model.from_pretrained(model_id)
        self._pipeline = VoiceActivityDetection(segmentation=model)
        self._pipeline.instantiate({"min_duration_on": 0.1, "min_duration_off": 0.1})

    def trim(self, audio: np.ndarray, sr: int) -> np.ndarray:
        if audio.size == 0:
            return audio
        import torch

        waveform = torch.from_numpy(audio).unsqueeze(0)
        vad = self._pipeline({"waveform": waveform, "sample_rate": sr})
        timeline = vad.get_timeline().support()
        if not timeline:
            return audio
        start = int(timeline[0].start * sr)
        end = int(timeline[-1].end * sr)
        return audio[max(0, start) : min(len(audio), end)]


def make_vad(cfg: VadCfg) -> VADBackend:
    if cfg.backend == "silero":
        return SileroVAD()
    return PyannoteVAD(cfg.model)
