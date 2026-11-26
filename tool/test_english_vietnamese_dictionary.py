"""Source filtering and shipped dictionary integrity (standard library only)."""
import gzip
import hashlib
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from build_english_vietnamese_dictionary import clean_gloss, collect


class DictionaryTests(unittest.TestCase):
    def test_filters_and_merges_vietnamese_senses(self):
        records = [
            {"word": "AIRPORT", "lang_code": "en", "pos": "noun", "senses": [
                {"glosses": ["Sân   bay"]}, {"glosses": ["Sân bay"]},
                {"glosses": ["Bến hàng không"]}, {"glosses": ["nghĩa thứ ba"]}]},
            {"word": "airport", "lang_code": "en", "pos": "verb", "senses": [
                {"glosses": ["nghĩa khác"]}]},
            {"word": "avion", "lang_code": "fr", "pos": "noun", "senses": [
                {"glosses": ["máy bay"]}]},
            {"word": "someone", "lang_code": "en", "pos": "name", "senses": [
                {"glosses": ["tên riêng"]}]},
        ]
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "source.gz"
            with gzip.open(source, "wt", encoding="utf-8") as stream:
                for item in records:
                    stream.write(json.dumps(item) + "\n")
            result = collect(source)
        self.assertEqual(list(result), ["airport"])
        self.assertEqual(result["airport"]["senses"], ["Sân bay", "Bến hàng không"])
        self.assertEqual(result["airport"]["title"], "AIRPORT")
        for invalid in ["", "{{template}}", "; malformed", "English only", "nghĩa" * 100]:
            self.assertIsNone(clean_gloss(invalid))

    def test_shipped_asset_matches_manifest_and_attribution(self):
        folder = Path(__file__).resolve().parents[1] / "assets/dictionary"
        manifest = json.loads((folder / "manifest.json").read_text())
        asset = (folder / "en_vi.sqlite.gz").read_bytes()
        unpacked = gzip.decompress(asset)
        self.assertEqual(hashlib.sha256(asset).hexdigest(), manifest["asset_sha256"])
        self.assertEqual(hashlib.sha256(unpacked).hexdigest(), manifest["sqlite_sha256"])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "dictionary.sqlite"
            path.write_bytes(unpacked)
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                self.assertEqual(db.execute("SELECT count(*) FROM entries").fetchone()[0], 110986)
                self.assertEqual(db.execute("SELECT count(*) FROM entries WHERE source_title = '' OR meaning = ''").fetchone()[0], 0)
                self.assertEqual(dict(db.execute("SELECT * FROM metadata"))["licence"], "CC-BY-SA-4.0")
        self.assertIn("Vietnamese Wiktionary contributors", (folder / "NOTICE.txt").read_text())
        self.assertIn("Section 1 -- Definitions", (folder / "CC-BY-SA-4.0.txt").read_text())


if __name__ == "__main__":
    unittest.main()
