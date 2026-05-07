from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_swift_hotkey_loader_preserves_default_command_binding() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    assert 'foundActions.contains("command")' in source
    assert 'appendBinding(action: "command", key: "right_cmd+right_option")' in source


def test_swift_hotkey_loader_preserves_default_dictate_binding() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    assert 'foundActions.contains("dictate")' in source
    assert 'appendBinding(action: "dictate", key: dictateKey)' in source


def test_swift_hotkeys_accept_printable_character_bindings() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()
    capture = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "HotkeyCapture.swift"
    ).read_text()

    assert "let printableKeycodes" in source
    assert '"a": 0' in source
    assert '"0": 29' in source
    assert "printableKeycodes[trimmed]" in source
    assert "printableKeyName(for:" in capture
    assert '0: "a"' in capture


def test_swift_hotkey_tap_swallows_printable_hotkey_events() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    assert "private func handle(type: CGEventType, event: CGEvent) -> Bool" in source
    assert "let consumed = this.handle(type: type, event: event)" in source
    assert "if consumed { return nil }" in source
