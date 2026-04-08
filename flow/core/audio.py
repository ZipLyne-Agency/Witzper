"""Audio capture using sounddevice — 16 kHz mono ring buffer."""

from __future__ import annotations

import queue
import threading
from collections.abc import Iterator

import numpy as np
import sounddevice as sd

from flow.config import AudioCfg


class AudioCapture:
    """Push-to-talk audio capture. Call start() on key-down, stop() on key-up."""

    def __init__(self, cfg: AudioCfg):
        self.cfg = cfg
        self._q: queue.Queue[np.ndarray] = queue.Queue()
        self._stream: sd.InputStream | None = None
        self._recording = threading.Event()
        self._frames: list[np.ndarray] = []
        # Open the input stream once now so macOS prompts for mic permission
        # immediately on daemon startup rather than on first hotkey press.
        self._warmup()

    def _warmup(self) -> None:
        try:
            warmup = sd.InputStream(
                samplerate=self.cfg.sample_rate,
                channels=self.cfg.channels,
                dtype="float32",
                blocksize=int(self.cfg.sample_rate * 0.03),
            )
            warmup.start()
            warmup.stop()
            warmup.close()
        except Exception as e:  # noqa: BLE001
            print(f"[flow] mic warmup failed: {e}")

    def _callback(self, indata, frames, time_info, status) -> None:  # noqa: ARG002
        if status:
            # Under-run / over-run; ignore for now, log in verbose mode.
            pass
        if self._recording.is_set():
            self._q.put(indata.copy())

    def _resolve_device(self):
        """Map cfg.audio.device (string name or 'default') to a sounddevice index."""
        name = (self.cfg.device or "default").strip()
        if name == "default" or name == "":
            return None
        # Try exact match against available input devices
        for i, dev in enumerate(sd.query_devices()):
            if dev.get("max_input_channels", 0) > 0 and dev.get("name") == name:
                return i
        # Fallback: substring match
        lname = name.lower()
        for i, dev in enumerate(sd.query_devices()):
            if dev.get("max_input_channels", 0) > 0 and lname in dev.get("name", "").lower():
                return i
        print(f"[flow] mic '{name}' not found — using system default")
        return None

    def start(self) -> None:
        self._frames.clear()
        while not self._q.empty():
            self._q.get_nowait()
        self._recording.set()
        if self._stream is None:
            self._stream = sd.InputStream(
                samplerate=self.cfg.sample_rate,
                channels=self.cfg.channels,
                dtype="float32",
                callback=self._callback,
                blocksize=int(self.cfg.sample_rate * 0.03),  # 30 ms blocks
                device=self._resolve_device(),
            )
            self._stream.start()

    def _drain(self) -> None:
        while not self._q.empty():
            try:
                self._frames.append(self._q.get_nowait())
            except queue.Empty:
                break

    def snapshot(self) -> np.ndarray:
        """Return the audio captured so far without stopping the stream.

        Used by the streaming/pre-flight ASR loop to run the ASR model
        against the live buffer while the user is still holding the hotkey.
        """
        self._drain()
        if not self._frames:
            return np.zeros(0, dtype=np.float32)
        audio = np.concatenate(self._frames, axis=0)
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        return audio.astype(np.float32)

    def stop(self) -> np.ndarray:
        """Stop recording and return the captured mono waveform as float32 [-1, 1]."""
        self._recording.clear()
        return self.snapshot()

    def close(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    def stream_chunks(self) -> Iterator[np.ndarray]:
        """Yield audio chunks live while recording — used for streaming VAD."""
        while self._recording.is_set():
            try:
                yield self._q.get(timeout=0.1)
            except queue.Empty:
                continue
