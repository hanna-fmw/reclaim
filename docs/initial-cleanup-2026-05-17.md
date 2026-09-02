# Disk Cleanup Project

Ongoing project to free up and stay on top of disk space on this Mac (228 GB usable, runs tight because of dev work).

## Starting point (2026-05-17)

- Before: **2.8 GB free** (critical)
- After first cleanup pass: **33 GB free** (~14% — workable but tight)
- Healthy target: **40–50 GB free** (~18–22%)

## What we already did

- Cleared `~/.cache`, `~/Library/Caches`, `~/Library/Logs`
- `pnpm store prune` (freed 4.2 GB)
- `docker system prune -af --volumes` (freed 4.2 GB)
- Deleted `~/Documents/superwhisper` (6.6 GB — models + recordings)
- Deleted `~/Library/Application Support/Notion` (4.2 GB — re-syncs on next login)

## What we deliberately kept

- `~/.npm` (4.1 GB) — user asked to keep
- `~/.vscode` (1.6 GB) — user asked to keep
- `~/Documents/rookie` (11 GB) — active project
- `~/Library/Application Support/Google` (4.6 GB) — keeps Chrome signed in

## Ideas for next sessions

### 1. Documents audit (~40 GB)
Go through `~/Documents/*` project by project and decide:
- Keep on disk (active work)
- Archive to external SSD or cloud (finished, but want to keep)
- Delete (truly done with)

Top candidates to review:
- `learning/` — old tutorials/courses, mostly archivable
- Finished client work — archive
- Old experiments / prototypes

### 2. External SSD or cloud archive
Pick a destination once and stick with it:
- External SSD (cheapest, fastest, offline)
- iCloud Drive (already paying for it?)
- Google Drive / Dropbox
- Backblaze B2 (cheapest cloud, ~$6/TB/month)

### 3. Recurring maintenance
Set a monthly reminder to run:
- `docker system prune -af --volumes`
- `pnpm store prune`
- `npm cache clean --force` (if npm cache is back over 2 GB)
- Empty `~/.Trash`
- Empty `~/Downloads` of anything older than 60 days

### 4. The 4 old node_modules we skipped (~1.3 GB)
Easy quick win whenever:
- `learning/vite/vite-project` (174 days idle, 59 MB)
- `learning/next-16-bytegrad` (145 days, 417 MB)
- `social-media-generator` (126 days, 399 MB)
- `learning/linkedIn-content-machine` (101 days, 398 MB)

## Where we saw the most reclaim (biggest offenders)

Ranked by how much we actually freed in the first pass — these are the hotspots to watch:

| Source | Freed | Notes |
|---|---|---|
| `~/Library/Caches` | ~9.6 GB | Mostly Safari/Chrome/app caches. Regenerates, but accumulates fast. |
| `~/Documents/superwhisper` | 6.6 GB | AI models + recordings. Deleted entirely. |
| `~/.cache` | 5.9 GB | Tool caches (Playwright, Puppeteer, etc.). Regenerates. |
| `~/Library/Application Support/Notion` | 4.2 GB | Local note cache. Re-syncs on login. |
| Docker (images, volumes, build cache) | 4.2 GB | **Biggest recurring offender** — refills every few weeks of dev work. |
| `~/Library/pnpm` store | 3.6 GB cleaned | Re-fills as projects install deps. |
| `~/Library/Logs` | 774 MB | Just logs. Harmless to clear. |

**Pattern:** The hotspots are (1) dev tooling caches that auto-regenerate (Docker, pnpm, .cache), (2) app local databases that re-sync (Notion), and (3) AI/ML artifacts (superwhisper models). These are where to focus recurring maintenance.

## Notes

- Docker grows back fast — biggest single recurring offender
- `node_modules` folders compound across many projects, but each is small individually
- AI tools (superwhisper, Whisper models, local LLMs) eat huge space — be selective about what stays installed
