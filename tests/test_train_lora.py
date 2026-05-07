import json

from flow.personalize import train_lora


class FakeStore:
    def __init__(self, pairs: list[tuple[str, str]]) -> None:
        self._pairs = pairs

    def pairs_for_asr_training(self) -> list[tuple[str, str]]:
        return self._pairs


def test_train_asr_writes_manifest_for_external_trainer(tmp_path, monkeypatch) -> None:
    pairs = [(f"/tmp/audio-{i}.wav", f"transcript {i}") for i in range(50)]
    monkeypatch.setattr(train_lora, "LORA_ROOT", tmp_path)
    monkeypatch.setattr(
        train_lora.CorrectionStore,
        "open_default",
        classmethod(lambda cls: FakeStore(pairs)),
    )

    train_lora.train_asr()

    manifest = tmp_path / "asr_manifest.jsonl"
    rows = [json.loads(line) for line in manifest.read_text().splitlines()]
    assert rows[0] == {"audio": "/tmp/audio-0.wav", "text": "transcript 0"}
    assert rows[-1] == {"audio": "/tmp/audio-49.wav", "text": "transcript 49"}


def test_train_asr_skips_manifest_when_not_enough_pairs(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(train_lora, "LORA_ROOT", tmp_path)
    monkeypatch.setattr(
        train_lora.CorrectionStore,
        "open_default",
        classmethod(lambda cls: FakeStore([("/tmp/audio.wav", "text")])),
    )

    train_lora.train_asr()

    assert not (tmp_path / "asr_manifest.jsonl").exists()
