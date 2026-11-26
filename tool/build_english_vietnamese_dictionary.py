#!/usr/bin/env python3
"""Build the separately licensed, offline English–Vietnamese dictionary.

Input: Kaikki Vietnamese Wiktionary raw JSONL gzip, downloaded separately.
No network requests. A source checksum pins the exact reviewed snapshot.
The SQLite adaptation and its contents are CC BY-SA 4.0; see NOTICE.txt.
"""
import argparse
import gzip
import hashlib
import json
import re
import sqlite3
import unicodedata
from pathlib import Path

SOURCE_SHA256 = "1f0abd21982660b5fc2eff5eb3fbacbed2d9fe8f476af794dbed0d927ffb8187"
REVISION = "viwiktionary-20261002-v1"
POS = {"noun": "n", "verb": "v", "adj": "adj", "adv": "adv",
       "phrase": "phr", "proverb": "idm", "abbrev": "etc",
       "prep": "etc", "conj": "etc", "pron": "etc", "det": "etc",
       "num": "etc", "intj": "etc", "article": "etc", "contraction": "etc"}


def clean_gloss(value):
    text = re.sub(r"\s+", " ", unicodedata.normalize("NFC", value)).strip()
    # Raw extraction sometimes contains empty/template-only fragments.
    if not text or text.startswith((";", "{{", "[[", "http")):
        return None
    if not any("LATIN" in unicodedata.name(c, "") and ord(c) > 127 for c in text):
        return None
    if len(text) > 320:
        # Preserve a complete short sense, rather than cutting a sentence.
        return None
    return text


def collect(source):
    entries = {}
    with gzip.open(source, "rt", encoding="utf-8") as stream:
        for line in stream:
            record = json.loads(line)
            if record.get("lang_code") != "en" or record.get("pos") not in POS:
                continue
            title = unicodedata.normalize("NFC", record.get("word", "")).strip()
            key = " ".join(title.lower().split())
            if not 2 <= len(key) <= 200 or not re.fullmatch(r"[a-z][a-z0-9 '\-.,!?()/&]*", key):
                continue
            senses = []
            for sense in record.get("senses", []):
                if "no-gloss" in sense.get("tags", []):
                    continue
                glosses = sense.get("glosses", [])
                text = clean_gloss(glosses[-1]) if glosses else None
                if text and text not in senses:
                    senses.append(text)
            if not senses:
                continue
            entry = entries.setdefault(key, {"senses": [], "pos": POS[record["pos"]], "title": title})
            for text in senses:
                if text not in entry["senses"] and len(entry["senses"]) < 2:
                    entry["senses"].append(text)
    return entries


def build(source, output):
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError("Source checksum differs; review and pin a new revision before rebuilding")
    entries = collect(source)
    if len(entries) < 50000:
        raise ValueError("Unexpectedly small dictionary; refusing to replace the bundled data")
    output.mkdir(parents=True, exist_ok=True)
    scratch = output / "en_vi.build.sqlite"
    scratch.unlink(missing_ok=True)
    with sqlite3.connect(scratch) as db:
        db.execute("CREATE TABLE entries(word TEXT PRIMARY KEY, meaning TEXT NOT NULL, part_of_speech TEXT, source_title TEXT NOT NULL) WITHOUT ROWID")
        db.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
        db.executemany("INSERT INTO entries VALUES (?,?,?,?)", (
            (key, "; ".join(value["senses"]), value["pos"], value["title"])
            for key, value in sorted(entries.items())
        ))
        db.executemany("INSERT INTO metadata VALUES (?,?)", [
            ("revision", REVISION), ("entry_count", str(len(entries))),
            ("licence", "CC-BY-SA-4.0"), ("source_sha256", digest),
        ])
        db.execute("PRAGMA user_version = 1")
        db.commit()
        db.execute("VACUUM")
    unpacked = scratch.read_bytes()
    compressed = gzip.compress(unpacked, compresslevel=9, mtime=0)
    (output / "en_vi.sqlite.gz").write_bytes(compressed)
    scratch.unlink()
    manifest = {
        "revision": REVISION, "entry_count": len(entries),
        "source": "Vietnamese Wiktionary contributors, extracted by Kaikki/Wiktextract",
        "source_url": "https://kaikki.org/viwiktionary/raw-wiktextract-data.jsonl.gz",
        "source_page": "https://kaikki.org/viwiktionary/rawdata.html",
        "wiktionary_dump": "2026-10-02", "extraction_date": "2026-11-03",
        "retrieved_date": "2026-11-26", "source_sha256": digest,
        "asset_sha256": hashlib.sha256(compressed).hexdigest(),
        "sqlite_sha256": hashlib.sha256(unpacked).hexdigest(),
        "compressed_bytes": len(compressed), "sqlite_bytes": len(unpacked),
        "licence": "CC-BY-SA-4.0",
        "licence_url": "https://creativecommons.org/licenses/by-sa/4.0/",
        "changes": "English records only; normalized headwords; selected short Vietnamese glosses (up to two); grammatical categories mapped to app labels; other fields omitted; SQLite conversion.",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: manifest[key] for key in ["entry_count", "compressed_bytes", "sqlite_bytes", "asset_sha256"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, default=Path("assets/dictionary"))
    args = parser.parse_args()
    build(args.source, args.output)
