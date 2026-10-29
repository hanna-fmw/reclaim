# reclaim: to-dos

## Open
- [ ] 2026-10-28 (merged from docs/TODO-expand-scope.md) Remaining item-5 allowlist entries: `ms-playwright` (1.0 GB observed), `Homebrew` (615 MB observed), `pip`; each needs its own reasoning before being added; do not blanket-sweep `~/Library/Caches/*`
- [ ] 2026-10-28 (merged from docs/TODO-expand-scope.md) Docker containers: surface stopped containers as a category to unlock `prune -af` (it cannot touch images referenced by containers); it deletes container state rather than a cache, so it needs its own safety reasoning and explicit approval before anyone builds it; do not fold it into the existing Docker category
- [ ] 2026-10-28 (merged from docs/TODO-expand-scope.md) Docker's disk image may give space back late: measure disk free before and after a prune rather than trust Docker's own number; compact the disk image after a prune (Docker Desktop Settings → Resources → Advanced, or `docker run --privileged --rm docker/desktop-reclaim-space`) after working out its safety reasoning first (takes minutes, wants the daemon idle, README:94 already notes compaction is unreliable); until it is built, reclaim should at least report the gap rather than imply the space came back

## Done
- [x] 2026-10-28 (merged from docs/TODO-expand-scope.md) Item 6 (Google DriveFS recommendation): surface a recommendation to switch Drive to "Stream files only" mode for `~/Library/Application Support/Google/DriveFS` (~900 MB); don't try to clear it automatically - done 2026-10-29 by todo-sweep: moved to issue #5
