"""Common ASR interface."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol

import numpy as np


@dataclass
class ASRResult:
    text: str
    alternatives: list[str] = field(default_factory=list)
    language: str | None = None


class ASRBackend(Protocol):
    def transcribe(
        self,
        audio: np.ndarray,
        sample_rate: int,
        context_prompt: str | None = None,
    ) -> ASRResult: ...

    def supports_streaming(self) -> bool: ...

    def open_stream(self) -> Any: ...
