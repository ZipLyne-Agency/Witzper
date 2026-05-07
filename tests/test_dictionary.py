from pathlib import Path

from flow.context.dictionary import Dictionary


def test_boost_and_replace(tmp_path: Path) -> None:
    d = Dictionary(tmp_path / "dict.db")
    d.add_boost("Isaac Horowitz")
    d.add_replacement("wisper", "Wispr")
    assert "Isaac Horowitz" in d.boost_terms()
    assert d.apply_replacements("I use wisper daily") == "I use Wispr daily"
    assert d.apply_replacements("Wisper") == "Wispr"  # case-insensitive


def test_whole_word_only(tmp_path: Path) -> None:
    d = Dictionary(tmp_path / "dict.db")
    d.add_replacement("cat", "dog")
    # Should not replace inside "catalog"
    assert d.apply_replacements("the catalog shows a cat") == "the catalog shows a dog"


def test_replacements_apply_longest_first(tmp_path: Path) -> None:
    d = Dictionary(tmp_path / "dict.db")
    d.add_replacement("flow", "Flow")
    d.add_replacement("flow local", "Witzper")

    assert d.apply_replacements("I use flow local") == "I use Witzper"


def test_empty_replacement_is_ignored(tmp_path: Path) -> None:
    d = Dictionary(tmp_path / "dict.db")
    d.add_replacement("", "anything")
    d.add_replacement("anything", "")

    assert d.apply_replacements("anything here") == "anything here"
