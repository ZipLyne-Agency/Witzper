from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_swift_app_termination_stops_daemon_and_removes_sockets() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    termination = source.split("func applicationWillTerminate", maxsplit=1)[1]
    termination = termination.split("func installMainMenu", maxsplit=1)[0]

    assert "stopPythonDaemon()" in termination
    assert 'unlink("/tmp/Witzper.sock")' in termination
    assert 'unlink("/tmp/flow-context.sock")' in termination
    assert 'unlink("/tmp/flow-stream.sock")' in termination


def test_swift_daemon_stop_uses_pid_file() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    stop_fn = source.split("func stopPythonDaemon", maxsplit=1)[1]
    stop_fn = stop_fn.split("@objc func menuRestartDaemon", maxsplit=1)[0]

    assert 'contentsOfFile: "/tmp/Witzper.pid"' in stop_fn
    assert "SIGTERM" in stop_fn
    assert 'unlink("/tmp/Witzper.pid")' in stop_fn


def test_settings_restart_uses_app_delegate_not_source_tree_shell() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "SettingsView.swift"
    ).read_text()

    restart_fn = source.split("private func restartDaemon", maxsplit=1)[1]
    restart_fn = restart_fn.split("\n    }\n}", maxsplit=1)[0]

    assert "restartPythonDaemon()" in restart_fn
    assert "nohup python" not in restart_fn
    assert "cd \\(home)/Witzper" not in restart_fn


def test_settings_shortcut_copy_requires_witzper_restart_not_daemon_restart() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "SettingsView.swift"
    ).read_text()

    assert "RESTART WITZPER TO APPLY SHORTCUT CHANGES" in source
    assert "SHORTCUT" in source
    assert "RESTART DAEMON BELOW" not in source


def test_menu_diagnostics_reports_all_required_permissions() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    diagnostics = source.split("@objc func showDiagnostics", maxsplit=1)[1]
    diagnostics = diagnostics.split("@objc func openAccessibility", maxsplit=1)[0]

    assert "Permissions.current()" in diagnostics
    assert "Accessibility (hotkey + AX context)" in diagnostics
    assert "Input Monitoring (global hotkey)" in diagnostics
    assert "Microphone" in diagnostics
    assert "If any permission is missing" in diagnostics


def test_context_rpc_can_simulate_hotkey_events_for_live_e2e() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    context_server = source.split("contextServer.start(requestHandler:", maxsplit=1)[1]
    context_server = context_server.split("return jsonString", maxsplit=1)[0]

    assert 'op == "simulate_hotkey"' in context_server
    assert "Permissions.current()" in context_server
    assert "!status.allGranted" in context_server
    assert '"permission_missing"' in context_server
    assert 'action == "dictate"' in context_server
    assert "unsupported_action" in context_server
    assert 'phase == "down"' in context_server
    assert 'phase == "up"' in context_server
    assert "hotkeyServer.broadcast" in context_server


def test_context_rpc_reports_hotkey_daemon_readiness_for_live_e2e() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    assert "func clientCount()" in source
    assert "pruneDeadClients()" in source
    assert "MSG_PEEK | MSG_DONTWAIT" in source

    context_server = source.split("contextServer.start(requestHandler:", maxsplit=1)[1]
    context_server = context_server.split("return jsonString", maxsplit=1)[0]

    assert 'op == "daemon_status"' in context_server
    assert '"hotkey_clients"' in context_server
    assert "hotkeyServer.clientCount()" in context_server


def test_bundled_daemon_launch_redirects_python_cache_outside_app_bundle() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    launch_script = source.split("private func buildDaemonLaunchScript", maxsplit=1)[1]
    launch_script = launch_script.split("func restartPythonDaemon", maxsplit=1)[0]

    assert "PYTHONDONTWRITEBYTECODE=1" in launch_script
    assert "PYTHONPYCACHEPREFIX=/tmp/witzper-pycache" in launch_script
    assert "Contents/Resources" not in launch_script.split("PYTHONPYCACHEPREFIX", maxsplit=1)[1]


def test_app_cleans_bundle_local_python_cache_dirs_after_daemon_startup() -> None:
    source = (
        ROOT / "swift-helper" / "Sources" / "FlowHelper" / "main.swift"
    ).read_text()

    assert "func cleanupBundlePythonCaches()" in source
    assert 'name == "__pycache__"' in source
    assert 'pathExtension == "pyc"' in source
    assert "cleanupBundlePythonCaches()" in source.split(
        "func spawnPythonDaemon", maxsplit=1
    )[1].split("func buildDaemonLaunchScript", maxsplit=1)[0]
