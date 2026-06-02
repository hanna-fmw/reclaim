# reclaim

A tiny, process-aware disk and memory janitor for macOS.

`reclaim` is **not** another disk cleaner. It is a small, auditable workspace
agent that happens to clean. Its one rule: **never delete anything you appear to
be actively working on**, and **log every decision** so it is fully auditable.

It runs on a schedule (launchd), pops up an approval dialog, frees only
regenerable caches and junk, shows how much it freed, and records every removed
path in an append-only JSON log.

---

## Why this exists (and why it is not just another cleaner)

Plenty of open-source Mac cleaners exist (PureMac, ClearDisk, mac-ops,
mac-cleaner-cli, macos-cache-cleaner) and they all use launchd - that part is
table stakes, not a feature. The cleaning itself is a commodity.

Three things make `reclaim` different, and the commodity tools genuinely lack
all three:

1. **Active-work awareness.** Before deleting a project's build cache it checks
   whether you are working in that project - a running dev server (`lsof`), a
   dirty git tree, or any file edited in the last 24 hours. If so, it is left
   completely alone. It reads your live workflow before it acts.
2. **Auditable, not a black box.** Every run appends one line to
   `history.jsonl` recording the exact paths removed, their sizes, what was
   protected and why, and real before/after free space. ~250 lines of
   transparent bash, zero telemetry.
3. **It reasons about its own tradeoffs.** For example it deliberately does
   *not* offer Trash-recovery: macOS Trash is on the same volume, so moving a
   cache there frees ~0 bytes until the Trash is emptied, and `.next` caches are
   regenerable so recovery has near-zero value. Trash-recovery would make it
   slower, more complex, and worse at its one job.

---

## What it cleans (and never touches)

**Removes (all regenerable or junk):**
- Next.js `.next` build/dev caches in `~/Documents` projects
- Leftover installer `.dmg` files (e.g. app self-updaters)
- Docker dangling images + build cache (`docker system prune -af`)

**Never touches:**
- Any project with a running dev server, a dirty git tree, or a file edited in
  the last 24h (configurable via `PROTECT_HOURS`)
- Cloud-only files (Google Drive 0-byte placeholders)
- Docker **volumes** (they can hold project databases)
- Anything outside the explicit safe categories above

Space freed is always measured from real `df` before/after, never estimated.

---

## Install

```sh
cd ./reclaim
./install.sh
```

This deploys the scripts to `~/.disk-cleanup/`, symlinks the `reclaim` CLI onto
your PATH, and loads the launchd schedule. To remove everything:

```sh
./uninstall.sh
```

The project folder is the **source of truth**. Edit here, then re-run
`./install.sh` to deploy. Runtime state (`history.jsonl`, `last-run`) lives in
`~/.disk-cleanup/` and is not part of the repo.

---

## Usage

```
reclaim clean          scan, then pop up the approval dialog
reclaim clean -y       clean all safe items immediately, no dialog
reclaim scan           notify how much is cleanable (deletes nothing)
reclaim dry            print the plan (no dialog, no delete)
reclaim history        table of past runs + space freed
reclaim history clear  archive + reset the log
reclaim stats          lifetime totals
reclaim trend          regrowth rate + forecast from the audit log
reclaim top            live scan of your biggest space users
reclaim status         schedule state, last run, free space
reclaim ram            top memory hogs + Chrome tab breakdown
reclaim enable/disable turn the schedule on/off
reclaim help           this
```

### The approval dialog
On a scheduled or manual run it shows an overview (free space, the
`.next`/DMG/Docker breakdown, and which projects are protected and why) with
three buttons:
- **Clean all** - remove every safe category
- **Choose...** - a checklist to pick categories (e.g. skip Docker today)
- **Skip** - do nothing (logged as a skip)

---

## Schedule

The launchd agent (`dev.reclaim.plist`) fires daily at **08:45**. The
script holds a **3-day gate** (`INTERVAL_DAYS=3`), so it only actually acts
every ~3 days. If the Mac is asleep at 08:45, macOS runs it on next wake.
Running `reclaim` manually always bypasses the gate.

---

## The audit log

`~/.disk-cleanup/history.jsonl` - one JSON object per run. Example clean entry:

```json
{"ts":"2026-06-01T08:45:03Z","action":"clean","freed_kb":12345678,
 "cleaned":{"next":1,"dmg":1,"docker":1},"next_dirs":12,"dmgs":2,
 "protected":{"running":5,"dirty":1,"recent":2},"free_after_kb":45000000,
 "removed":[{"path":"/Users/.../foo/.next","kb":810240}, ...]}
```

This is the "git for data" flat-file approach: append-only, greppable, and
git-trackable if you choose to version it.

---

## File layout

```
reclaim/
  cleanup.sh                    core engine (scan, protect, dialog, clean, log)
  reclaim                       CLI front-end
  dev.reclaim.plist  launchd schedule (daily 08:45)
  install.sh                    deploy to ~/.disk-cleanup + symlink + load launchd
  uninstall.sh                  unload + remove symlink
  README.md
  LICENSE
```

Deployed runtime (created by install.sh):
```
~/.disk-cleanup/
  cleanup.sh, reclaim           deployed copies
  history.jsonl                 audit log (runtime state)
  last-run                      epoch of last real run (drives the 3-day gate)
~/Library/LaunchAgents/dev.reclaim.plist
/opt/homebrew/bin/reclaim       symlink onto PATH
```

---

## Configuration

Edit the constants at the top of `cleanup.sh`:
- `INTERVAL_DAYS` - days between scheduled actions (default 3)
- `PROTECT_HOURS` - "recently edited" protection window (default 24)
- `DOCS` - root scanned for `.next` caches (default `~/Documents`)
- `DMG_DIR` - directory swept for installer `.dmg` files

To change the schedule time, edit `StartCalendarInterval` in the plist and
re-run `./install.sh`.

---

## Requirements

macOS, `bash` 3.2+ (system default), `python3` (system default), and optionally
Docker (the Docker step is skipped silently if the daemon is not running).
