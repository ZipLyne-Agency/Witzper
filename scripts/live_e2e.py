"""Live Witzper end-to-end harness.

This is the test to run after the packaged app has macOS TCC permissions.
It fails closed when Accessibility, Input Monitoring, or Microphone is still
missing, then records real microphone audio, runs VAD -> ASR -> cleanup, and
optionally inserts the cleaned text through the Swift helper.
"""

from __future__ import annotations

import json
import re
import socket
import subprocess
import sys
import tempfile
import time
from argparse import ArgumentParser
from collections.abc import Callable
from difflib import SequenceMatcher
from pathlib import Path
from typing import NamedTuple

import numpy as np

from flow.config import load_config
from flow.core.audio import AudioCapture
from flow.core.orchestrator import _make_asr
from flow.core.vad import make_vad
from flow.insert.inserter import CONTEXT_SOCKET
from flow.models.cleanup import CleanupLLM

DEFAULT_EXPECTED_PHRASE = "hey are you free for lunch tomorrow"
Runner = Callable[..., subprocess.CompletedProcess[str]]
Sleeper = Callable[[float], None]


class PermissionPreflight(NamedTuple):
    ok: bool
    missing: list[str]
    detail: str


PERMISSION_SETTINGS_URLS = {
    "Accessibility": (
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ),
    "Input Monitoring": (
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    ),
    "Microphone": (
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    ),
}


def context_rpc(socket_path: Path, payload: dict) -> dict | None:
    if not socket_path.exists():
        return None
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(1.0)
            sock.connect(str(socket_path))
            sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            data = b""
            while not data.endswith(b"\n"):
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
        obj = json.loads(data or b"{}")
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


def permission_preflight(socket_path: Path = CONTEXT_SOCKET) -> PermissionPreflight:
    obj = context_rpc(socket_path, {"op": "permission_status"})
    if not obj:
        return PermissionPreflight(
            ok=False,
            missing=["Swift helper"],
            detail="Swift helper unavailable. Launch Witzper.app, wait for startup, then retry.",
        )
    raw_missing = obj.get("missing", [])
    missing = [str(item) for item in raw_missing] if isinstance(raw_missing, list) else []
    if not missing:
        return PermissionPreflight(
            ok=True,
            missing=[],
            detail="all required permissions granted",
        )
    return PermissionPreflight(
        ok=False,
        missing=missing,
        detail=(
            "missing: "
            + ", ".join(missing)
            + ". Open Witzper menu settings for each missing permission, then quit and relaunch."
        ),
    )


def open_permission_settings(
    missing: list[str],
    runner: Runner = subprocess.run,
) -> None:
    for name in missing:
        url = PERMISSION_SETTINGS_URLS.get(name)
        if not url:
            continue
        runner(
            ["open", url],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )


def _rms(audio: np.ndarray) -> float:
    if audio.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(audio.astype(np.float32)))))


