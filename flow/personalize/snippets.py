"""Snippets — voice-triggered text expansion (mirrors Wispr Flow's feature).

A snippet has:
  - trigger: the phrase you say (max 60 chars)
  - expansion: the text inserted in its place (max 4000 chars)

Matching rules (mirrors Wispr Flow):
  - case-insensitive whole-word match
  - if the trigger appears inside a longer transcript, replace it in place
  - if the transcript IS only the trigger (with optional trailing punctuation),
    strip the punctuation before matching so it still fires
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DB = Path.home() / ".local" / "share" / "Witzper" / "snippets.db"

MAX_TRIGGER_CHARS = 60
MAX_EXPANSION_CHARS = 4000


@dataclass
class Snippet:
    trigger: str
    expansion: str


class SnippetStore:
    def __init__(self, db: Path = DEFAULT_DB):
        db.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(db)
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS snippet (
                trigger TEXT PRIMARY KEY,
                expansion TEXT NOT NULL,
                added_at REAL DEFAULT (strftime('%s','now'))
            );
            """
        )
        self._conn.commit()

    @classmethod
    def open_default(cls) -> SnippetStore:
        return cls()

    # ---- CRUD ----------------------------------------------------------

    def add(self, trigger: str, expansion: str) -> None:
        trigger = trigger.strip()
        if not trigger or not expansion:
            raise ValueError("trigger and expansion required")
        if len(trigger) > MAX_TRIGGER_CHARS:
            raise ValueError(f"trigger too long (max {MAX_TRIGGER_CHARS})")
        if len(expansion) > MAX_EXPANSION_CHARS:
            raise ValueError(f"expansion too long (max {MAX_EXPANSION_CHARS})")
        self._conn.execute(
            "INSERT OR REPLACE INTO snippet(trigger, expansion) VALUES (?, ?)",
            (trigger, expansion),
        )
        self._conn.commit()

    def remove(self, trigger: str) -> bool:
        cur = self._conn.execute("DELETE FROM snippet WHERE LOWER(trigger) = LOWER(?)", (trigger,))
        self._conn.commit()
        return cur.rowcount > 0

    def all(self) -> list[Snippet]:
        rows = self._conn.execute("SELECT trigger, expansion FROM snippet ORDER BY trigger")
        return [Snippet(trigger=t, expansion=e) for t, e in rows]

    def count(self) -> int:
        return self._conn.execute("SELECT COUNT(*) FROM snippet").fetchone()[0]

    # ---- Application ---------------------------------------------------

    def apply(self, text: str, *, strip_punct_on_solo: bool = True) -> str:
        """Replace any matching snippet triggers in `text` with their expansions."""
        if not text:
            return text
        snippets = self.all()
        if not snippets:
            return text

        # Solo-trigger fast path: if the entire transcript (modulo punctuation)
        # equals a trigger, return that snippet's expansion outright.
        if strip_punct_on_solo:
            stripped = text.strip().rstrip(".,!?;:")
            for s in snippets:
                if stripped.lower() == s.trigger.lower():
                    return s.expansion

        # Whole-word, case-insensitive substring replacement, longest first
        # so that "my work email address" wins over "my email" if both exist.
        out = text
        for s in sorted(snippets, key=lambda x: -len(x.trigger)):
            pattern = re.compile(rf"\b{re.escape(s.trigger)}\b", re.IGNORECASE)
            out = pattern.sub(s.expansion, out)
        return out
