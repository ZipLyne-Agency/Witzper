import re
from pathlib import Path

import tomli

from flow.config import DEFAULT_CONFIG_PATH

ROOT = Path(__file__).resolve().parent.parent


def test_default_cleanup_model_is_documented_and_in_swift_catalog() -> None:
    with DEFAULT_CONFIG_PATH.open("rb") as f:
        default_cleanup = tomli.load(f)["cleanup"]["model"]

    catalog = (ROOT / "swift-helper/Sources/FlowHelper/ModelCatalog.swift").read_text()
    readme = (ROOT / "README.md").read_text()
    downloads = (ROOT / "scripts/download_models.sh").read_text()

    assert f'id: "{default_cleanup}"' in catalog
    assert f"`{default_cleanup}`" in readme
    assert default_cleanup in downloads


def test_swift_settings_fallback_uses_default_cleanup_model() -> None:
    with DEFAULT_CONFIG_PATH.open("rb") as f:
        default_cleanup = tomli.load(f)["cleanup"]["model"]

    settings = (ROOT / "swift-helper/Sources/FlowHelper/SettingsView.swift").read_text()

    fallback_match = re.search(r'readModelFromConfig\(section: "cleanup"\) \?\? "([^"]+)"', settings)
    assert fallback_match is not None
    assert fallback_match.group(1) == default_cleanup


def test_readme_does_not_advertise_automatic_lora() -> None:
    readme = (ROOT / "README.md").read_text()

    assert "Nightly cleanup LoRA" not in readme
    assert "Biweekly ASR LoRA" not in readme
    assert "Manual cleanup LoRA" in readme
    assert "ASR LoRA manifest export" in readme


def test_package_version_matches_release_version_file() -> None:
    version = (ROOT / "VERSION").read_text().strip()
    with (ROOT / "pyproject.toml").open("rb") as f:
        pyproject = tomli.load(f)

    assert pyproject["project"]["version"] == version


def test_release_script_updates_pyproject_version_with_version_file() -> None:
    release_script = (ROOT / "scripts" / "release.sh").read_text()

    assert "pyproject.toml" in release_script
    assert "git add VERSION pyproject.toml" in release_script
