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
    # Hotkey registry back-compat: both default actions present.
    assert "dictate" in cfg.hotkeys
    assert "command" in cfg.hotkeys