def _normalize_text(text: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", text.lower()))


def text_similarity(expected: str, actual: str) -> float:
    normalized_expected = _normalize_text(expected)
    normalized_actual = _normalize_text(actual)
    if not normalized_expected or not normalized_actual:
        return 0.0
    return SequenceMatcher(None, normalized_expected, normalized_actual).ratio()


def validate_expected_text(actual: str, expected: str, min_similarity: float) -> float:
    if not expected:
        return 1.0
    score = text_similarity(expected, actual)
    if score < min_similarity:
        raise RuntimeError(
            "transcript similarity "
            f"{score:.2f} below required {min_similarity:.2f}; "
            f"expected {expected!r}, got {actual!r}"
        )
    return score


def open_textedit_target(
    target_dir: Path | None = None,
    runner: Runner = subprocess.run,
) -> tuple[Path, str]:
    marker = f"Witzper live E2E target {int(time.time())}"
    directory = target_dir or Path(tempfile.gettempdir())
    path = directory / f"witzper-live-e2e-{int(time.time())}.txt"
    path.write_text(marker + "\n", encoding="utf-8")
    runner(
        ["open", "-a", "TextEdit", str(path)],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    # Give macOS a moment to make the new document's text view frontmost.
    time.sleep(0.5)
    return path, marker


def record_live_audio(cfg, duration_s: float) -> np.ndarray:
    capture = AudioCapture(cfg.audio)
    try:
        print(f"recording live microphone for {duration_s:.1f}s")
        capture.start()
        time.sleep(duration_s)
        return capture.stop()
    finally:
        capture.close()


def transcribe_and_clean(cfg, audio: np.ndarray) -> tuple[str, str]:
    sr = cfg.audio.sample_rate
    print(f"captured {len(audio) / sr:.2f}s; rms={_rms(audio):.4f}")
    if _rms(audio) < 0.003:
        raise RuntimeError("captured audio is too quiet; check microphone selection and input level")

    print("running VAD")
    vad = make_vad(cfg.vad)
    trimmed = vad.trim(audio, sr=sr)
    print(f"kept {len(trimmed) / sr:.2f}s after VAD")
    if trimmed.size == 0:
        raise RuntimeError("VAD removed all audio; speak during the recording window")

    print(f"loading ASR: {cfg.asr.speed.model}")
    asr = _make_asr(cfg.asr.speed.model)
    t0 = time.perf_counter()
    raw = asr.transcribe(trimmed, sample_rate=sr).text.strip()
    print(f"ASR done in {(time.perf_counter() - t0) * 1000:.0f}ms")
    print(f"raw: {raw!r}")
    if not raw:
        raise RuntimeError("ASR returned empty text")

    print(f"loading cleanup LLM: {cfg.cleanup.model}")
    cleanup = CleanupLLM(cfg.cleanup)
    t0 = time.perf_counter()
    cleaned = cleanup.clean(raw_transcript=raw, few_shots=[]).strip()
    print(f"cleanup done in {(time.perf_counter() - t0) * 1000:.0f}ms")
    print(f"cleaned: {cleaned!r}")
    if not cleaned:
        raise RuntimeError("cleanup returned empty text")
    return raw, cleaned


def insert_and_verify_text(
    socket_path: Path,
    text: str,
    strategy: str,
    restore_clipboard_after_ms: int,
    verify: bool,
) -> bool:
    obj = context_rpc(
        socket_path,
        {
            "op": "insert",
            "text": text,
            "strategy": strategy,
            "restore_clipboard_after_ms": restore_clipboard_after_ms,
        },
    )
    if not obj or obj.get("ok") is False:
        error = obj.get("error", "helper rejected insert") if obj else "helper unavailable"
        raise RuntimeError(str(error))
    if not verify:
        return True

    # Give paste/type events a moment to land before reading AXValue back.
    time.sleep(0.2)
    readback = context_rpc(socket_path, {"op": "read_focused_text"})
    focused_text = readback.get("text") if isinstance(readback, dict) else None
    if not isinstance(focused_text, str) or not focused_text:
        raise RuntimeError("focused text is unavailable after insertion")
    if _normalize_text(text) not in _normalize_text(focused_text):
        raise RuntimeError("focused text does not contain insertion")
    return True


def _require_ok(obj: dict | None, op: str) -> None:
    if not obj or obj.get("ok") is False:
        error = obj.get("error", f"{op} failed") if obj else "helper unavailable"
        raise RuntimeError(str(error))


def trigger_daemon_dictation(
    socket_path: Path,
    duration_s: float,
    sleeper: Sleeper = time.sleep,
) -> None:
    _require_ok(
        context_rpc(
            socket_path,
            {"op": "simulate_hotkey", "action": "dictate", "phase": "down"},
        ),
        "simulate_hotkey down",
    )
    try:
        sleeper(duration_s)
    finally:
        _require_ok(
            context_rpc(
                socket_path,
                {"op": "simulate_hotkey", "action": "dictate", "phase": "up"},
            ),
            "simulate_hotkey up",
        )


def wait_for_daemon_ready(
    socket_path: Path,
    timeout_s: float = 30.0,
    interval_s: float = 0.5,
    sleeper: Sleeper = time.sleep,
) -> bool:
    deadline = time.perf_counter() + timeout_s
    while time.perf_counter() < deadline:
        obj = context_rpc(socket_path, {"op": "daemon_status"})
        if isinstance(obj, dict) and int(obj.get("hotkey_clients", 0)) > 0:
            return True
        sleeper(interval_s)
    raise RuntimeError("Python daemon is not connected to the helper hotkey stream")


def wait_for_inserted_text(
    socket_path: Path,
    expected: str,
    timeout_s: float = 20.0,
    interval_s: float = 0.25,
) -> tuple[str, float]:
    deadline = time.perf_counter() + timeout_s
    best_text = ""
    best_score = 0.0
    while time.perf_counter() < deadline:
        obj = context_rpc(socket_path, {"op": "read_focused_text"})
        text = obj.get("text") if isinstance(obj, dict) else None
        if isinstance(text, str):
            best_text = text
            score = text_similarity(expected, text)
            best_score = max(best_score, score)
            if _normalize_text(expected) in _normalize_text(text) or score >= 0.82:
                return text, score
        time.sleep(interval_s)
    raise RuntimeError(
        "timed out waiting for daemon insertion; "
        f"best similarity {best_score:.2f}, focused text {best_text!r}"
    )


def main() -> int:
    parser = ArgumentParser(description="Run live Witzper microphone and insertion E2E.")
    parser.add_argument("--config", type=Path, default=None)
    parser.add_argument("--duration", type=float, default=4.0)
    parser.add_argument(
        "--expect",
        default=DEFAULT_EXPECTED_PHRASE,
        help="Phrase to speak and verify; pass an empty string to skip accuracy scoring.",
    )
    parser.add_argument("--min-similarity", type=float, default=0.82)
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument(
        "--open-permissions",
        action="store_true",
        help="Open System Settings panes for missing permissions when preflight blocks.",
    )
    parser.add_argument("--skip-insert", action="store_true")
    parser.add_argument(
        "--mode",
        choices=("daemon", "direct"),
        default="daemon",
        help="'daemon' drives the packaged app pipeline; 'direct' records in this harness process.",
    )
    parser.add_argument(
        "--target",
        choices=("textedit", "focused"),
        default="textedit",
        help="Where to insert the final text. 'textedit' opens a scratch document.",
    )
    parser.add_argument(
        "--no-verify-insert",
        action="store_true",
        help="Skip focused-text readback after insertion.",
    )
    args = parser.parse_args()

    preflight = permission_preflight()
    if not preflight.ok:
        print(f"BLOCKED: {preflight.detail}")
        if args.open_permissions:
            open_permission_settings(preflight.missing)
        return 2
    print(f"permissions: {preflight.detail}")
    if args.preflight_only:
        return 0

    cfg = load_config(args.config)
    if not args.skip_insert and args.target == "textedit":
        path, marker = open_textedit_target()
        print(f"opened TextEdit target: {path} ({marker})")
    else:
        print("Focus a writable text field now.")
    if args.expect:
        print(f"Speak this phrase: {args.expect!r}")
    else:
        print("Speak during the recording window.")
    time.sleep(3)
    try:
        if args.mode == "daemon":
            if args.skip_insert:
                raise RuntimeError("--skip-insert is only valid with --mode direct")
            wait_for_daemon_ready(CONTEXT_SOCKET)
            trigger_daemon_dictation(CONTEXT_SOCKET, max(0.5, args.duration))
            focused_text, score = wait_for_inserted_text(
                CONTEXT_SOCKET,
                args.expect,
                timeout_s=30.0,
            )
            if args.expect:
                validate_expected_text(focused_text, args.expect, args.min_similarity)
                print(f"similarity: {score:.2f}")
        else:
            audio = record_live_audio(cfg, max(0.5, args.duration))
            _raw, cleaned = transcribe_and_clean(cfg, audio)
            score = validate_expected_text(cleaned, args.expect, args.min_similarity)
            if args.expect:
                print(f"similarity: {score:.2f}")
            if args.skip_insert:
                print("insert skipped")
                return 0
            insert_and_verify_text(
                socket_path=CONTEXT_SOCKET,
                text=cleaned,
                strategy=cfg.insertion.default_strategy,
                restore_clipboard_after_ms=cfg.insertion.restore_clipboard_after_ms,
                verify=not args.no_verify_insert,
            )
    except Exception as exc:  # noqa: BLE001
        print(f"FAILED: {exc}")
        return 3
    print("OK: live microphone -> ASR -> cleanup -> insertion verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
