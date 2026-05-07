import tomli

import flow.config
from flow.__main__ import style


def test_style_command_preserves_nested_hotkey_config(tmp_path, monkeypatch) -> None:
    cfg_path = tmp_path / "config.toml"
    cfg_path.write_text(
        """
[hotkeys.dictate]
key = "right_shift"
mode = "hold"

[hotkeys.command]
key = "right_cmd+right_option"
mode = "hold"
""".strip()
    )
    monkeypatch.setattr(flow.config, "USER_CONFIG_PATH", cfg_path)

    style("email", "formal")

    with cfg_path.open("rb") as f:
        data = tomli.load(f)

    assert data["hotkeys"]["dictate"]["key"] == "right_shift"
    assert data["hotkeys"]["command"]["key"] == "right_cmd+right_option"
    assert data["styles"]["email"] == "formal"
