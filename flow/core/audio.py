"""Audio capture using sounddevice — 16 kHz mono ring buffer."""

from __future__ import annotations

import queue
import tempfile
import threading
import time
import uuid
from collections.abc import Iterator
from pathlib import Path

import numpy as np
import sounddevice as sd

from flow.config import AudioCfg

# Crash-safe audio is flushed here so a long recording survives a crash.
_RECOVERY_DIR = Path.home() / ".local" / "share" / "Witzper" / "recovery"

# How often (in seconds) to flush audio to the recovery file while recording.
_FLUSH_INTERVAL_S = 10


class AudioCapture:
    """Push-to-talk audio capture. Call start() on key-down, stop() on key-up."""

    def __init__(self, cfg: AudioCfg):
        self.cfg = cfg
        self._q: queue.Queue[np.ndarray] = queue.Queue()
        self._stream: sd.InputStream | None = None
        self._recording = threading.Event()
        self._frames: list[np.ndarray] = []
        # Incremental snapshot cache — avoids re-concatenating all frames on
        # every snapshot() call, which was O(n²) over the recording duration.
        self._concat_cache: np.ndarray = np.zeros(0, dtype=np.float32)
        self._concat_frames_count: int = 0
        # Max-duration auto-stop callback (set by caller via on_max_reached).
        self._on_max_reached: callable | None = None
        self._max_timer: threading.Timer | None = None
        # Crash-recovery: periodic WAV flush while recording.
        self._recovery_path: Path | None = None
        self._flush_timer: threading.Timer | None = None
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

    def set_on_max_reached(self, callback: callable) -> None:
        """Register a callback invoked (from a timer thread) when max_seconds
        is reached. The orchestrator uses this to trigger the same pipeline
        that a normal key-up would."""
        self._on_max_reached = callback

    def start(self) -> None:
        self._frames.clear()
        self._concat_cache = np.zeros(0, dtype=np.float32)
        self._concat_frames_count = 0
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
        # Enforce max_seconds: auto-stop after the configured limit so the
        # user never silently loses audio by recording past the cap.
        max_s = self.cfg.max_seconds
        if max_s > 0:
            self._max_timer = threading.Timer(max_s, self._auto_stop)
            self._max_timer.daemon = True
            self._max_timer.start()
        # Start periodic crash-recovery flush.
        self._start_recovery_flush()

    def _drain(self) -> None:
        while not self._q.empty():
            try:
                self._frames.append(self._q.get_nowait())
            except queue.Empty:
                break

    def snapshot(self) -> np.ndarray:
        """Return the audio captured so far without stopping the stream.

        Uses an incremental cache so only newly-arrived frames are
        concatenated — previous implementation re-concatenated *all* frames
        on every call, which was O(n²) over the recording duration and caused
        the streaming ASR loop to stall on long recordings.
        """
        self._drain()
        if not self._frames:
            return np.zeros(0, dtype=np.float32)
        n = len(self._frames)
        if n > self._concat_frames_count:
            new = self._frames[self._concat_frames_count:]
            new_block = np.concatenate(new, axis=0)
            if new_block.ndim > 1:
                new_block = new_block.mean(axis=1)
            new_block = new_block.astype(np.float32)
            if self._concat_cache.size == 0:
                self._concat_cache = new_block
            else:
                self._concat_cache = np.concatenate(
                    [self._concat_cache, new_block]
                )
            self._concat_frames_count = n
        return self._concat_cache

    def stop(self) -> np.ndarray:
        """Stop recording and return the captured mono waveform as float32 [-1, 1].

        Keeps the callback enqueueing for ``cfg.trailing_ms`` after the key
        release so we don't chop the tail of the user's final word — see
        ``AudioCfg.trailing_ms`` for the rationale.
        """
        # Cancel timers — we're stopping normally.
        if self._max_timer is not None:
            self._max_timer.cancel()
            self._max_timer = None
        self._stop_recovery_flush()
        trailing_ms = max(0, int(getattr(self.cfg, "trailing_ms", 0)))
        if trailing_ms > 0:
            time.sleep(trailing_ms / 1000.0)
        self._recording.clear()
        return self.snapshot()

    # ---- Max-duration auto-stop ------------------------------------------

    def _auto_stop(self) -> None:
        """Called from a Timer thread when max_seconds is reached."""
        if not self._recording.is_set():
            return
        print(f"[flow] max recording duration ({self.cfg.max_seconds}s) reached — auto-stopping")
        if self._on_max_reached:
            self._on_max_reached()

    # ---- Crash-recovery flush --------------------------------------------

    def _start_recovery_flush(self) -> None:
        _RECOVERY_DIR.mkdir(parents=True, exist_ok=True)
        self._recovery_path = _RECOVERY_DIR / f"{uuid.uuid4().hex}.wav"
        self._schedule_flush()

    def _schedule_flush(self) -> None:
        if not self._recording.is_set():
            return
        self._flush_timer = threading.Timer(_FLUSH_INTERVAL_S, self._flush_to_disk)
        self._flush_timer.daemon = True
        self._flush_timer.start()

    def _flush_to_disk(self) -> None:
        """Write accumulated audio to the recovery file."""
        if not self._recording.is_set():
            return
        try:
            audio = self.snapshot()
            if audio.size > 0 and self._recovery_path is not None:
                import soundfile as sf
                sf.write(str(self._recovery_path), audio, self.cfg.sample_rate)
        except Exception as e:  # noqa: BLE001
            print(f"[flow] recovery flush failed: {e}")
        self._schedule_flush()

    def _stop_recovery_flush(self) -> None:
        if self._flush_timer is not None:
            self._flush_timer.cancel()
            self._flush_timer = None

    def cleanup_recovery(self) -> None:
        """Delete the recovery file after a successful transcription."""
        if self._recovery_path is not None and self._recovery_path.exists():
            self._recovery_path.unlink(missing_ok=True)
            self._recovery_path = None

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
