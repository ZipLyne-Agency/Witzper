from flow.personalize.edit_watch import EditWatcher


class FakeDictionary:
    def __init__(self) -> None:
        self.boosts: list[str] = []

    def add_boost(self, term: str) -> None:
        self.boosts.append(term)


def _watcher(dictionary: FakeDictionary) -> EditWatcher:
    return EditWatcher(
        window_seconds=0,
        store=object(),  # type: ignore[arg-type]
        dictionary=dictionary,  # type: ignore[arg-type]
    )


def test_maybe_learn_single_token_correction() -> None:
    dictionary = FakeDictionary()
    watcher = _watcher(dictionary)

    watcher._maybe_learn(
        raw_transcript="I met Izac today",
        before="I met Izac today",
        after="I met Isaac today",
    )

    assert dictionary.boosts == ["Isaac"]


def test_maybe_learn_ignores_multiple_token_edits() -> None:
    dictionary = FakeDictionary()
    watcher = _watcher(dictionary)

    watcher._maybe_learn(
        raw_transcript="I met Izac todai",
        before="I met Izac todai",
        after="I met Isaac today",
    )

    assert dictionary.boosts == []


def test_maybe_learn_requires_raw_word_boundary_match() -> None:
    dictionary = FakeDictionary()
    watcher = _watcher(dictionary)

    watcher._maybe_learn(
        raw_transcript="the catalog is open",
        before="the cat is open",
        after="the Kat is open",
    )

    assert dictionary.boosts == []
