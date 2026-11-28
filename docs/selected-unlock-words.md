# Learning rules and unlock words

Owner decision, 28 November 2026: Free has one selected unlock word; one-time
Pro enables multiple selected unlock words. Ordinary learning stays free.

The user chooses the actual words, using search and dates. Each unlock reviews
every active selected word once. One selected word means one answer; four selected
words means four answers on Pro. There is no independent count over a larger pool.
Free uses a single-selection picker, and replacing that word is free. Confirming
the unchanged visible Free word keeps the paused paid list and its unfinished
answers; explicitly choosing a different word replaces that saved list, as explained
in Learning rules. Pro uses checkboxes. Cancelling leaves both the saved selection and progress unchanged.
Listen, ordinary Review, standalone Practice Rounds and custom lists are unrestricted.

An old automatic pool becomes an explicit selection matching its saved count,
preserving unfinished answers. An old explicit selection uses its full list on
Pro, even if its former quota was smaller. Free activates one saved word and keeps
the rest paused. Upgrading restores that saved selection; only deliberately saving
a replacement changes it. New notebook words never enlarge an existing challenge.

The existing SQLite selection/count fields are reused; count is synchronized to
the saved list. Deleting selected words reduces the available challenge. If none
remain, the user can choose a new list. Answers and interrupted progress belong
to each protected app. Pending earned answers remain recoverable across plan
changes. Preview does not record review progress or grant access.

See [the Free/Pro offer](pro-99k-model.md) and [device acceptance](pro-99k-qa.md).
