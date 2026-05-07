import asyncio

import numpy as np
import pytest

from flow.config import Config
from flow.core.command_mode import CommandModeController
from flow.models.asr_base import ASRResult


class FakeAudio:
    def __init__(self, stop_audio: np.ndarray | None = None) -> None:
        self.started = 0
        self.stopped = 0
        self.stop_audio = stop_audio if stop_audio is not None else np.ones(4, dtype=np.float32)

    def start(self) -> None:
        self.started += 1

    def stop(self) -> np.ndarray:
        self.stopped += 1
        return self.stop_audio


class FakeASR:
    def transcribe(self, audio: np.ndarray, sample_rate: int) -> ASRResult:
        return ASRResult(text="rewrite this")

    def supports_streaming(self) -> bool:
        return False

    def open_stream(self):
        raise RuntimeError("not supported")


class FakeLLM:
    def run(self, instruction: str, source_text: str) -> str:
        return f"{instruction}: {source_text}"


def _cfg() -> Config:
    return Config.model_validate(
        {
            "asr": {
                "speed": {"model": "stub", "backend": "stub"},
                "accuracy": {"model": "stub", "backend": "stub"},
            },
            "cleanup": {"model": "stub"},
            "command": {"enabled": True, "model": "stub"},
        }
    )


@pytest.mark.asyncio
async def test_command_mode_ignores_key_up_without_key_down(monkeypatch) -> None:
    audio = FakeAudio()
    controller = CommandModeController(_cfg(), audio, FakeASR(), FakeLLM())
    monkeypatch.setattr(controller, "_show_result", lambda *args, **kwargs: None)

    controller.on_up()
    await asyncio.sleep(0)

    assert audio.started == 0
    assert audio.stopped == 0
    assert controller._task is None


@pytest.mark.asyncio
async def test_command_mode_ignores_repeated_key_down(monkeypatch) -> None:
    audio = FakeAudio(stop_audio=np.zeros(0, dtype=np.float32))
    controller = CommandModeController(_cfg(), audio, FakeASR(), FakeLLM())
    monkeypatch.setattr(controller, "_capture_selection", lambda: "selected")

    controller.on_down()
    controller.on_down()
    controller.on_up()
    await asyncio.sleep(0)

    assert audio.started == 1
    assert audio.stopped == 1
