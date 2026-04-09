"""Edit-watch daemon.

After an insertion, poll the focused field's contents for N seconds. If the
inserted text was edited, treat the diff as:
  - a correction → goes to the CorrectionStore for training
  - a dictionary auto-learn candidate → single-token spelling/casing changes
    are appended to the boost dictionary (but only if the "wrong" token
    actually came from the ASR, not a user typo)

The actual AXValue read is done by the Swift helper via the
`read_focused_text` op on /tmp/flow-context.sock.
"""

from __future__ import annotations

import difflib
import threading
import time

import numpy as np
from rapidfuzz.distance import Levenshtein

from flow.context.app_context import AppContextProvider
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
        self._ctx_provider = AppContextProvider()

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
            args=(cid, raw_transcript, inserted_text, app_ctx),
            daemon=True,
        )
        thread.start()

    # ------------------------------------------------------------------
    def _watch(self, cid: str, raw_transcript: str, inserted_text: str, app_ctx) -> None:
        deadline = time.time() + self.window_seconds
        # Debounce: we only accept a "final" corrected value once we've seen
        # the same span twice in a row (≥1 s of stability) — otherwise we'd
        # catch mid-edit states like "Helll" on the way to "Hello".
        previous: str | None = None
        stable_candidate: str | None = None
        stable_count = 0
        initial_app = getattr(app_ctx, "bundle_id", None)

        while time.time() < deadline:
            time.sleep(0.5)
            # Bail if the user switched apps — any text in the new app isn't
            # ours to diff against.
            try:
                current_ctx = self._ctx_provider.snapshot()
                if (
                    initial_app is not None
                    and current_ctx is not None
                    and current_ctx.bundle_id is not None
                    and current_ctx.bundle_id != initial_app
                ):
                    return
            except Exception:
                pass

            full_text = self._ctx_provider.read_focused_text()
            if not full_text:
                continue

            span = self._extract_span(inserted_text, full_text)
            if span is None:
                continue

            if previous is not None and span == previous:
                stable_count += 1
                if stable_count >= 2 and span != inserted_text:
                    stable_candidate = span
            else:
                stable_count = 0
            previous = span

        if stable_candidate and stable_candidate != inserted_text:
            self.store.update_final_text(cid, stable_candidate)
            if self.auto_add:
                self._maybe_learn(raw_transcript, inserted_text, stable_candidate)

    # ------------------------------------------------------------------
    @staticmethod
    def _extract_span(inserted: str, full: str) -> str | None:
        """Locate the region of `full` that corresponds to `inserted`.

        If `inserted` is still present verbatim we return it unchanged — the
        user hasn't edited yet. Otherwise use difflib to find the largest
        contiguous block that aligns with `inserted`, expand it to the
        sentence-ish boundary, and return the corresponding slice of `full`.
        """
        if not inserted:
            return None
        if inserted in full:
            return inserted
        if len(full) > 10_000:
            full = full[-10_000:]
        sm = difflib.SequenceMatcher(a=inserted, b=full, autojunk=False)
        match = sm.find_longest_match(0, len(inserted), 0, len(full))
        if match.size < max(4, len(inserted) // 4):
            # Too little overlap — probably not our insertion anymore.
            return None
        # Estimate the inserted region in `full` by extending from the match
        # by the length of `inserted` (centred on the matching block).
        start = max(0, match.b - match.a)
        end = min(len(full), start + len(inserted) + max(10, len(inserted) // 2))
        return full[start:end].strip()

    # ------------------------------------------------------------------
    def _maybe_learn(self, raw_transcript: str, before: str, after: str) -> None:
        """If a single token changed spelling/casing, and the old spelling
        actually came from the ASR (appears in raw_transcript), add the new
        spelling to the boost dictionary. Avoids learning user typos.
        """
        before_tokens = before.split()
        after_tokens = after.split()
        if len(before_tokens) != len(after_tokens):
            return
        raw_lower = raw_transcript.lower()
        for b, a in zip(before_tokens, after_tokens, strict=False):
            if b == a:
                continue
            # Only learn if the pre-edit token was in the raw ASR output —
            # that confirms it was a mishearing, not something the user typed.
            if b.strip(".,!?;:").lower() not in raw_lower:
                continue
            dist = Levenshtein.distance(b.lower(), a.lower())
            if dist <= 2 or b.lower() == a.lower():
                self.dictionary.add_boost(a.strip(".,!?;:"))
