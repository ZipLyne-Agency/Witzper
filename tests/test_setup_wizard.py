import tomli

from flow.core import setup_wizard


def test_write_user_config_preserves_dotted_hotkey_section(tmp_path, monkeypatch) -> None:
    cfg_path = tmp_path / "config.toml"
    cfg_path.write_text(
        """
[cleanup]
model = "mlx-community/Qwen3-8B-4bit"

[hotkeys.command]
key = "right_cmd+right_option"
mode = "hold"
""".strip()
    )
    monkeypatch.setattr(setup_wizard, "USER_CONFIG_PATH", cfg_path)

    setup_wizard.write_user_config("fn")

    with cfg_path.open("rb") as f:
        data = tomli.load(f)

    assert data["cleanup"]["model"] == "mlx-community/Qwen3-8B-4bit"
    assert data["hotkey"]["key"] == "fn"
    assert data["hotkeys"]["dictate"] == {"key": "fn", "mode": "hold"}
    assert data["hotkeys"]["command"]["key"] == "right_cmd+right_option"
