# Offline English–Vietnamese meanings

The app includes 110,986 normalized English headwords adapted from Vietnamese
Wiktionary through Kaikki/Wiktextract. The compressed asset is 3,107,148 bytes;
its separate, read-only SQLite copy occupies 8,937,472 bytes. On first use it is
unpacked off the UI thread. No account or network request is needed.

## Lookup and privacy

The full lookup checks personal notes across notebook dates first, then a hot
cache and curated meanings, saved online results, and the bundled dictionary.
Exact dictionary headwords win over conservative noun/verb plural fallbacks.
Suggestions never overwrite saved words or fill the editor without approval.
Late results cannot replace the next word being typed.

Online requests remain explicitly opt-in per lookup. Successful Google Translate
or MyMemory results are stored in the device-wide `online_meaning_cache` table
(local schema 15), outside account/sync data. Unknown, failed, identity, HTML and
quota responses are not saved. Clearing saved lookups in Settings also clears
memory results and waits for prior writes, without deleting notebook words or
the bundled dictionary. A failed write still leaves a successful lookup visible.
The existing online provider endpoints still require provider/production review;
this change does not establish a commercial service agreement.

## Source and redistribution

Data: CC BY-SA 4.0, Vietnamese Wiktionary contributors. Attribution, changes,
source links and the full licence are bundled and readable offline in Settings
→ Offline dictionary. Each bundled suggestion links to its original entry.
The data licence applies to this separate dictionary adaptation. Private online
results are neither added to the public dataset nor redistributed with it.
Community definitions can be incomplete or wrong; the user chooses the sense.

`assets/dictionary/manifest.json` pins the dump (2026-10-02), extraction
(2026-11-03), source SHA-256, converted hashes and sizes. Retain the downloaded
source externally for future reproducible builds; Kaikki may replace its current
download. Never replace the source checksum without reviewing a new revision.

Rebuild with Python's standard library:

```sh
python3 tool/build_english_vietnamese_dictionary.py /path/to/pinned-source.jsonl.gz
python3 -m unittest discover -s tool -p 'test_english_vietnamese_dictionary.py'
```

The separately licensed data, converter and notice must be published together
before distributing a release that advertises the public GitHub attribution
links. Vocabulary/account schemas and the disabled word-sync gate are unchanged.

## Verification

Tests exercise real bundled SQLite lookups without HTTP, a schema-14 upgrade,
cache reuse after closing and reopening both databases, personal meanings across
dates, deletion, failed provider results, UTF-8 responses, in-flight clear races,
corruption recovery, stale editor results, credits and cache clearing. Layout
checks include 320-point screens, 200% text, landscape and dark mode.
