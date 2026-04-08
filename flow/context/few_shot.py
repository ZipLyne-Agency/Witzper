"""Dynamic few-shot retriever for the cleanup LLM.

Stores (raw, cleaned) examples from the corrections store, embeds them with a
small sentence-transformer, and returns the top-N most similar to the current
raw transcript. Few-shots are the biggest quality lever for small-LLM cleanup.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import numpy as np

from flow.models.cleanup import FewShotExample

DEFAULT_DB = Path.home() / ".local" / "share" / "Witzper" / "few_shot.db"
EMBED_MODEL = "sentence-transformers/all-MiniLM-L6-v2"


class FewShotRetriever:
    def __init__(self, db: Path):
        db.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(db)
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS examples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                raw TEXT NOT NULL,
                cleaned TEXT NOT NULL,
                embedding BLOB,
                added_at REAL DEFAULT (strftime('%s','now'))
            );
            """
        )
        self._conn.commit()
        self._embedder = None

    @classmethod
    def open_default(cls) -> FewShotRetriever:
        return cls(DEFAULT_DB)

    def _get_embedder(self):
        if self._embedder is None:
            from sentence_transformers import SentenceTransformer

            self._embedder = SentenceTransformer(EMBED_MODEL)
        return self._embedder

    def add(self, raw: str, cleaned: str) -> None:
        emb = self._embed([raw])[0]
        self._conn.execute(
            "INSERT INTO examples(raw, cleaned, embedding) VALUES (?, ?, ?)",
            (raw, cleaned, emb.tobytes()),
        )
        self._conn.commit()

    def _embed(self, texts: list[str]) -> np.ndarray:
        model = self._get_embedder()
        return np.asarray(model.encode(texts, normalize_embeddings=True), dtype=np.float32)

    def retrieve(self, raw: str, n: int = 5) -> list[FewShotExample]:
        rows = list(self._conn.execute("SELECT raw, cleaned, embedding FROM examples"))
        if not rows:
            return []
        embs = np.stack([np.frombuffer(r[2], dtype=np.float32) for r in rows])
        q = self._embed([raw])[0]
        sims = embs @ q
        top = np.argsort(-sims)[:n]
        return [FewShotExample(raw=rows[i][0], cleaned=rows[i][1]) for i in top]
