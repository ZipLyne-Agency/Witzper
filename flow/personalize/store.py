"""Local corrections store — (raw_transcript, inserted_text, final_edited_text, audio_path).

Used for:
  - few-shot retrieval (raw → cleaned)
  - nightly cleanup LoRA training
  - biweekly ASR LoRA training (audio → final_edited_text)
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid
from pathlib import Path

import numpy as np
import soundfile as sf

DEFAULT_ROOT = Path.home() / ".local" / "share" / "Witzper"
DEFAULT_DB = DEFAULT_ROOT / "corrections.db"
AUDIO_DIR = DEFAULT_ROOT / "audio_cache"


class CorrectionStore:
    def __init__(self, db: Path = DEFAULT_DB, audio_dir: Path = AUDIO_DIR):
        db.parent.mkdir(parents=True, exist_ok=True)
        audio_dir.mkdir(parents=True, exist_ok=True)
        self._audio_dir = audio_dir
        self._conn = sqlite3.connect(db)
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS corrections (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                raw_transcript TEXT NOT NULL,
                inserted_text TEXT NOT NULL,
                final_text TEXT,
                app_bundle_id TEXT,
                app_name TEXT,
                audio_path TEXT,
                sample_rate INTEGER,
                meta_json TEXT
            );
            CREATE INDEX IF NOT EXISTS ix_corrections_created ON corrections(created_at);
            """
        )
        self._conn.commit()

    @classmethod
    def open_default(cls) -> CorrectionStore:
        return cls()

    def record(
        self,
        raw_transcript: str,
        inserted_text: str,
        app_ctx=None,
        audio: np.ndarray | None = None,
        sample_rate: int | None = None,
        meta: dict | None = None,
    ) -> str:
        cid = str(uuid.uuid4())
        audio_path: str | None = None
        if audio is not None and audio.size and sample_rate:
            audio_path = str(self._audio_dir / f"{cid}.wav")
            # Write audio in a background thread — a 5-minute recording is
            # ~19 MB of WAV which takes tens of ms to flush. This keeps the
            # caller (edit_watcher.arm) from blocking.
            a, sr, p = audio.copy(), sample_rate, audio_path
            threading.Thread(
                target=sf.write, args=(p, a, sr), daemon=True
            ).start()
        self._conn.execute(
            """
            INSERT INTO corrections
            (id, created_at, raw_transcript, inserted_text, app_bundle_id, app_name,
             audio_path, sample_rate, meta_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                cid,
                time.time(),
                raw_transcript,
                inserted_text,
                app_ctx.bundle_id if app_ctx else None,
                app_ctx.app_name if app_ctx else None,
                audio_path,
                sample_rate,
                json.dumps(meta or {}),
            ),
        )
        self._conn.commit()
        return cid

    def update_final_text(self, cid: str, final_text: str) -> None:
        self._conn.execute(
            "UPDATE corrections SET final_text = ? WHERE id = ?", (final_text, cid)
        )
        self._conn.commit()

    def pairs_for_cleanup_training(self) -> list[tuple[str, str]]:
        """Raw → final-edited pairs where the user actually changed something."""
        rows = self._conn.execute(
            """
            SELECT raw_transcript, final_text FROM corrections
            WHERE final_text IS NOT NULL AND final_text != inserted_text
            """
        )
        return [(r[0], r[1]) for r in rows]

    def pairs_for_asr_training(self) -> list[tuple[str, str]]:
        """audio_path → final_text pairs — for acoustic LoRA."""
        rows = self._conn.execute(
            """
            SELECT audio_path, COALESCE(final_text, inserted_text)
            FROM corrections WHERE audio_path IS NOT NULL
            """
        )
        return [(r[0], r[1]) for r in rows]
