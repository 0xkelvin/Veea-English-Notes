# Learning rules: selected words are the challenge

Owner decision: 27 November 2026. This replaces the larger rotating practice pool
plus a separate “words per unlock” quota for app unlocking.

## User flow

- Learning rules shows “Review N words to unlock”, the selected words/meanings,
  one Change words action, pronunciation and a safe practice preview.
- Select one word: review that exact word each time. Select two words on Pro:
  review both, once each, before every unlock. Four selected means all four.
  There is no independent count editor or hidden subset.
- Free uses a single-choice word list: tapping another word replaces the current
  choice. Multiple selection is explicitly offered through Pro. Cancelling the
  upgrade or picker preserves the saved selection.
- Pro uses checkboxes with search, dates and select-all. The final action says
  “Use N words per unlock”, including words selected outside the current filter.
- New notebook words do not join an unlock challenge automatically. The ordinary
  notebook, Listen, Review and their custom lists remain unlimited and free.
- App locks, timers, purchase verification and the one-time Pro product are
  otherwise unchanged. Pro still enables multiple apps and multiple unlock words.

## Saved configuration and progress

The existing SQLite `practice_word_ids_json` remains the selection source. The
legacy `words_per_unlock` column is retained for compatibility and synchronized
to the saved selection size. Runtime count comes from the active selection.
The old setter maps a legacy count request to a real selection; the UI never
exposes it as a second control. No database schema migration is added.

An existing explicit selection is kept, even if its old quota was smaller. Legacy
null/automatic pools are frozen to the old count's worth of notebook words,
including unfinished answer IDs so earned work is not discarded. New words do
not silently enlarge that list. Unavailable/deleted words are excluded; deleting
the final selected word asks the user to choose again.

On Free, only the first saved word is active. Extra Pro selections stay saved
and are clearly shown as paused; restoring Pro restores the full word list.
Explicitly editing on Free replaces it with the newly chosen single word.

Completed answers remain scoped per app and are not duplicated. Normal access
upgrades preserve an open round's target; a downgrade permits the one-word Free
rule. Recovering from an empty challenge starts the newly selected target,
rather than keeping the stale empty round's one-word fallback. A retry of an
already-earned pending answer remains valid across a downgrade. The legacy
notebook fallback cannot substitute an unselected word into an unlock challenge.

## Verification

Regression coverage checks exact two/four-word challenges, no early unlock,
per-app interrupted progress, restarts, failed final grants, downgrade/restore,
Free enforcement, selection replacement, cancelled edits/upgrades, frozen future
words, deletion recovery and the empty-challenge target reset. Widget checks
exercise phone, 200% text and dark layouts; real-font captures were inspected.
The full learner Flutter suite and analyzer are run for this candidate, including
Listen/Review/shared-picker coverage. Physical signed TestFlight testing remains
Nin's release check; this change is not an installation on a phone.

Final local results: **815 Flutter tests passed, 8 existing environment-dependent
skips**; analyzer clean. Source is based on `main` after merged PR #49. No commit
was added to the branches for already-merged PRs #47, #48 or #49.
