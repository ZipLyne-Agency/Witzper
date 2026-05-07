from pathlib import Path

import numpy as np

from flow.personalize.store import CorrectionStore


def test_cleanup_training_pairs_only_include_changed_final_text(tmp_path: Path) -> None:
    store = CorrectionStore(tmp_path / "corrections.db", tmp_path / "audio")
    changed = store.record("raw one", "inserted one")
    unchanged = store.record("raw two", "inserted two")

    store.update_final_text(changed, "final one")
    store.update_final_text(unchanged, "inserted two")

    assert store.pairs_for_cleanup_training() == [("raw one", "final one")]


def test_asr_training_pairs_skip_missing_audio_files(tmp_path: Path) -> None:
    store = CorrectionStore(tmp_path / "corrections.db", tmp_path / "audio")
    cid = store.record(
        "raw",
        "inserted",
        audio=np.ones(8, dtype=np.float32),
        sample_rate=16_000,
    )
    missing = tmp_path / "audio" / f"{cid}.wav"
    missing.unlink(missing_ok=True)

    assert store.pairs_for_asr_training() == []
