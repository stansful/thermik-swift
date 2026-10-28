#!/usr/bin/env python3 -I
"""l10n-merge.py — Thermik (MIT). Merges per-unit Russian translation fragments into the String Catalog.

Why: parallel implementation units must not edit the single JSON file App/Resources/Localizable.xcstrings.
Each unit owns App/Resources/L10n/<unit>.json; this script (run before building) regenerates the catalog.

Fragment format (UTF-8 JSON object, keys = English source strings exactly as written in Swift):
  "Fans": "Вентиляторы"                                        simple
  "Hottest · %@": {"ru": "Самый горячий · %@", "comment": "…"}  with a translator comment
  "%lld sensors": {"en": {"one": "%lld sensor", "other": "%lld sensors"},
                   "ru": {"one": "%lld датчик", "few": "%lld датчика", "many": "%lld датчиков", "other": "%lld датчика"}}
Interpolations: Text("\\(n) sensors") → key "%lld sensors"; String → "%@"; Double → "%lf".

Usage:
  python3 -I scripts/lib/l10n-merge.py            regenerate App/Resources/Localizable.xcstrings
  python3 -I scripts/lib/l10n-merge.py --missing  list literal UI strings in App/**/*.swift with no Russian translation
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FRAG_DIR = os.path.join(ROOT, "App", "Resources", "L10n")
CATALOG = os.path.join(ROOT, "App", "Resources", "Localizable.xcstrings")


def translation(val):
    """The part of a fragment value that reaches the catalog, without the translator comment."""
    if isinstance(val, str):
        return {"ru": val}
    return {k: v for k, v in val.items() if k != "comment"}


def load_fragments():
    merged, origin = {}, {}
    if not os.path.isdir(FRAG_DIR):
        return merged
    for name in sorted(os.listdir(FRAG_DIR)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(FRAG_DIR, name), encoding="utf-8") as f:
            data = json.load(f)
        for key, val in data.items():
            if key in merged:
                # Fragments may describe a shared key with different translator comments; only a different
                # translation is a conflict. The first fragment (sorted by name) wins either way.
                if translation(merged[key]) != translation(val):
                    print(f"warning: '{key}' translated differently in {origin[key]} and {name}; keeping {origin[key]}", file=sys.stderr)
                continue
            merged[key], origin[key] = val, name
    return merged


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(forms):
    return {"variations": {"plural": {k: unit(v) for k, v in forms.items()}}}


def build(existing, fragments):
    strings = existing.get("strings", {})
    for key, val in fragments.items():
        entry = strings.get(key, {"extractionState": "manual"})
        locs = entry.setdefault("localizations", {})
        if isinstance(val, str):
            locs["ru"] = unit(val)
        else:
            if "comment" in val:
                entry["comment"] = val["comment"]
            ru = val.get("ru")
            if isinstance(ru, str):
                locs["ru"] = unit(ru)
            elif isinstance(ru, dict):
                locs["ru"] = plural(ru)
            en = val.get("en")
            if isinstance(en, dict):
                locs["en"] = plural(en)
            elif isinstance(en, str):
                locs["en"] = unit(en)
        strings[key] = entry
    return {"sourceLanguage": "en", "strings": dict(sorted(strings.items())), "version": "1.0"}


LITERAL = re.compile(r'(?:String\(localized:\s*|Text\(|Label\(|Button\(|Toggle\(|Picker\(|Section\(|LabeledContent\(|\.help\(|'
                     r'\.accessibilityLabel\(|\.accessibilityHint\(|'
                     # App Intents (titles, parameters, summaries, dialogs) are LocalizedStringResource literals.
                     r'LocalizedStringResource\(\s*|LocalizedStringResource\s*=\s*|IntentDescription\(\s*|IntentDialog\(\s*|'
                     r'TypeDisplayRepresentation\(name:\s*|DisplayRepresentation\(title:\s*|@Parameter\(title:\s*|Summary\(\s*)'
                     r'"((?:[^"\\]|\\.)+)"')
FORMAT_SPEC = re.compile(r"%(?:\d+\$)?(?:ll|l|h|hh|q|z|t|j)?[@dDiuUxXoOfFeEgGaAcCsSp]")
# App Intents parameter summaries use "${name}" placeholders in their keys ("Get the ${source} temperature").
INTENT_PLACEHOLDER = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}")


def interpolations_to_spec(s):
    """Text("\\(f(x)) rpm") → "%@ rpm" (balanced parentheses; the real specifier depends on the type)."""
    out, i = [], 0
    while i < len(s):
        if s.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(s) and depth:
                depth += {"(": 1, ")": -1}.get(s[j], 0)
                j += 1
            out.append("%@")
            i = j
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def normalized(key):
    """Compare keys independently of the specifier type: "%lld s", "%@ s", "%1$@ s" and "${n} s" all match."""
    return INTENT_PLACEHOLDER.sub("%@", FORMAT_SPEC.sub("%@", key))


def missing(fragments):
    found = set()
    for d, _, files in os.walk(os.path.join(ROOT, "App")):
        for fn in files:
            if fn.endswith(".swift"):
                with open(os.path.join(d, fn), encoding="utf-8") as f:
                    for m in LITERAL.finditer(f.read()):
                        found.add(interpolations_to_spec(m.group(1)))
    known = {normalized(k) for k in fragments}
    for s in sorted(found):
        if normalized(s) not in known:
            print(s)


if __name__ == "__main__":
    frags = load_fragments()
    if "--missing" in sys.argv:
        missing(frags)
        sys.exit(0)
    existing = {}
    if os.path.exists(CATALOG):
        with open(CATALOG, encoding="utf-8") as f:
            existing = json.load(f)
    out = build(existing, frags)
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write("\n")
    print(f"Localizable.xcstrings: {len(out['strings'])} keys ({len(frags)} with Russian from {FRAG_DIR})")
