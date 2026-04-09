"""Typed configuration loaded from TOML."""

from __future__ import annotations

from pathlib import Path
from typing import Literal

import tomli
from pydantic import BaseModel, Field

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent.parent / "configs" / "default.toml"
USER_CONFIG_PATH = Path.home() / ".config" / "Witzper" / "config.toml"


class HotkeyCfg(BaseModel):
    """Legacy single-hotkey config. Superseded by `hotkeys` (action map),
    but kept so old user configs keep parsing. `load_config` migrates this
    into `hotkeys["dictate"]` on read.
    """

    key: str = "fn"
    toggle_mode: bool = False


class HotkeyBinding(BaseModel):
    """One configurable shortcut. `key` is a hotkey name like ``fn`` or a
    chord like ``right_cmd+right_option``. ``mode`` is ``hold`` (push-to-
    talk) or ``tap`` (single-press toggle, not yet implemented for chords).
    Empty `key` disables the binding.
    """

    key: str = ""
    mode: Literal["hold", "tap"] = "hold"


class AudioCfg(BaseModel):
    sample_rate: int = 16000
    channels: int = 1
    device: str = "default"
    max_seconds: int = 120
    # Keep recording for this many ms AFTER the user releases the hotkey.
    # CoreAudio delivers in ~30 ms blocks and humans release the key at the
    # exact instant they finish speaking — without this pad, the last word's
    # tail gets chopped. 250 ms is imperceptible to the user but captures the
    # final fricatives / stop releases reliably.
    trailing_ms: int = 250


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
    # Streaming partial transcripts + pre-flight ASR (IDEAS #1, #2).
    # While the hotkey is held, we run the speed ASR on the growing audio
    # buffer every `streaming_interval_ms`, emit `partial` events to the
    # dashboard/HUD, and — on key release — reuse the last partial as the
    # raw transcript if it covered ≥`streaming_reuse_ratio` of the final
    # audio, skipping the serial final ASR pass.
    streaming: bool = True
    streaming_interval_ms: int = 350
    streaming_min_audio_ms: int = 350
    streaming_reuse_ratio: float = 0.95


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
    # Legacy: hotkey now lives in [hotkeys.command]. Kept for back-compat.
    hotkey: str = ""


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
    email: str = "casual"
    other: str = "casual"


class SnippetsCfg(BaseModel):
    case_insensitive: bool = True
    strip_trailing_punct_on_solo_trigger: bool = True


def _default_hotkeys() -> dict[str, HotkeyBinding]:
    return {
        "dictate": HotkeyBinding(key="fn", mode="hold"),
        "command": HotkeyBinding(key="right_cmd+right_option", mode="hold"),
    }


class Config(BaseModel):
    hotkey: HotkeyCfg = Field(default_factory=HotkeyCfg)
    hotkeys: dict[str, HotkeyBinding] = Field(default_factory=_default_hotkeys)
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
    user_data: dict = {}
    if candidate and candidate.exists():
        with candidate.open("rb") as f:
            user_data = tomli.load(f)

    # Migrate legacy keys *before* merging so user configs that only set
    # `[hotkey] key = "..."` or `[command] hotkey = "..."` keep working.
    if isinstance(user_data.get("hotkey"), dict) and "key" in user_data["hotkey"]:
        user_data.setdefault("hotkeys", {})
        user_data["hotkeys"].setdefault(
            "dictate", {"key": user_data["hotkey"]["key"], "mode": "hold"}
        )
    if (
        isinstance(user_data.get("command"), dict)
        and user_data["command"].get("hotkey")
    ):
        user_data.setdefault("hotkeys", {})
        user_data["hotkeys"].setdefault(
            "command", {"key": user_data["command"]["hotkey"], "mode": "hold"}
        )

    data = _merge(data, user_data)
    return Config(**data)
