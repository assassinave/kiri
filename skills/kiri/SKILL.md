---
name: kiri
description: Load the screenshots and notes on the kiri menu-bar app's shelf (mirrored live to disk, or from its Copy All / Copy for Agent exports) and carry out the changes the notes ask for in the current project. Use when the user invokes /kiri, or says "grab my kiri shots", "read my captures", "look at the screenshots I just copied", or refers to kiri notes.
---

# Act on kiri captures

While kiri runs it mirrors its shelf to disk, keeping it in step as captures are added or
deleted and notes are typed or dictated (within about a second):

```
<per-user temp dir>/kiri/live/        ← the current shelf; emptied when kiri launches
    kiri-1.png … kiri-N.png           ← in shelf order; renumbered when one is deleted
    kiri-notes.md                     ← only while at least one capture has a note
```

Each press of **Copy All** or **Copy for Agent** in the Show All grid (⌃⇧5) also writes a
frozen snapshot to `<per-user temp dir>/kiri/<yyyy-MM-ddTHHmmss>/` (UTC timestamp), same
layout.

`kiri-notes.md` has one `## kiri-N.png` section per capture with a note. The note is what
the user typed or dictated about that capture, usually the change they want. Captures
without a note have no section.

## 1. Find the captures

Run the helper next to this file. It resolves the temp dir itself (don't rely on `$TMPDIR`
in the CLI, which may differ from the app's):

```bash
~/.claude/skills/kiri/latest.sh            # the live shelf: image paths, pixel sizes, notes
~/.claude/skills/kiri/latest.sh --list     # the live shelf, then every export, newest first
~/.claude/skills/kiri/latest.sh <folder>   # a specific one from --list
```

Use the live shelf unless the user names an export. If the user just added a note and it
isn't there yet, run the script again after a moment.

- **No live folder:** kiri isn't running, or it's a build without the mirror. Say so and
  offer the newest export from `--list`, giving its time.
- **Live shelf empty:** tell the user the shelf has no captures. If they mean an earlier
  set, offer the exports from `--list`.
- Exports are never cleaned up by kiri. If you use one from an earlier day, tell the user
  its time and ask before going on.

## 2. Read everything

- **Read every PNG** with the Read tool (it shows images). Don't skip any: a capture
  without a note can still be the "before" or the context for another note.
- Read the notes printed by the script. Pair each `## kiri-N.png` note with its image.
- If there's no `kiri-notes.md`, the user gave no instructions with the images. Describe
  what you see briefly and ask what they want done. Don't guess at a change.

## 3. Make the changes

Work in the **current project** (the CLI's working directory), not the kiri folder. The
temp folders are read-only input; never edit or delete them.

1. For each note, restate in one line what it asks for and which image it refers to.
2. Find the code responsible for what's shown: search for visible strings, labels and
   component names from the screenshot. Say which file you matched and why. If nothing
   in the project plausibly produced the screenshot, say so instead of editing something
   unrelated.
3. If a note is ambiguous (unclear target, "make it better"), ask about that one and
   carry out the clear ones.
4. Make the edits, following the project's own conventions and any `CLAUDE.md`.
5. Finish with a short list per capture: `kiri-N.png`, the note, what you changed (with
   `file:line`) or why you didn't. Say which changes you verified (build, test, ran it)
   and which you didn't.
