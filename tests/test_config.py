from flow.config import load_config


def test_default_config_loads() -> None:
    cfg = load_config()
    assert cfg.asr.speed.model.startswith("mlx-community/parakeet")
    assert "Qwen3-30B-A3B" in cfg.cleanup.model
    assert cfg.personalization.auto_add_to_dictionary is True
