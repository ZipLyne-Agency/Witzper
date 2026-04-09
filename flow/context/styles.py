"""Flow Styles — per-category formatting (mirrors Wispr Flow's feature)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import tomli

APP_CATEGORIES_PATH = (
    Path(__file__).resolve().parent.parent.parent / "configs" / "app_categories.toml"
)

CATEGORIES = ("personal_messages", "work_messages", "email", "other")

# Per-style instruction text injected into the cleanup LLM prompt.
# IMPORTANT: this controls FORMATTING ONLY — never grammar, word choice, or phrasing.
STYLE_INSTRUCTIONS: dict[str, str] = {
    "formal": (
        "STYLE: FORMAL. Capitalize sentences and proper nouns. End every sentence "
        "with proper punctuation (periods, question marks). Use complete sentences. "
        "Do not use exclamation points unless the speaker clearly intended one."
    ),
    "casual": (
        "STYLE: CASUAL. Capitalize the first word of each sentence and proper nouns. "
        "Keep punctuation light: question marks where needed, commas only when truly "
        "necessary, and DROP the trailing period at the end of the message. "
        "Example input: 'hey are you free for lunch tomorrow lets do twelve if that works for you' "
        "Example output: 'Hey are you free for lunch tomorrow? Let's do 12 if that works for you'"
    ),
    "very_casual": (
        "STYLE: VERY CASUAL. Use ALL LOWERCASE — even at the start of sentences and for "
        "proper nouns when it sounds natural in chat (e.g. names of brands stay normal). "
        "Drop the trailing period. Keep question marks. No exclamation points."
    ),
    "excited": (
        "STYLE: EXCITED. Capitalize normally. Use exclamation points liberally where "
        "the speaker sounds enthusiastic. Otherwise standard punctuation."
    ),
}


@dataclass
class AppCategoryRule:
    match: str
    category: str


class StyleResolver:
    def __init__(self, rules_path: Path = APP_CATEGORIES_PATH):
        self._rules = self._load_rules(rules_path)

    def _load_rules(self, path: Path) -> list[AppCategoryRule]:
        if not path.exists():
            return [AppCategoryRule(match="*", category="other")]
        with path.open("rb") as f:
            data = tomli.load(f)
        return [AppCategoryRule(**r) for r in data.get("rule", [])]

    def category_for(self, app_name: str | None, bundle_id: str | None) -> str:
        for rule in self._rules:
            if rule.match == "*":
                continue
            if bundle_id and rule.match == bundle_id:
                return rule.category
            if app_name and rule.match.lower() == app_name.lower():
                return rule.category
        return "other"

    def style_for(self, styles_cfg, app_name: str | None, bundle_id: str | None) -> str:
        category = self.category_for(app_name, bundle_id)
        return getattr(styles_cfg, category, "casual")

    def instruction_for(self, styles_cfg, app_name: str | None, bundle_id: str | None) -> str:
        style = self.style_for(styles_cfg, app_name, bundle_id)
        return STYLE_INSTRUCTIONS.get(style, STYLE_INSTRUCTIONS["casual"])
