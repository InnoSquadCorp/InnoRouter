#!/usr/bin/env python3
"""Validate reviewed Inspector strings. Never generate or modify translations."""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/InnoRouterInspector"
LANGUAGES = {
    "ko", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt-BR",
    "ru", "ar", "hi", "id", "vi", "th",
}


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def require(condition, message):
    if not condition:
        raise SystemExit(f"[inspector-localization] {message}")


catalog = json.loads(
    (SOURCE / "Localizable.xcstrings").read_text(encoding="utf-8"),
    object_pairs_hook=unique_keys,
)
require(catalog["sourceLanguage"] == "en", "Source language must be English")
strings = catalog["strings"]
for key, entry in strings.items():
    require(bool(entry.get("comment", "").strip()), f"Missing semantic context: {key}")
    require(set(entry["localizations"]) == LANGUAGES, f"Language coverage differs: {key}")
    for language, translation in entry["localizations"].items():
        unit = translation["stringUnit"]
        value = unit["value"]
        require(unit["state"] == "translated", f"Unfinished translation: {language}/{key}")
        require(bool(value) and value == value.strip(), f"Empty or padded text: {language}/{key}")
        # The current catalog has no substitutions. New substitutions require
        # an explicit formatting contract, not implicit interpolation in labels.
        require("%" not in value and "%" not in key, f"Review new format substitution: {language}/{key}")

for path in SOURCE.glob("*.swift"):
    source = path.read_text(encoding="utf-8")
    for key in re.findall(r'routerInspectorLocalized\(\s*"([^"\\]*)"', source):
        require(key in strings, f"Missing catalog key in {path.name}: {key}")

for key in ("idle", "recording", "complete", "incomplete", "cancelled", "failed",
            "applied", "unchanged", "deferred", "rejected", "unresolved"):
    require(key in strings, f"Missing dynamic status key: {key}")

print(f"[inspector-localization] {len(strings)} keys, {len(LANGUAGES) + 1} languages validated (no translation performed)")
