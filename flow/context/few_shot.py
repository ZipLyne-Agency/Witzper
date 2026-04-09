"""Dynamic few-shot retriever for the cleanup LLM.

Stores (raw, cleaned) examples from the corrections store and returns the
top-N most similar to the current raw transcript using rapidfuzz's
token-set ratio — no embedding model, no torch, no sentence-transformers.

For the 5-example few-shot budget the cleanup LLM actually consumes, token
overlap is plenty. Semantic retrieval's marginal win doesn't justify ~1 GB
of runtime dependencies. The `embedding` column stays in the schema (nulled
out for new rows) so upgrading from an older Witzper install is zero-touch.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

from rapidfuzz import fuzz, process

from flow.models.cleanup import FewShotExample

DEFAULT_DB = Path.home() / ".local" / "share" / "Witzper" / "few_shot.db"


class FewShotRetriever:
    def __init__(self, db: Path):
        db.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(db)
        # `embedding` kept for schema compatibility with pre-0.2 installs
        # where rows carried MiniLM vectors. We no longer read or write it.
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

    @classmethod
    def open_default(cls) -> FewShotRetriever:
        return cls(DEFAULT_DB)

    def add(self, raw: str, cleaned: str) -> None:
        self._conn.execute(
            "INSERT INTO examples(raw, cleaned) VALUES (?, ?)",
            (raw, cleaned),
        )
        self._conn.commit()

    def retrieve(self, raw: str, n: int = 5) -> list[FewShotExample]:
        rows = list(self._conn.execute("SELECT raw, cleaned FROM examples"))
        if not rows:
            return []
        raw_texts = [r[0] for r in rows]
        # token_set_ratio is order-insensitive and robust to ASR word-order
        # jitter — a better fit than plain ratio for transcript similarity.
        matches = process.extract(
            raw,
            raw_texts,
            scorer=fuzz.token_set_ratio,
            limit=n,
        )
        # `matches` is a list of (text, score, idx) tuples sorted by score desc.
        return [
            FewShotExample(raw=rows[idx][0], cleaned=rows[idx][1])
            for _text, _score, idx in matches
        ]
