from flow.config import Config
from flow.core.orchestrator import Orchestrator


class FakeSpeedASR:
    pass


def _orchestrator_shell() -> Orchestrator:
    cfg = Config.model_validate(
        {
            "asr": {
                "speed": {
                    "model": "mlx-community/parakeet-tdt-0.6b-v3",
                    "backend": "parakeet",
                },
                "accuracy": {
                    "model": "mlx-community/Qwen3-ASR",
                    "backend": "qwen3",
                },
            },
            "cleanup": {"model": "mlx-community/Qwen3-8B-4bit"},
            "command": {"enabled": True, "model": "mlx-community/Qwen3-8B-4bit"},
        }
    )
    orch = object.__new__(Orchestrator)
    orch.cfg = cfg
    orch.asr_speed = FakeSpeedASR()
    orch.asr_accuracy = None
    return orch


def test_accuracy_asr_falls_back_to_speed_when_qwen3_unavailable(monkeypatch) -> None:
    orch = _orchestrator_shell()

    def fail_qwen3(_model: str):
        raise RuntimeError("qwen3 unavailable")

    monkeypatch.setattr("flow.core.orchestrator.Qwen3ASR", fail_qwen3)

    assert orch._get_asr("accuracy") is orch.asr_speed
    assert orch.asr_accuracy is None
