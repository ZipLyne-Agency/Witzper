"""Edit-watch daemon.

After an insertion, poll the focused field's contents for N seconds. If the
inserted text was edited, treat the diff as:
  - a correction → goes to the CorrectionStore for training
  - a dictionary auto-learn candidate → single-token spelling/casing changes
    are appended to the boost dictionary
"""

from __future__ import annotations

import subprocess
import threading
import time

import numpy as np
from rapidfuzz.distance import Levenshtein

from flow.context.dictionary import Dictionary
from flow.personalize.store import CorrectionStore


class EditWatcher:
    def __init__(
        self,
        window_seconds: int,
        store: CorrectionStore,
        dictionary: Dictionary,
        auto_add: bool = True,
    ):
        self.window_seconds = window_seconds
        self.store = store
        self.dictionary = dictionary
        self.auto_add = auto_add

    def arm(
        self,
        raw_transcript: str,
        inserted_text: str,
        app_ctx=None,
        audio: np.ndarray | None = None,
        sample_rate: int | None = None,
    ) -> None:
        cid = self.store.record(
            raw_transcript=raw_transcript,
            inserted_text=inserted_text,
            app_ctx=app_ctx,
            audio=audio,
            sample_rate=sample_rate,
        )
        thread = threading.Thread(
            target=self._watch,
            args=(cid, inserted_text, app_ctx),
            daemon=True,
        )
        thread.start()

    def _watch(self, cid: str, inserted_text: str, app_ctx) -> None:
        # Poll selected-text / field contents every 500ms. This is best-effort;
        # the Swift helper provides the actual AXUIElement read. Without it, we
        # rely on the user selecting the inserted text again (Cmd-A etc.)
        deadline = time.time() + self.window_seconds
        last_seen = inserted_text
        while time.time() < deadline:
            time.sleep(0.5)
            observed = self._read_current_text(app_ctx)
            if observed and observed != last_seen:
                last_seen = observed
        if last_seen != inserted_text:
            self.store.update_final_text(cid, last_seen)
            if self.auto_add:
                self._maybe_learn(inserted_text, last_seen)

    @staticmethod
    def _read_current_text(app_ctx) -> str | None:
        # Placeholder: the Swift helper provides this via XPC. Without it we
        # can't reliably read the focused field's contents. Returns None.
        return None

    def _maybe_learn(self, before: str, after: str) -> None:
        """If a single token changed spelling/casing, add the new spelling to dict."""
        before_tokens = before.split()
        after_tokens = after.split()
        if len(before_tokens) != len(after_tokens):
            return
        for b, a in zip(before_tokens, after_tokens, strict=False):
            if b == a:
                continue
            dist = Levenshtein.distance(b.lower(), a.lower())
            if dist <= 2 or b.lower() == a.lower():
                self.dictionary.add_boost(a.strip(".,!?;:"))
