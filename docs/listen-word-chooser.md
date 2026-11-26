# Listen: Choose words

The Listen word chooser replaces the old Commute Tape Selector with a list-first
sheet. The initial screen shows searchable words grouped by readable dates;
Calendar expands on request. Words and Saved lists are the only peer sections.
There is one overall selected-word count and a pinned Play selection button.

Users can select all words, select search matches, clear the selection, toggle
individual words or a whole date, and select across calendar dates. Searching
does not discard selections outside the results. The current playlist remains
selected when reopening. Empty selections cannot start playback or be saved.

Saved lists retain create, edit, play and delete. List naming and editing support
the on-screen keyboard, with Save reachable above it. Word rows use lazy list
rendering for large notebooks. Existing playback and storage services are reused.

Actual agy CLI implemented the redesign and test updates. Its editing turn
reached its 10-minute limit after writing both assigned files. Codex reviewed the
result, corrected an unsupported Wrap baseline property, compacted the 200%
footer/header, fixed widget-test scroll targeting, and verified the final code.

Verification: nine chooser interaction/layout tests cover exact playback
selection, calendar dates, reopening a playlist, saved lists, a 320-point screen
with keyboard, 200% text, landscape, dark mode and a 500-word notebook. The full
Flutter suite passed with 776 tests and eight intentional skips. The analyser
was clean. Real-font layout captures additionally cover the chooser, expanded
calendar and saved lists. These are local checks, not a signed-phone deployment.
