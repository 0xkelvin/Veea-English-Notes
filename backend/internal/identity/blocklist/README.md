# Password blocklist

`common-passwords.txt` is embedded into the binary (`go:embed`) and loaded into a hash set at
startup by `identity.DefaultBlocklist`. It backs the `too_common` rule of the password policy
(TRD 01 section 9.1).

## Source

| | |
|---|---|
| List | `Passwords/Common-Credentials/Pwdb_top-1000000.txt` from [SecLists](https://github.com/danielmiessler/SecLists) |
| Pinned commit | `cc28d5e100cadf6f8b9aa644ff748ac69d454174` |
| Source SHA-256 | `e9a88f67aafe65496682dc374559ee714e978bee50314767494c3e37a18c9fc8` (1,000,000 lines) |
| Licence | MIT (SecLists) |
| Retrieved | 2026-11-13 |

The list is the 1,000,000 most frequent passwords seen in public breach corpora.

## Processing

`scripts/build-blocklist.py` normalizes every entry like the policy does (Unicode NFKC, then
lowercase), keeps entries of 15 to 128 code points, removes duplicates and sorts. Result:
**5,329 entries**.

Why so few: the policy minimum is 15 characters, so any entry shorter than that is rejected by
the length rule anyway and would only cost memory. The TRD estimate of "about 100k entries"
assumed an unfiltered list.

## Behavior and limits

- Matching is exact on the normalized, lowercased password. There is no fuzzy or leetspeak
  matching, no keyboard-pattern detection and no online breach lookup in Phase 1.
- Entries are data, not code. Leading and trailing spaces in an entry are significant.
- Some entries are artifacts of the source (for example `$hex[...]` encodings). They are
  harmless and kept so the file stays a straight filter of the source.

## Regenerating

```sh
# Download the pinned source, check its SHA-256 against the table above, then:
scripts/build-blocklist.py <source.txt> internal/identity/blocklist/common-passwords.txt
```

Updating the list means a new pinned commit, a new source hash and a new count in this file.
A unit test checks that the embedded file is sorted, unique, lowercase, NFKC-normalized and
within the length bounds.
