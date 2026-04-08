"""End-to-end pipeline test using a synthesized audio clip.

Generates speech with macOS `say`, then runs it through ASR + LLM cleanup
to verify every stage works in isolation from the hotkey/audio-capture path.
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from flow.config import load_config
from flow.models.cleanup import CleanupLLM
from flow.models.parakeet import ParakeetASR

TEST_PHRASE = (
    "um hello so this is a test of the flow local dictation system "
    "uh today is a great day and it is currently working perfectly"
)


def synth_audio(out_path: Path) -> None:
    print(f"→ synthesizing speech with `say` to {out_path}")
    aiff = out_path.with_suffix(".aiff")
    subprocess.run(
        ["say", "-v", "Samantha", "-r", "180", "-o", str(aiff), TEST_PHRASE],
        check=True,
    )
    # Convert AIFF → 16 kHz mono WAV
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", str(aiff),
            "-ar", "16000", "-ac", "1",
            str(out_path),
        ],
        check=True,
    )
    aiff.unlink(missing_ok=True)


def main() -> int:
    cfg = load_config()
    print(f"config loaded; ASR: {cfg.asr.speed.model}; LLM: {cfg.cleanup.model}")

    test_wav = Path("/tmp/flow-test.wav")
    synth_audio(test_wav)
    audio, sr = sf.read(test_wav)
    print(f"audio: {len(audio)/sr:.2f}s @ {sr} Hz, dtype={audio.dtype}")

    print("→ loading Parakeet")
    t0 = time.perf_counter()
    asr = ParakeetASR(cfg.asr.speed.model)
    print(f"  loaded in {time.perf_counter()-t0:.1f}s")

    print("→ transcribing")
    t0 = time.perf_counter()
    result = asr.transcribe(audio.astype(np.float32), sample_rate=sr)
    print(f"  done in {(time.perf_counter()-t0)*1000:.0f}ms")
    print(f"  raw: {result.text!r}")

    print("→ loading cleanup LLM (this takes ~15s on first call)")
    t0 = time.perf_counter()
    llm = CleanupLLM(cfg.cleanup)
    print(f"  loaded in {time.perf_counter()-t0:.1f}s")

    print("→ cleaning")
    t0 = time.perf_counter()
    cleaned = llm.clean(raw_transcript=result.text, few_shots=[])
    print(f"  done in {(time.perf_counter()-t0)*1000:.0f}ms")
    print(f"  cleaned: {cleaned!r}")

    print("\n✔ end-to-end pipeline works")
    return 0


if __name__ == "__main__":
    sys.exit(main())
