#!/usr/bin/env python3
"""Build the bundled IPA pronunciation dictionary.

The app shows pronunciation automatically rather than asking for it: a phone
keyboard has no way to type `/rɪˈzɪljənt/`, so requiring the user to enter it
means the field is always empty.

Source is the CMU Pronouncing Dictionary, which is General American and gives
ARPABET phonemes. This converts those to IPA, keeps one pronunciation per word,
and writes a gzipped `word<TAB>ipa` table.

Usage:
    python3 tool/build_pronunciation_dictionary.py [cmudict.dict] \
        assets/pronunciation/en_us_ipa.txt.gz

With no input path the dictionary is downloaded from upstream.
"""

import argparse
import gzip
import re
import sys
import urllib.request

CMUDICT_URL = (
    "https://raw.githubusercontent.com/cmusphinx/cmudict/master/cmudict.dict"
)

# ARPABET to IPA, General American.
#
# `r` rather than the strict `ɹ`, and `ɜr`/`ər` for ER, because that is what
# learner dictionaries print and therefore what the user will have seen
# elsewhere. Strict IPA would be more correct and less recognisable.
PHONES = {
    "AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ",
    "B": "b", "CH": "tʃ", "D": "d", "DH": "ð", "EH": "ɛ", "ER": "ɜr",
    "EY": "eɪ", "F": "f", "G": "ɡ", "HH": "h", "IH": "ɪ", "IY": "i",
    "JH": "dʒ", "K": "k", "L": "l", "M": "m", "N": "n", "NG": "ŋ",
    "OW": "oʊ", "OY": "ɔɪ", "P": "p", "R": "r", "S": "s", "SH": "ʃ",
    "T": "t", "TH": "θ", "UH": "ʊ", "UW": "u", "V": "v", "W": "w",
    "Y": "j", "Z": "z", "ZH": "ʒ",
}

VOWELS = {
    "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER",
    "EY", "IH", "IY", "OW", "OY", "UH", "UW",
}

PHONE_RE = re.compile(r"^([A-Z]+)([012])?$")
WORD_RE = re.compile(r"^[a-z'.-]+$")


def convert(phones):
    """Convert one ARPABET pronunciation to IPA, or None if unconvertible."""
    parsed = []
    for phone in phones:
        match = PHONE_RE.match(phone)
        if not match:
            return None
        base, stress = match.group(1), match.group(2)
        if base not in PHONES:
            return None

        symbol = PHONES[base]
        # CMUdict spells both the STRUT vowel and schwa as AH; only the stress
        # digit tells them apart.
        if base == "AH" and stress == "0":
            symbol = "ə"
        elif base == "ER" and stress == "0":
            symbol = "ər"

        parsed.append((symbol, base in VOWELS, stress))

    pieces = [symbol for symbol, _, _ in parsed]
    vowel_count = sum(1 for _, is_vowel, _ in parsed if is_vowel)

    # A stress mark belongs before the whole syllable, not before its vowel, so
    # walk back over the preceding consonant cluster (the onset).
    for index in range(len(parsed) - 1, -1, -1):
        _, is_vowel, stress = parsed[index]
        if not is_vowel or stress not in ("1", "2"):
            continue

        onset = index
        while onset > 0 and not parsed[onset - 1][1]:
            onset -= 1

        # A one-syllable word has nothing to contrast against, so a leading
        # mark is just noise.
        if onset == 0 and vowel_count == 1:
            continue

        pieces[onset] = ("ˈ" if stress == "1" else "ˌ") + pieces[onset]

    return "".join(pieces)


def build(lines):
    entries = {}
    for line in lines:
        line = line.split("#")[0].strip()
        if not line:
            continue

        parts = line.split()
        word = parts[0]

        # `word(2)` marks an alternate pronunciation; the first entry is the
        # common one and showing a single answer is the whole point here.
        if "(" in word or not WORD_RE.match(word):
            continue

        ipa = convert(parts[1:])
        if ipa:
            entries.setdefault(word, ipa)

    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", help="cmudict.dict (downloaded if omitted)")
    parser.add_argument("output", help="destination .txt.gz")
    args = parser.parse_args()

    if args.source:
        with open(args.source, encoding="utf-8") as handle:
            lines = handle.readlines()
    else:
        print(f"downloading {CMUDICT_URL}", file=sys.stderr)
        with urllib.request.urlopen(CMUDICT_URL) as response:
            lines = response.read().decode("utf-8").splitlines()

    entries = build(lines)
    packed = "".join(f"{w}\t{p}\n" for w, p in sorted(entries.items()))
    raw = packed.encode("utf-8")

    # mtime=0 so rebuilding the same input produces a byte-identical file and
    # does not show up as a spurious diff.
    with gzip.GzipFile(args.output, "wb", compresslevel=9, mtime=0) as handle:
        handle.write(raw)

    print(
        f"{len(entries):,} entries  "
        f"{len(raw) / 1024:.0f} KB raw  ->  {args.output}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
