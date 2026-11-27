"""Ready-made prompts from lib/prompt-library.tsv, in the panel language."""

import unicodedata

import core

LIBRARY = core.RESOURCES / "prompt-library.tsv"
LANGUAGES = ("pt-BR", "en", "es")


def load(path=LIBRARY):
    """Returns {key: {language: entry}}; malformed lines are skipped, never executed."""
    table = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return table
    for line in lines:
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5 or fields[1] not in LANGUAGES or not fields[0].replace("-", "").isalnum():
            continue
        key, language, category, title, text = fields
        table.setdefault(key, {})[language] = {
            "key": key, "category": category, "title": title,
            "text": text.replace("\\n", "\n"), "file": key,
        }
    return table


def entries(language=None, path=LIBRARY):
    """Entries in one language, falling back to Portuguese for a missing translation."""
    language = language or core.PANEL_LANGUAGE
    chosen = []
    for translations in load(path).values():
        entry = translations.get(language) or translations.get("pt-BR") or next(iter(translations.values()))
        chosen.append(dict(entry))
    return chosen


def fold(value):
    decomposed = unicodedata.normalize("NFKD", value.casefold())
    return "".join(character for character in decomposed if not unicodedata.combining(character))


def search(items, query):
    """Every word of the query must appear in the category, title or text, ignoring accents and case."""
    words = fold(query).split()
    if not words:
        return list(items)
    found = []
    for entry in items:
        haystack = fold(" ".join((entry["category"], entry["title"], entry["text"])))
        if all(word in haystack for word in words):
            found.append(entry)
    return found
