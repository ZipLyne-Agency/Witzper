import tomli

from flow.core.user_config import update_user_config


def test_update_user_config_preserves_nested_sections(tmp_path) -> None:
    cfg_path = tmp_path / "config.toml"
    cfg_path.write_text(
        """
[hotkeys.dictate]
key = "right_cmd"
mode = "hold"

[hotkeys.command]
key = "right_cmd+right_option"
mode = "hold"
""".strip()
    )

    def mutate(data: dict) -> None:
        data.setdefault("styles", {})["email"] = "formal"

    update_user_config(cfg_path, mutate)

    with cfg_path.open("rb") as f:
        data = tomli.load(f)

    assert data["hotkeys"]["dictate"] == {"key": "right_cmd", "mode": "hold"}
    assert data["hotkeys"]["command"] == {
        "key": "right_cmd+right_option",
        "mode": "hold",
    }
    assert data["styles"]["email"] == "formal"
