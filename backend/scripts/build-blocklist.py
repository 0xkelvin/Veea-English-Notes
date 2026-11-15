#!/usr/bin/env python3
"""Builds internal/identity/blocklist/common-passwords.txt from a source password list.

    scripts/build-blocklist.py <source.txt> <output.txt>

Each entry is normalized exactly as the password policy normalizes input (NFKC, then
lowercase). Entries shorter than the policy minimum (15) are dropped because the length
rule already rejects them, and entries longer than the maximum (128) are dropped because
no password can match them. The result is deduplicated and sorted, one entry per line.
See internal/identity/blocklist/README.md for the source and how it was pinned.
"""
import sys
import unicodedata

MIN_LEN, MAX_LEN = 15, 128


def main(src: str, dst: str) -> None:
    seen = set()
    total = undecodable = 0
    with open(src, "rb") as f:
        for raw in f:
            total += 1
            try:
                line = raw.rstrip(b"\r\n").decode("utf-8")
            except UnicodeDecodeError:
                undecodable += 1
                continue
            entry = unicodedata.normalize("NFKC", line).lower()
            if MIN_LEN <= len(entry) <= MAX_LEN:
                seen.add(entry)
    entries = sorted(seen)
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(entries) + "\n")
    print(f"read={total} undecodable={undecodable} kept={len(entries)}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
