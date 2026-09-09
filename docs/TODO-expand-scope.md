# TODO: Expand reclaim's cleanup scope

reclaim currently only handles a narrow set of safe targets (`.next` caches, `.dmg` installers, Docker dangling images + build cache). On 2026-06-21 a manual disk audit found ~40 GB of additional safe-to-reclaim space that reclaim doesn't look at. Most of it could be added without losing the active-work-awareness guarantee.

## Candidates to add (ranked by impact)

### 1. Docker: full unused-image prune (~15-20 GB typical)
Current: `docker image prune -f` (dangling only) + `docker builder prune -f`.
Add: `docker system prune -af` equivalent — removes ALL unused images, not just dangling. Volumes still excluded (already correct).
Risk: next `docker compose up` redownloads images. Acceptable for non-active projects; gate behind "no Docker container has been started in N days" or just always.

### 2. Claude Code `vm_bundles` (~9.7 GB observed)
Path: `~/Library/Application Support/Claude/vm_bundles`
What it is: sandbox VM bundles Claude Code downloads for the Bash tool's sandbox mode.
Why safe: redownloaded on demand. Conversation history is elsewhere (~3 MB Local Storage).
Active-work check: skip if Claude.app is running (`pgrep Claude` or check the lockfile).

### 3. npm cache (~5 GB typical)
Command: `npm cache clean --force` (or just measure `~/.npm` and `rm -rf` it — npm rebuilds the dir empty).
Why safe: pure download cache, rebuilds on next `npm install`.
Active-work check: arguably none needed — even active projects don't need a warm cache.

### 4. Dormant `node_modules` (~5-10 GB possible)
For each project under `~/Documents/`:
- Skip if it satisfies the existing active-work checks (dev server running, dirty git, files edited within PROTECT_HOURS).
- Skip if any file in the project edited within the last N days (configurable, suggest 30).
- If both pass: `rm -rf <project>/node_modules`. Reinstalled on demand.
This is the biggest behavior change — wants a clear approval dialog listing each project before deleting.

### 5. General `~/Library/Caches/*` selective cleanup
Many app caches accumulate (often 9 GB+). Risky to blanket-delete (some apps misbehave). Possible approach: a known-safe allowlist (e.g. `ms-playwright` browser binaries, `Homebrew/downloads`, `pip`, `pnpm/dlx`). Lower priority.

PARTIALLY SHIPPED in v1.5 (2026-08-10): the allowlist approach was taken, with exactly one entry - `~/Library/Caches/Google` (3.3 GB observed) as category 8. Still open: `ms-playwright` (1.0 GB observed), `Homebrew` (615 MB observed), `pip`. Each needs its own reasoning before being added; do not blanket-sweep `~/Library/Caches/*`.

### 6. Google DriveFS local cache (~900 MB)
Path: `~/Library/Application Support/Google/DriveFS`
Better solution: surface a recommendation to switch Drive to "Stream files only" mode. Don't try to clear automatically — Drive manages this itself.

## What to NOT add
- Chrome / browser **profile** data — `~/Library/Application Support/Google/Chrome/*` (passwords, cookies, sessions, history). Too easy to break the user's flow: deleting a profile logs her out everywhere. This still stands and must not be softened.
  - NOTE: v1.5's category 8 is NOT a violation of this. It cleans `~/Library/Caches/Google` only — a sibling directory that holds no credentials — and refuses to run unless Chrome is quit. The cache/profile split is the whole point of that category; keep them separate if anyone extends it.
- Anything inside `~/Library/Application Support/<app>/` without explicit per-app reasoning (some hold real user data).
- `~/.cache` blanket — small (~23 MB observed) and risky.

## Suggested next step
Pick item 1 (full Docker prune) and item 3 (npm cache) first — biggest wins with the lowest behavior-change risk. Items 2 and 4 should ship behind a clear, itemized approval dialog.

---

## Status after v1.5 (2026-08-10)

Items 1-4 shipped in v1.4. Item 5 partially shipped (see above). Item 6 still open.

Added in v1.5, found by a manual audit that reclaim itself could not see:
- **Category 7, ballooned Turbopack caches.** The important find. Active-work protection skips a project entirely when its dev server runs, which is correct — but Next 16's persistent Turbopack cache (`.next/dev/cache/turbopack`, an append-only LSM store) grows per rebuild and is never compacted, so one project held 9.4 GB across 2,597 `.sst` segments that protection guaranteed would never be reported. Category 7 reports around the rule instead of weakening it.
- **Category 9, pnpm store** (3.2 GB observed). Was never on this list.
- **Category 10, stray recordings.** Reporting only, per-file approval, never preselected.
- Reboot gain is reported but never acted on; a down Docker daemon now offers to start itself.

Still open, in rough priority order:
1. Item 6 (Google DriveFS recommendation).
2. Remaining item-5 allowlist entries: `ms-playwright`, `Homebrew`, `pip`.
3. **Docker containers.** `prune -af` cannot touch an image while any container references it, so a machine running local dev stacks shows ~0 prunable despite many GB of images (observed 2026-08-10: 14 images, all held by 14 running containers, 11.5 GB). Surfacing *stopped* containers as a category would unlock that, but it deletes container state rather than a cache — it needs its own safety reasoning and explicit approval before anyone builds it. Do not fold it into the existing Docker category.
4. **Docker's disk image never shrinks, so pruning frees nothing on the Mac.** Everything Docker holds lives inside one file, `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`. Deleting images frees space *inside* that file; the file itself stays the size it grew to. Observed 2026-09-09: 24 GB, holding several unused duplicates of the same Supabase images across three local stacks. So reclaim's Docker category can report a win that the disk never sees. The fix is to compact the disk image after a prune — Docker Desktop does it under Settings → Resources → Advanced, and `docker run --privileged --rm docker/desktop-reclaim-space` is the scriptable equivalent — but it needs its own safety reasoning first: it takes minutes, wants the daemon idle, and README:94 already notes compaction is unreliable. **Until it is built, reclaim should at least report the gap** rather than imply the space came back.

---

Source: cleanup audit conducted in a Claude Code session, 2026-06-21. Updated 2026-08-10 after the v1.5 audit.
