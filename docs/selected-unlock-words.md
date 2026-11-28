# Learning rules and unlock words

Open Learning rules and choose the words to review before unlocking an app.
The picker supports multiple words, search and date filters for everyone.
Saving a selection sets the next challenge to that exact list. The button shows
how many words each unlock will require. New notebook words join the list only
when selected. Listen, Review and their custom lists keep their existing rules.

Existing configurations keep their active rule until the user saves a new
selection. This includes automatic pools and explicit pools whose configured
count is smaller than the pool. The picker starts an automatic pool with a
suggestion matching the current count. It shows the full saved list for an
existing explicit pool so the user can confirm or edit it. Cancelling keeps
both the saved rule and progress.

The existing SQLite fields store the selection and count. Saving an explicit
selection makes the count match the list. Deleting a selected word reduces the
available challenge. If no selected words are available, the user can choose a
new list. Completed work and pending answers are scoped to each protected app.
When editing a rule, only work on words retained in the selection is carried
forward. Preview does not change saved progress.

App protection, word selection and multi-word unlock challenges are free.
Veea Pro Lifetime adds configurable multi-word standalone Practice Rounds from
Home. See the [offer and acceptance criteria](pro-99k-model.md).
