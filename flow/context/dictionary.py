"""Personal dictionary — boost terms + replacement rules, backed by SQLite."""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DB = Path.home() / ".local" / "share" / "flow-local" / "dictionary.db"


@dataclass
class DictionaryEntry:
    kind: str  # "boost" | "replace"
    key: str
    value: str | None = None

    def __str__(self) -> str:
        if self.kind == "boost":
            return f"boost: {self.key}"
        return f"replace: {self.key!r} → {self.value!r}"


class Dictionary:
    def __init__(self, db: Path):
        db.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(db)
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS boost (
                term TEXT PRIMARY KEY,
                added_at REAL DEFAULT (strftime('%s','now'))
            );
            CREATE TABLE IF NOT EXISTS replacement (
                wrong TEXT PRIMARY KEY,
                right TEXT NOT NULL,
                added_at REAL DEFAULT (strftime('%s','now'))
            );
            """
        )
        self._conn.commit()

    @classmethod
    def open_default(cls) -> Dictionary:
        return cls(DEFAULT_DB)

    def add_boost(self, term: str) -> None:
        term = term.strip()
        if not term:
            return
        self._conn.execute("INSERT OR IGNORE INTO boost(term) VALUES (?)", (term,))
        self._conn.commit()

    def add_replacement(self, wrong: str, right: str) -> None:
        self._conn.execute(
            "INSERT OR REPLACE INTO replacement(wrong, right) VALUES (?, ?)",
            (wrong.strip(), right.strip()),
        )
        self._conn.commit()

    def boost_terms(self) -> list[str]:
        return [r[0] for r in self._conn.execute("SELECT term FROM boost ORDER BY added_at DESC")]

    def replacements(self) -> list[tuple[str, str]]:
        return list(self._conn.execute("SELECT wrong, right FROM replacement"))

    def apply_replacements(self, text: str) -> str:
        out = text
        for wrong, right in self.replacements():
            # Case-insensitive whole-word replacement that preserves surrounding punctuation
            pattern = re.compile(rf"\b{re.escape(wrong)}\b", re.IGNORECASE)
            out = pattern.sub(right, out)
        return out

    def all(self) -> list[DictionaryEntry]:
        entries: list[DictionaryEntry] = []
        for (term,) in self._conn.execute("SELECT term FROM boost"):
            entries.append(DictionaryEntry("boost", term))
        for wrong, right in self._conn.execute("SELECT wrong, right FROM replacement"):
            entries.append(DictionaryEntry("replace", wrong, right))
        return entries
