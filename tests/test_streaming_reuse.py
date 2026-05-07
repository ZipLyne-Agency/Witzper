from pathlib import Path

from flow.config import load_config
from flow.core.orchestrator import Orchestrator


def _orchestrator_shell() -> Orchestrator:
    cfg = load_config(Path("/tmp/witzper-test-config-does-not-exist.toml"))
    orch = object.__new__(Orchestrator)
    orch.cfg = cfg
    return orch


def test_reuses_partial_when_it_covers_nearly_all_audio() -> None:
    orch = _orchestrator_shell()
    total = orch.cfg.audio.sample_rate * 10

    assert orch._should_reuse_partial(
        partial_text="hello world",
        partial_samples=total - 1000,
        total_samples=total,
    )


def test_does_not_reuse_partial_with_too_much_untranscribed_tail() -> None:
    orch = _orchestrator_shell()
    total = orch.cfg.audio.sample_rate * 10
    missing_300_ms = int(orch.cfg.audio.sample_rate * 0.3)

    assert not orch._should_reuse_partial(
        partial_text="hello world",
        partial_samples=total - missing_300_ms,
        total_samples=total,
    )


def test_does_not_reuse_empty_partial() -> None:
    orch = _orchestrator_shell()

    assert not orch._should_reuse_partial(
        partial_text="",
        partial_samples=orch.cfg.audio.sample_rate,
        total_samples=orch.cfg.audio.sample_rate,
    )
