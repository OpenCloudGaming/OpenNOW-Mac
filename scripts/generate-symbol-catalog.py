#!/usr/bin/env python3
"""Generate the SF Symbols catalog bundled for the collection icon picker.

Reads the symbol metadata that ships inside the system's SFSymbols framework and writes a
curated, self-contained JSON file to ``Resources/CollectionIcons/sf-symbols.json``. Run it
when the deployment floor (and therefore the newest symbols the picker may offer) moves::

    scripts/generate-symbol-catalog.py

The output is committed, so the app never reads the framework's private resources at runtime.
Availability is capped at the SF Symbols release that ships with the macOS deployment floor
(SF Symbols 6 / 2024 for macOS 15), so every symbol the catalog offers renders on the oldest
supported system. Script/locale variants and numeric index symbols are dropped so search and
browse show one glyph per concept rather than a dozen near-duplicates.
"""

from __future__ import annotations

import json
import plistlib
import re
import sys
from pathlib import Path

DEPLOYMENT_SYMBOL_YEAR = 2024

FRAMEWORK_RESOURCES = Path(
    "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources"
)
GLYPHS_RESOURCES = FRAMEWORK_RESOURCES / "CoreGlyphs.bundle/Contents/Resources"
OUTPUT = Path(__file__).resolve().parent.parent / "Resources/CollectionIcons/sf-symbols.json"

CATEGORY_TITLES = {
    "communication": "Communication",
    "weather": "Weather",
    "maps": "Maps",
    "objectsandtools": "Objects & Tools",
    "devices": "Devices",
    "cameraandphotos": "Camera & Photos",
    "gaming": "Gaming",
    "connectivity": "Connectivity",
    "transportation": "Transportation",
    "automotive": "Automotive",
    "accessibility": "Accessibility",
    "privacyandsecurity": "Privacy & Security",
    "human": "Human",
    "home": "Home",
    "fitness": "Fitness",
    "nature": "Nature",
    "editing": "Editing",
    "textformatting": "Text Formatting",
    "media": "Media",
    "keyboard": "Keyboard",
    "commerce": "Commerce",
    "time": "Time",
    "health": "Health",
    "shapes": "Shapes",
    "arrows": "Arrows",
    "indices": "Indices",
    "math": "Math",
    "draw": "Draw",
}

# Category tags that describe rendering or release membership rather than a subject.
NON_SUBJECT_TAGS = {"all", "whatsnew", "variable", "multicolor"}

# Locale and script suffixes Apple appends to a localized duplicate of a base symbol.
LOCALE_SUFFIXES = {
    "ar", "he", "hi", "th", "ja", "ko", "zh", "rtl", "bn", "gu", "kn", "ml", "mr",
    "or", "pa", "sat", "si", "ta", "te", "mni", "as", "ur", "dv", "km", "lo", "my",
    "ne", "sa", "bo", "ti", "am", "chr", "iu", "oj", "cr", "vi",
}

LOCALE_SUFFIX = re.compile(r"\.([a-z]{2})$")
LEADING_NUMBER = re.compile(r"^\d+\.")


def availability_year(value: object) -> int:
    try:
        return int(str(value).split(".")[0])
    except (TypeError, ValueError):
        return 9999


def load_plist(name: str) -> object:
    with (GLYPHS_RESOURCES / name).open("rb") as handle:
        return plistlib.load(handle)


def is_locale_variant(name: str) -> bool:
    match = LOCALE_SUFFIX.search(name)
    return bool(match and match.group(1) in LOCALE_SUFFIXES)


def primary_category(tags: list[str]) -> str:
    for tag in tags:
        if tag in CATEGORY_TITLES:
            return tag
    return "objectsandtools"


def build() -> dict[str, object]:
    availability = load_plist("name_availability.plist")["symbols"]
    categories_by_name = load_plist("symbol_categories.plist")
    search_by_name = load_plist("symbol_search.plist")

    symbols: list[dict[str, object]] = []
    used_categories: set[str] = set()

    for name in sorted(availability):
        if availability_year(availability[name]) > DEPLOYMENT_SYMBOL_YEAR:
            continue
        if LEADING_NUMBER.match(name) or is_locale_variant(name):
            continue

        tags = [tag for tag in categories_by_name.get(name, [])]
        subject_tags = [tag for tag in tags if tag not in NON_SUBJECT_TAGS]
        category = primary_category(tags)
        used_categories.add(category)

        tokens = set(name.split("."))
        keywords = []
        for keyword in search_by_name.get(name, []):
            lowered = keyword.lower()
            if lowered not in tokens and lowered not in keywords:
                keywords.append(lowered)
        keywords = keywords[:8]

        symbols.append({"name": name, "category": category, "keywords": keywords})

    categories = [
        {"key": key, "title": CATEGORY_TITLES[key]}
        for key in CATEGORY_TITLES
        if key in used_categories
    ]
    return {"deploymentSymbolYear": DEPLOYMENT_SYMBOL_YEAR, "categories": categories, "symbols": symbols}


def main() -> int:
    if not GLYPHS_RESOURCES.exists():
        print(f"SFSymbols resources not found at {GLYPHS_RESOURCES}", file=sys.stderr)
        return 1
    catalog = build()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(catalog, separators=(",", ":"), sort_keys=False))
    size_kb = OUTPUT.stat().st_size / 1024
    print(
        f"wrote {OUTPUT.relative_to(OUTPUT.parent.parent.parent)}: "
        f"{len(catalog['symbols'])} symbols, {len(catalog['categories'])} categories, {size_kb:.0f} KB"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
