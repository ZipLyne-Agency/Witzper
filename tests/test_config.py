from flow.config import DEFAULT_CONFIG_PATH, load_config


def test_default_config_loads() -> None:
    # Load the shipped default directly so the test isn't sensitive to
    # whichever model the current user happens to have selected in their
    # ~/.config/Witzper/config.toml override.
    cfg = load_config(DEFAULT_CONFIG_PATH)
    assert cfg.asr.speed.model.startswith("mlx-community/parakeet")
    # Default cleanup is Qwen3 8B (~4.5 GB) — the 30B is now opt-in for
    # power users via the Settings tab. See ModelCatalog.swift.
    assert "Qwen3-8B" in cfg.cleanup.model
    assert cfg.personalization.auto_add_to_dictionary is True
    assert cfg.audio.preroll_ms == 300
    assert cfg.audio.trailing_ms == 650
    assert cfg.asr.streaming_reuse_ratio >= 0.98
    assert cfg.asr.streaming_max_untranscribed_ms == 250
    assert cfg.personalization.cleanup_lora_enabled is False
    assert cfg.personalization.asr_lora_enabled is False
    assert cfg.personalization.dspy_enabled is False
    # Hotkey registry back-compat: both default actions present.
    assert "dictate" in cfg.hotkeys
    assert "command" in cfg.hotkeys


def test_hotkeys_dictate_override_wins(tmp_path) -> None:
    cfg_path = tmp_path / "config.toml"
    cfg_path.write_text(
        """
[hotkeys.dictate]
key = "right_cmd"
mode = "hold"
""".strip()
    )

    cfg = load_config(cfg_path)

    assert cfg.hotkeys["dictate"].key == "right_cmd"


def test_legacy_hotkey_migrates_to_dictate_binding(tmp_path) -> None:
    cfg_path = tmp_path / "config.toml"
    cfg_path.write_text(
        """
[hotkey]
key = "caps_lock"
toggle_mode = false
""".strip()
    )

    cfg = load_config(cfg_path)

    assert cfg.hotkeys["dictate"].key == "caps_lock"
