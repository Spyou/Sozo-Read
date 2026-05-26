# Future features

Parking lot for ideas we want to ship later, but not now. Add new
entries at the top.

---

## Per-book notification subscription (bell icon on detail screen)

**Status:** deferred (2026-05-26).

**Goal:** Let the user explicitly opt a single book into / out of new-chapter
notifications, and pick a global mode for what "no opt-in" means.

**Sketch of the design we discussed:**

- Add a bell icon to the detail screen's AppBar (outline = not subscribed,
  filled = subscribed). Tapping toggles subscription for that book.
- Persist the choice on `LibraryEntry` as a new nullable `bool? notify`:
  - `null` -> follow the global mode
  - `true` -> always notify (overrides mode)
  - `false` -> always silent (overrides mode)
- Add a global mode in `NotificationsPrefsCubit`:
  - **Auto + manual** (default): continue-reading books notify
    automatically; the bell can add or remove specific books.
  - **Manual only**: nothing notifies unless the bell is on.
- `chapter_check_service` already walks every library entry today; gate it
  on `_shouldNotify(entry, mode)`.
- If the user taps the bell on a book that isn't in the library yet, silently
  add it so the background scanner can track it.

**Open questions to settle when picking this up:**

1. Should the default mode be **Auto + manual** or **Manual only**?
2. Where does the mode toggle live — its own `/settings/notifications` page,
   or a row inside the existing Updates settings page?
3. Long-press the bell to reset to "follow default", or skip that and keep
   the bell strictly two-state?
