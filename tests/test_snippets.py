"""Tests for snippet matching — in particular punctuation tolerance."""

from pathlib import Path

from flow.personalize.snippets import SnippetStore


def _store(tmp_path: Path) -> SnippetStore:
    return SnippetStore(tmp_path / "snippets.db")


def test_solo_trigger_with_trailing_period(tmp_path):
    s = _store(tmp_path)
    s.add("sig", "— Isaac")
    assert s.apply("sig.") == "— Isaac"
    assert s.apply("Sig!") == "— Isaac"
    assert s.apply("  sig,  ") == "— Isaac"


def test_inline_trigger_preserves_surroundings(tmp_path):
    s = _store(tmp_path)
    s.add("my sig", "— Isaac")
    assert s.apply("Please add my sig here.") == "Please add — Isaac here."


def test_multiword_tolerates_punct_between_words(tmp_path):
    s = _store(tmp_path)
    s.add("my sig", "— Isaac")
    # Cleanup LLM sometimes inserts a period between the words — the
    # punctuation between trigger tokens gets consumed, any trailing
    # punctuation after the trigger is preserved as sentence punctuation.
    assert s.apply("My. Sig. now please") == "— Isaac. now please"
    assert s.apply("my, sig") == "— Isaac"


def test_longest_trigger_wins(tmp_path):
    s = _store(tmp_path)
    s.add("my email", "a@b.com")
    s.add("my work email", "work@b.com")
    assert s.apply("send my work email") == "send work@b.com"


def test_non_matching_text_unchanged(tmp_path):
    s = _store(tmp_path)
    s.add("sig", "— Isaac")
    assert s.apply("signature") == "signature"  # word boundary respected
