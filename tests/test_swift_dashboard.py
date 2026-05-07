from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_dashboard_consumes_recording_and_command_events() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "Dashboard.swift"
    ).read_text()

    assert 'case "recording"' in source
    assert 'status = "LISTENING"' in source
    assert 'case "command"' in source
    assert 'status = "COMMAND PROCESSING"' in source


def test_dashboard_does_not_advertise_automatic_lora() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "Dashboard.swift"
    ).read_text()

    assert "LORA NIGHTLY" not in source
    assert 'kv("LORA", "MANUAL"' in source


def test_dashboard_has_manual_dictation_button() -> None:
    dashboard = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "Dashboard.swift"
    ).read_text()
    helper = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    assert "manualDictationButton" in dashboard
    assert "manualDictationStart()" in dashboard
    assert "manualDictationStop()" in dashboard
    assert "func manualDictationStart()" in helper
    assert "func manualDictationStop()" in helper
    assert "status.accessibility && status.microphone" in helper
    start_body = helper[
        helper.index("func manualDictationStart()"):
        helper.index("func manualDictationStop()")
    ]
    assert "status.allGranted" not in start_body
    assert '"hotkey_down"' in helper
    assert '"hotkey_up"' in helper
