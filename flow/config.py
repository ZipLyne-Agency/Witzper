"""Typed configuration loaded from TOML."""

from __future__ import annotations

from pathlib import Path
from typing import Literal

import tomli
from pydantic import BaseModel, Field

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent.parent / "configs" / "default.toml"
USER_CONFIG_PATH = Path.home() / ".config" / "flow-local" / "config.toml"


class HotkeyCfg(BaseModel):
    key: str = "fn"
    toggle_mode: bool = False


class AudioCfg(BaseModel):
    sample_rate: int = 16000
    channels: int = 1
    device: str = "default"
    max_seconds: int = 120


class VadCfg(BaseModel):
    backend: Literal["pyannote", "silero"] = "pyannote"
    model: str = "pyannote/segmentation-3.1"
    endpoint_silence_ms: int = 700


class AsrModeCfg(BaseModel):
    model: str
    backend: str
    context_prompt_max_tokens: int = 1024


class AsrCfg(BaseModel):
    mode: Literal["speed", "accuracy", "auto"] = "auto"
    speed: AsrModeCfg
    accuracy: AsrModeCfg


class CleanupCfg(BaseModel):
    model: str
    max_tokens: int = 256
    temperature: float = 0.2
    few_shot_n: int = 5
    max_length_ratio: float = 3.0
    max_edit_distance_ratio: float = 0.7


class CommandCfg(BaseModel):
    enabled: bool = True
    model: str
    max_tokens: int = 2048
    hotkey: str = "right_cmd+right_option"


class InsertionCfg(BaseModel):
    default_strategy: Literal["paste", "type"] = "paste"
    restore_clipboard_after_ms: int = 200


class PersonalizationCfg(BaseModel):
    auto_add_to_dictionary: bool = True
    edit_watch_window_seconds: int = 10
    cleanup_lora_enabled: bool = True
    cleanup_lora_rank: int = 16
    cleanup_lora_schedule_cron: str = "0 3 * * *"
    asr_lora_enabled: bool = True
    asr_lora_rank: int = 8
    asr_lora_schedule_cron: str = "0 4 */14 * *"
    dspy_enabled: bool = True


class UiCfg(BaseModel):
    menu_bar_icon: bool = True
    floating_pill: bool = True


class TelemetryCfg(BaseModel):
    enabled: bool = False


class StylesCfg(BaseModel):
    personal_messages: str = "casual"
    work_messages: str = "casual"
    email: str = "formal"
    other: str = "casual"


class SnippetsCfg(BaseModel):
    case_insensitive: bool = True
    strip_trailing_punct_on_solo_trigger: bool = True


class Config(BaseModel):
    hotkey: HotkeyCfg = Field(default_factory=HotkeyCfg)
    audio: AudioCfg = Field(default_factory=AudioCfg)
    vad: VadCfg = Field(default_factory=VadCfg)
    asr: AsrCfg
    cleanup: CleanupCfg
    command: CommandCfg
    insertion: InsertionCfg = Field(default_factory=InsertionCfg)
    personalization: PersonalizationCfg = Field(default_factory=PersonalizationCfg)
    ui: UiCfg = Field(default_factory=UiCfg)
    telemetry: TelemetryCfg = Field(default_factory=TelemetryCfg)
    styles: StylesCfg = Field(default_factory=StylesCfg)
    snippets: SnippetsCfg = Field(default_factory=SnippetsCfg)


def _merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for k, v in override.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def load_config(path: Path | None = None) -> Config:
    with DEFAULT_CONFIG_PATH.open("rb") as f:
        data = tomli.load(f)
    candidate = path or (USER_CONFIG_PATH if USER_CONFIG_PATH.exists() else None)
    if candidate and candidate.exists():
        with candidate.open("rb") as f:
            data = _merge(data, tomli.load(f))
    return Config(**data)
