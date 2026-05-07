from flow.config import VadCfg
from flow.core import vad


class FakeSilero:
    def __init__(self, cfg: VadCfg) -> None:
        self.cfg = cfg


def test_make_vad_falls_back_to_silero_when_pyannote_unavailable(monkeypatch) -> None:
    def fail_pyannote(_model: str):
        raise RuntimeError("pyannote unavailable")

    monkeypatch.setattr(vad, "PyannoteVAD", fail_pyannote)
    monkeypatch.setattr(vad, "SileroVAD", FakeSilero)

    backend = vad.make_vad(VadCfg(backend="pyannote", model="pyannote/model"))

    assert isinstance(backend, FakeSilero)
    assert backend.cfg.backend == "silero"
