#!/bin/bash
# Disk Cleanup - scan, ask, reclaim safe space, log. macOS launchd-friendly.
#
# Categories handled (each can be picked individually in the dialog):
#   1. .next caches             - Next.js build caches in projects under the
#                                 scan roots (RECLAIM_ROOTS, default: home folders)
#   2. Installer DMGs           - leftover Screaming Frog auto-update DMGs
#   3. Docker unused images     - full prune (not just dangling) + build cache
#   4. npm cache                - ~/.npm/_cacache, rebuilds on next install
#   5. Claude vm_bundles        - sandbox VM bundles, redownloaded on demand
#   6. Dormant node_modules     - per-project picker, only projects untouched
#                                 for DORMANT_DAYS and not active work
#   7. Ballooned Turbopack cache- .next/dev/cache/turbopack on ACTIVE projects.
#                                 Next 16 keeps a persistent LSM cache that grows
#                                 with every rebuild and is never auto-compacted
#                                 away, so a long-running dev server can reach
#                                 many GB. Only offered above TURBO_MIN_KB, and
#                                 never deleted while that project's dev server
#                                 is running (the store is open).
#   8. Browser cache             - ~/Library/Caches/Google only. Cookies, logins
#                                 and passwords live in Application Support and
#                                 are NEVER touched. Requires Chrome to be quit.
#   9. pnpm store                - ~/Library/pnpm/store. Existing node_modules
#                                 are hardlinks and keep working; only the next
#                                 install re-downloads.
#  10. Stray recordings          - big, old media files sitting in Desktop /
#                                 Downloads / Documents. Report + per-file
#                                 picker, never ticked by default.
#
# Also reported (never auto-deleted): how much a reboot would likely free.
#
# ACTIVE-WORK AWARENESS still applies to .next and dormant node_modules:
#   a project is protected if a dev server is running for it, its git tree
#   is dirty, or any file was edited within PROTECT_HOURS.
#
# Cloud-only files (Google Drive 0 B placeholders) are never touched.
# Docker VOLUMES are never pruned (they can hold project databases).
# Every deleted path + its size is recorded in history.jsonl.
#
# Flags:
#   (none)      auto mode - scheduler; obeys 3-day gate, shows dialog
#   --force     skip the 3-day gate, show dialog now
#   --yes / -y  skip the gate AND the dialog; cleans the low-risk set
#               (.next, DMGs, Docker, npm cache, Claude vm_bundles)
#               Does NOT touch dormant node_modules in -y (needs approval)
#   --scan      just notify how much is cleanable, delete nothing
#   --dry       print the plan to stdout, delete nothing, no dialog
#   --notify    scheduler mode without the dialog: obeys the 3-day gate,
#               posts a notification if at least NOTIFY_MIN_KB (default 1 GB)
#               is cleanable, deletes nothing

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
set -u

STATE_DIR="$HOME/.disk-cleanup"
LOG="$STATE_DIR/history.jsonl"
LAST_RUN="$STATE_DIR/last-run"
# Where projects are looked for (.next caches, dormant node_modules).
# RECLAIM_ROOTS (space-separated) overrides; otherwise every visible folder in
# $HOME except the macOS media/system ones, so moving projects never hides them.
RECLAIM_ROOTS=${RECLAIM_ROOTS:-}
scan_roots() {
  if [ -n "$RECLAIM_ROOTS" ]; then
    printf '%s\n' $RECLAIM_ROOTS
    return
  fi
  for d in "$HOME"/*/; do
    d=${d%/}
    case "${d##*/}" in
      Library|Applications|Movies|Music|Pictures|Downloads|Public) continue ;;
    esac
    printf '%s\n' "$d"
  done
}
# project_dirs <name>: every directory called <name> under the scan roots.
# Never descends into .git, node_modules or .next, so it stays fast.
project_dirs() {
  scan_roots | while IFS= read -r r; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 8 -type d \
      \( -name .git -o -name node_modules -o -name .next \) -prune -name "$1" -print 2>/dev/null
  done
}
# Every docker call times out: a wedged daemon (common on a full disk) would
# otherwise hang the whole scan.
DOCKER_BIN=$(command -v docker 2>/dev/null || echo docker)
DOCKER_TIMEOUT=${DOCKER_TIMEOUT:-20}
# The docker CLI (Go) ignores SIGALRM, so a plain `alarm; exec` never fires:
# run it as a child and SIGKILL it when the timer runs out. Exit 124 = timed out.
docker() {
  perl -e '$t=shift; $p=fork; if(!$p){exec @ARGV; exit 127}
           $SIG{ALRM}=sub{kill "KILL",$p; waitpid($p,0); exit 124};
           alarm $t; waitpid($p,0); exit($?>>8)' "$DOCKER_TIMEOUT" "$DOCKER_BIN" "$@"
}
# Start Docker Desktop - or restart it if it is running but not answering, since
# `open -a` does nothing for a stuck app. Returns 0 once the daemon answers.
start_docker() {
  if pgrep -f com.docker.backend >/dev/null 2>&1; then
    osascript -e 'quit app "Docker"' 2>/dev/null
    for _ in $(seq 1 30); do pgrep -f com.docker.backend >/dev/null 2>&1 || break; sleep 2; done
    pkill -9 -f com.docker 2>/dev/null
  fi
  open -a Docker 2>/dev/null
  for _ in $(seq 1 60); do
    DOCKER_TIMEOUT=3 docker info >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
DOCKER_RAW="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
DMG_DIR="$HOME/.ScreamingFrogSEOSpider/AppUpdater"
NPM_CACHE="$HOME/.npm/_cacache"
CLAUDE_VM="$HOME/Library/Application Support/Claude/vm_bundles"
CHROME_CACHE="$HOME/Library/Caches/Google"
CHROME_PROFILES="$HOME/Library/Application Support/Google/Chrome"
PNPM_STORE="$HOME/Library/pnpm/store"
INTERVAL_DAYS=3
PROTECT_HOURS=24
DORMANT_DAYS=30
# A Turbopack dev cache only counts as "ballooned" above this size.
TURBO_MIN_KB=${TURBO_MIN_KB:-$((2 * 1024 * 1024))}   # 2 GB
# Stray recordings: only files at least this big and this old are listed.
MEDIA_MIN_KB=${MEDIA_MIN_KB:-$((200 * 1024))}        # 200 MB
MEDIA_AGE_DAYS=${MEDIA_AGE_DAYS:-30}
# --notify stays quiet below this much reclaimable space.
NOTIFY_MIN_KB=${NOTIFY_MIN_KB:-$((1024 * 1024))}     # 1 GB
MEDIA_DIRS="$HOME/Desktop $HOME/Downloads $HOME/Documents"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$STATE_DIR"

MODE="auto"
case "${1:-}" in
  --force)   MODE="force" ;;
  --scan)    MODE="scan" ;;
  --dry)     MODE="dry" ;;
  --yes|-y)  MODE="yes" ;;
  --notify)  MODE="notify" ;;
esac
# A human running it in a terminal always means "now".
[ -t 0 ] && [ "$MODE" = "auto" ] && MODE="force"

now=$(date +%s)

# --- 3-day gate: scheduler fires daily, we only proceed every Nth day ---
if { [ "$MODE" = "auto" ] || [ "$MODE" = "notify" ]; } && [ -f "$LAST_RUN" ]; then
  last=$(cat "$LAST_RUN" 2>/dev/null || echo 0)
  if [ $(( (now - last) / 86400 )) -lt "$INTERVAL_DAYS" ]; then
    exit 0
  fi
fi

human() { # $1 = kilobytes -> human string
  awk -v k="$1" 'BEGIN{
    if (k>=1048576) printf "%.1f GB", k/1048576;
    else if (k>=1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k;
  }'
}

RUNNING_TMP="$STATE_DIR/.running.$$"
NEXT_TMP="$STATE_DIR/.next.$$"
DORM_TMP="$STATE_DIR/.dormant.$$"
PLAN_TMP="$STATE_DIR/.plan.$$"
TURBO_TMP="$STATE_DIR/.turbo.$$"
MEDIA_TMP="$STATE_DIR/.media.$$"
cleanup_temps() { rm -f "$RUNNING_TMP" "$NEXT_TMP" "$DORM_TMP" "$PLAN_TMP" "$TURBO_TMP" "$MEDIA_TMP"; }
trap cleanup_temps EXIT

# --- detect project dirs with a live dev server ---
: > "$RUNNING_TMP"
for pid in $(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk '/node/{print $2}' | sort -u); do
  lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
done | sort -u >> "$RUNNING_TMP"

# Returns a one-word reason on stdout if the project is "active work" (and thus
# protected), or nothing if it is safe to clean.
protected_reason() { # $1 = project dir
  local p="$1" r
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    case "$p/" in "$r/"*) echo "running"; return ;; esac
    case "$r/" in "$p/"*) echo "running"; return ;; esac
  done < "$RUNNING_TMP"
  if git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git -C "$p" status --porcelain 2>/dev/null | head -1)" ]; then
      echo "dirty-git"; return
    fi
  fi
  if [ -n "$(find "$p" \( -name node_modules -o -name .next -o -name .git \) -prune -o \
              -type f -mmin "-$((PROTECT_HOURS * 60))" -print 2>/dev/null | head -1)" ]; then
    echo "recent-edit"; return
  fi
}

# Size of the persistent Turbopack dev cache inside a .next dir, in KB.
# Next 16 puts it at .next/dev/cache/turbopack; older layouts use .next/cache.
turbo_kb_of() { # $1 = .next dir
  local n="$1" t=0 p sz
  for p in "$n/dev/cache/turbopack" "$n/cache/turbopack"; do
    [ -d "$p" ] || continue
    sz=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
    t=$((t + ${sz:-0}))
  done
  echo "$t"
}

# --- collect safe .next caches (and ballooned Turbopack caches on active ones) ---
: > "$NEXT_TMP"; : > "$TURBO_TMP"
next_kb=0; next_count=0; skipped=0
prot_running=0; prot_dirty=0; prot_recent=0
turbo_kb=0; turbo_count=0; turbo_blocked=0; turbo_blocked_kb=0
while IFS= read -r d; do
  [ -z "$d" ] && continue
  reason=$(protected_reason "$(dirname "$d")")
  if [ -n "$reason" ]; then
    skipped=$((skipped + 1))
    case "$reason" in
      running)     prot_running=$((prot_running + 1)) ;;
      dirty-git)   prot_dirty=$((prot_dirty + 1)) ;;
      recent-edit) prot_recent=$((prot_recent + 1)) ;;
    esac
    # The project is active, so the whole .next stays - but its Turbopack cache
    # may still have ballooned. Offer that separately when it is big enough.
    tkb=$(turbo_kb_of "$d")
    if [ "${tkb:-0}" -ge "$TURBO_MIN_KB" ]; then
      printf '%s\t%s\t%s\n' "$tkb" "$reason" "$d" >> "$TURBO_TMP"
      if [ "$reason" = "running" ]; then
        # Never delete an open LSM store out from under a live dev server.
        turbo_blocked=$((turbo_blocked + 1)); turbo_blocked_kb=$((turbo_blocked_kb + tkb))
      else
        turbo_kb=$((turbo_kb + tkb)); turbo_count=$((turbo_count + 1))
      fi
    fi
    continue
  fi
  echo "$d" >> "$NEXT_TMP"
  sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
  next_kb=$((next_kb + ${sz:-0})); next_count=$((next_count + 1))
done <<EOF
$(project_dirs .next)
EOF

# --- collect installer DMGs ---
dmg_kb=0; dmg_count=0
if [ -d "$DMG_DIR" ]; then
  for f in "$DMG_DIR"/*.dmg; do
    [ -f "$f" ] || continue
    sz=$(du -sk "$f" 2>/dev/null | awk '{print $1}')
    dmg_kb=$((dmg_kb + ${sz:-0})); dmg_count=$((dmg_count + 1))
  done
fi

# Turn a `docker system df` size string ("1.23GB", "455.1MB") into KB.
docker_size_to_kb() {
  awk -F'\t' -v col="$1" 'BEGIN{t=0}
      { v=$col; sub(/ \(.*/,"",v); n=v+0;
        if (v ~ /GB/) n=n*1048576;
        else if (v ~ /MB/) n=n*1024;
        else if (v ~ /kB/ || v ~ /KB/) n=n;
        else if (v ~ /B/) n=n/1024;
        t+=n }
      END{ printf "%.0f", t }'
}

# Real total size Docker is holding right now, so a prune can be measured rather
# than estimated.
docker_total_kb() {
  docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null | docker_size_to_kb 2
}

# --- Docker: estimate size of unused (reclaimable) images + build cache ---
docker_note="not running"
# Docker.raw is sparse: du gives what it really occupies on disk.
docker_disk_kb=0
[ -f "$DOCKER_RAW" ] && docker_disk_kb=$(du -sk "$DOCKER_RAW" 2>/dev/null | awk '{print $1}')
if [ "${docker_disk_kb:-0}" -gt 0 ]; then
  docker_note="not answering - Docker's disk holds $(human "$docker_disk_kb"); restart Docker Desktop, then run again"
fi
docker_kb=0
docker_held=0
if docker info >/dev/null 2>&1; then
  # Docker's Reclaimable column is an UPPER BOUND: it counts an image as
  # reclaimable even when a stopped container still references it, and
  # `prune -af` will not remove those. Report it, but say so.
  docker_upper_kb=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | docker_size_to_kb 2)
  docker_held=$(docker system df --format '{{.Type}}\t{{.Active}}' 2>/dev/null \
    | awk -F'\t' 'NR==1{print ($2+0)}')
  # What `prune -af` can ACTUALLY remove right now: build cache plus images no
  # container references. Anything a container holds - running or stopped - stays.
  docker_build_kb=$(docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null \
    | awk -F'\t' '$1 ~ /Build Cache/' | docker_size_to_kb 2)
  docker_dangling_kb=$(docker image ls --filter dangling=true --format '{{.Size}}' 2>/dev/null \
    | awk '{print "x\t" $0}' | docker_size_to_kb 2)
  docker_kb=$(( ${docker_build_kb:-0} + ${docker_dangling_kb:-0} ))
  docker_note="$(human "$docker_kb") (build cache + unreferenced images; volumes left alone)"
  if [ "${docker_held:-0}" -gt 0 ]; then
    docker_note="$docker_note - $docker_held image(s) are in use by containers and stay; up to $(human "${docker_upper_kb:-0}") if you stop them first"
  fi
fi

# --- npm cache size ---
npm_kb=0
[ -d "$NPM_CACHE" ] && npm_kb=$(du -sk "$NPM_CACHE" 2>/dev/null | awk '{print $1}')

# --- Claude vm_bundles size + running check ---
claude_kb=0; claude_running=0
[ -d "$CLAUDE_VM" ] && claude_kb=$(du -sk "$CLAUDE_VM" 2>/dev/null | awk '{print $1}')
pgrep -x Claude >/dev/null 2>&1 && claude_running=1

# --- dormant node_modules: per-project list ---
: > "$DORM_TMP"
dorm_kb=0; dorm_count=0
while IFS= read -r nm; do
  [ -z "$nm" ] && continue
  proj=$(dirname "$nm")
  # skip active work
  [ -n "$(protected_reason "$proj")" ] && continue
  # skip if anything edited within DORMANT_DAYS (excluding node_modules/.next/.git)
  if [ -n "$(find "$proj" \( -name node_modules -o -name .next -o -name .git \) -prune -o \
              -type f -mtime "-$DORMANT_DAYS" -print 2>/dev/null | head -1)" ]; then
    continue
  fi
  sz=$(du -sk "$nm" 2>/dev/null | awk '{print $1}')
  [ -z "$sz" ] || [ "$sz" -lt 1024 ] && continue # skip <1 MB
  printf '%s\t%s\n' "$sz" "$nm" >> "$DORM_TMP"
  dorm_kb=$((dorm_kb + sz)); dorm_count=$((dorm_count + 1))
done <<EOF
$(project_dirs node_modules)
EOF
# sort biggest first for the per-project picker
if [ -s "$DORM_TMP" ]; then
  sort -rn "$DORM_TMP" -o "$DORM_TMP"
fi
[ -s "$TURBO_TMP" ] && sort -rn "$TURBO_TMP" -o "$TURBO_TMP"

# --- Chrome cache (safe) vs Chrome profiles (destructive - never touched) ---
chrome_kb=0; chrome_running=0; chrome_profile_kb=0
[ -d "$CHROME_CACHE" ] && chrome_kb=$(du -sk "$CHROME_CACHE" 2>/dev/null | awk '{print $1}')
[ -d "$CHROME_PROFILES" ] && chrome_profile_kb=$(du -sk "$CHROME_PROFILES" 2>/dev/null | awk '{print $1}')
pgrep -x "Google Chrome" >/dev/null 2>&1 && chrome_running=1

# --- pnpm store ---
pnpm_kb=0
[ -d "$PNPM_STORE" ] && pnpm_kb=$(du -sk "$PNPM_STORE" 2>/dev/null | awk '{print $1}')

# --- stray recordings: big, old media sitting in Desktop / Downloads / Documents ---
: > "$MEDIA_TMP"
media_kb=0; media_count=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  sz=$(du -sk "$f" 2>/dev/null | awk '{print $1}')
  # 0 KB means a cloud-only placeholder - leave those alone.
  [ -z "$sz" ] || [ "$sz" -lt "$MEDIA_MIN_KB" ] && continue
  printf '%s\t%s\n' "$sz" "$f" >> "$MEDIA_TMP"
  media_kb=$((media_kb + sz)); media_count=$((media_count + 1))
done <<EOF
$(find $MEDIA_DIRS -maxdepth 3 -type f \
    \( -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.mp3' \
       -o -iname '*.wav' -o -iname '*.mkv' -o -iname '*.m4v' \) \
    -mtime "+$MEDIA_AGE_DAYS" 2>/dev/null)
EOF
[ -s "$MEDIA_TMP" ] && sort -rn "$MEDIA_TMP" -o "$MEDIA_TMP"

# --- what a reboot would likely free (reported only, never deleted here) ---
# /private/var/folders is the per-user temp + cache area macOS rebuilds on boot;
# local APFS snapshots are freed by the OS when it needs the space.
reboot_kb=$(du -sk /private/var/folders 2>/dev/null | awk '{print $1}')
reboot_kb=${reboot_kb:-0}
snap_count=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple' || true)
snap_count=${snap_count:-0}

est_kb=$((next_kb + dmg_kb + docker_kb + npm_kb + claude_kb + dorm_kb + turbo_kb + chrome_kb + pnpm_kb))
free_now=$(df -k / | awk 'NR==2{print $4}')

# --- build the human-readable plan (also written to a file for Ask Claude) ---
build_plan() {
  cat <<PLAN
Disk free now: $(human "$free_now")
Total reclaimable (safe set, before any choices): ~$(human "$est_kb")

Categories:
  1. .next caches             $(human "$next_kb")  ($next_count projects)
     Risk: none. Rebuilt on next \`pnpm dev\` / \`next build\`.

  2. Installer DMGs           $(human "$dmg_kb")  ($dmg_count files)
     Risk: none. Old Screaming Frog auto-update installers; app already installed.

  3. Docker unused images     $docker_note
     Risk: low. Full prune (not just dangling). Next \`docker compose up\` redownloads
     missing images. Volumes are NEVER pruned.

  4. npm cache                $(human "$npm_kb")
     Risk: none. Pure download cache; rebuilds on next \`npm install\` (first install
     after cleanup is slightly slower).

  5. Claude vm_bundles        $(human "$claude_kb")$([ "$claude_running" = "1" ] && echo "  (Claude.app running -> SKIPPED)")
     Risk: low. Sandbox VM bundles for Claude Code's Bash sandbox; redownloaded
     on demand. Conversation history lives elsewhere and is not touched.

  6. Dormant node_modules     $(human "$dorm_kb")  ($dorm_count projects, untouched ${DORMANT_DAYS}d+)
     Risk: low. Reinstall with \`pnpm install\` / \`npm install\` if you come back
     to the project. Only projects with no edits for ${DORMANT_DAYS}+ days and no
     active dev server / dirty git are listed.

  7. Ballooned Turbopack cache $(human "$turbo_kb")  ($turbo_count project(s) over $(human "$TURBO_MIN_KB"))
     Risk: none. Next 16 keeps a persistent Turbopack cache under .next/dev that
     grows with every rebuild and is never compacted away, so a dev server left
     running for weeks can reach many GB. Deleting it costs one slow rebuild.$([ "$turbo_blocked" -gt 0 ] && printf '\n     BLOCKED: %s more (%s) have a dev server running - stop it to reclaim those.' "$turbo_blocked" "$(human "$turbo_blocked_kb")")

  8. Chrome cache             $(human "$chrome_kb")$([ "$chrome_running" = "1" ] && echo "  (Chrome running -> SKIPPED)")
     Risk: none, but Chrome must be quit first. This is ~/Library/Caches/Google
     only. Cookies, logins and passwords live in Application Support/Google
     ($(human "$chrome_profile_kb")) and are NEVER touched - you stay signed in.

  9. pnpm store               $(human "$pnpm_kb")
     Risk: none. Existing node_modules are hardlinks and keep working; only the
     next \`pnpm install\` re-downloads instead of linking.

 10. Stray recordings         $(human "$media_kb")  ($media_count files, ${MEDIA_AGE_DAYS}d+ old, over $(human "$MEDIA_MIN_KB"))
     Risk: YOUR CALL - these are your own files, not caches. Never ticked by
     default; opens a per-file picker. Not counted in the total above.

  Reboot would likely free  up to $(human "$reboot_kb") of temp/cache in /private/var/folders$([ "$snap_count" -gt 0 ] && printf ', plus %s local APFS snapshot(s) the OS frees on demand' "$snap_count")
     Nothing here is deleted by reclaim - just restart the Mac.
PLAN
  if [ "$skipped" -gt 0 ]; then
    echo ""
    echo "$skipped project(s) protected from .next cleanup (active work):"
    [ "$prot_running" -gt 0 ] && echo "  - $prot_running with a running dev server"
    [ "$prot_dirty"   -gt 0 ] && echo "  - $prot_dirty with uncommitted git changes"
    [ "$prot_recent"  -gt 0 ] && echo "  - $prot_recent edited in the last ${PROTECT_HOURS}h"
  fi
}
build_plan > "$PLAN_TMP"

# --- scan: just report, never delete ---
if [ "$MODE" = "scan" ]; then
  osascript -e "display notification \"~$(human "$est_kb") cleanable across 6 categories. Run cleanup to free it.\" with title \"Disk Cleanup\"" 2>/dev/null
  exit 0
fi

# --- notify: quiet scheduler reminder, never delete ---
if [ "$MODE" = "notify" ]; then
  echo "$now" > "$LAST_RUN"
  if [ "$est_kb" -ge "$NOTIFY_MIN_KB" ]; then
    osascript -e "display notification \"~$(human "$est_kb") cleanable. Run reclaim in a terminal, or ask Claude.\" with title \"Disk Cleanup\"" 2>/dev/null
    printf '{"ts":"%s","action":"notify","reclaimable_kb":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$est_kb" >> "$LOG"
  fi
  exit 0
fi

# --- dry: print plan, never delete ---
if [ "$MODE" = "dry" ]; then
  cat "$PLAN_TMP"
  echo ""
  echo "--- .next dirs that would be removed: ---"
  cat "$NEXT_TMP" 2>/dev/null
  echo "--- dormant node_modules (size  path): ---"
  awk -F'\t' '{printf "  %s  %s\n", $1, $2}' "$DORM_TMP" 2>/dev/null
  echo "--- ballooned Turbopack caches (size  blocker  path): ---"
  awk -F'\t' '{printf "  %s  %-11s  %s\n", $1, $2, $3}' "$TURBO_TMP" 2>/dev/null
  echo "--- stray recordings (size  path): ---"
  awk -F'\t' '{printf "  %s  %s\n", $1, $2}' "$MEDIA_TMP" 2>/dev/null
  exit 0
fi

# --- Ask Claude: open Terminal in the repo with the plan + claude ---
open_ask_claude() {
  local plan_copy="$STATE_DIR/last-plan.txt"
  cp "$PLAN_TMP" "$plan_copy"
  /usr/bin/osascript <<OSA 2>/dev/null
tell application "Terminal"
  activate
  do script "cd '$REPO_DIR' && clear && echo 'Reclaim is about to run with this plan:' && echo '' && cat '$plan_copy' && echo '' && echo '--- Claude is starting in the reclaim repo. Ask anything, then re-run \`reclaim clean\` when ready. ---' && echo '' && claude"
end tell
OSA
}

# Proceeding (or asking) for real - record run time so the gate honours interval.
echo "$now" > "$LAST_RUN"

# --- decide what to clean ---
do_next=0; do_dmg=0; do_docker=0; do_npm=0; do_claudevm=0; do_dorm=0
do_turbo=0; do_chrome=0; do_pnpm=0; do_media=0
dorm_selected_file=""; media_selected_file=""
action="skip"

if [ "$MODE" = "yes" ]; then
  # Headless safe set. Skip dormant node_modules (needs per-project approval),
  # Turbopack caches (active projects - deserve a look), Chrome cache (needs
  # Chrome quit) and recordings (personal files). Claude vm_bundles only if
  # Claude.app is not running.
  do_next=1; do_dmg=1; do_docker=1; do_npm=1; do_pnpm=1
  [ "$claude_running" = "0" ] && do_claudevm=1
  action="clean"
else
  # Interactive: main dialog (Cancel / Ask Claude / Continue) -> picker.
  # Compact summary only - full details live in the picker and last-plan.txt.
  # Docker holds its whole VM in one big file, so an unreachable daemon means we
  # cannot see (or reclaim) any of it. Offer to start it and rescan, once.
  if ! docker info >/dev/null 2>&1 && [ "${RECLAIM_DOCKER_TRIED:-0}" = "0" ]; then
    dchoice=$(osascript -e 'display dialog "Docker Desktop is not running (or is stuck), so reclaim cannot see how much of its images and build cache are reclaimable (this is often the single biggest item).

Start Docker Desktop and rescan?" buttons {"Skip Docker", "Start Docker & rescan"} default button "Start Docker & rescan" with title "Disk Cleanup" with icon note giving up after 120' 2>/dev/null)
    case "$dchoice" in
      *"Start Docker & rescan"*)
        if start_docker; then
          RECLAIM_DOCKER_TRIED=1 exec "$0" --force
        else
          osascript -e 'display notification "Docker did not come up in time - continuing without it." with title "Disk Cleanup"' 2>/dev/null
        fi
        ;;
    esac
  fi

  docker_short="not running"
  [ "$docker_kb" -gt 0 ] && docker_short="$(human "$docker_kb")"
  summary=$(cat <<SUM
Free now: $(human "$free_now")   -   reclaimable: ~$(human "$est_kb")

1. .next caches            $(human "$next_kb")  ($next_count projects)
2. Installer DMGs          $(human "$dmg_kb")  ($dmg_count files)
3. Docker unused images    $docker_short
4. npm cache               $(human "$npm_kb")
5. Claude vm_bundles       $(human "$claude_kb")$([ "$claude_running" = "1" ] && echo " (Claude running, skipped)")
6. Dormant node_modules    $(human "$dorm_kb")  ($dorm_count projects, ${DORMANT_DAYS}d+ idle)
7. Turbopack cache bloat   $(human "$turbo_kb")  ($turbo_count project(s))$([ "$turbo_blocked" -gt 0 ] && echo " + $(human "$turbo_blocked_kb") blocked by a running dev server")
8. Chrome cache            $(human "$chrome_kb")$([ "$chrome_running" = "1" ] && echo " (quit Chrome first)")
9. pnpm store              $(human "$pnpm_kb")
10. Stray recordings       $(human "$media_kb")  ($media_count files - your own files, off by default)

Reboot would free up to $(human "$reboot_kb") more.
SUM
)
  [ "$skipped" -gt 0 ] && summary="$summary
$(printf '\n%s project(s) protected (dev server / dirty git / recent edits).' "$skipped")"
  summary="$summary

Continue opens a picker - nothing is deleted until you select and confirm there."
  plan_for_dialog=$(printf '%s' "$summary" | sed 's/"/\\"/g')
  while true; do
    choice=$(osascript -e "display dialog \"$plan_for_dialog\" buttons {\"Cancel\", \"Ask Claude\", \"Continue\"} default button \"Continue\" with title \"Disk Cleanup\" with icon note giving up after 300" 2>/dev/null)
    case "$choice" in
      *"Ask Claude"*)
        open_ask_claude
        # Re-show plan after Claude opens, so user can decide to continue or cancel.
        continue
        ;;
      *"Continue"*)
        break
        ;;
      *)
        # Cancel / timeout / closed
        printf '{"ts":"%s","action":"skip","reclaimable_kb":%s}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$est_kb" >> "$LOG"
        exit 0
        ;;
    esac
  done

  # Build the picker labels. Each line: short tag, size, risk note.
  l1=".next caches             -  $(human "$next_kb")  ($next_count projects)   risk: none, rebuilds on next dev"
  l2="Installer DMGs           -  $(human "$dmg_kb")  ($dmg_count files)   risk: none, old installers"
  l3="Docker unused images     -  $docker_note   risk: low, re-pulled on next docker up"
  l4="npm cache                -  $(human "$npm_kb")   risk: none, rebuilds on next npm install"
  if [ "$claude_running" = "1" ]; then
    l5="Claude vm_bundles        -  $(human "$claude_kb")   SKIPPED: Claude.app is running"
  else
    l5="Claude vm_bundles        -  $(human "$claude_kb")   risk: low, redownloaded on demand"
  fi
  l6="Dormant node_modules     -  $(human "$dorm_kb")  ($dorm_count projects ${DORMANT_DAYS}d+ idle)   risk: low, opens per-project picker"
  if [ "$turbo_count" -gt 0 ]; then
    l7="Turbopack cache bloat    -  $(human "$turbo_kb")  ($turbo_count project(s))   risk: none, Next rebuilds it (one slow start)"
  elif [ "$turbo_blocked" -gt 0 ]; then
    l7="Turbopack cache bloat    -  $(human "$turbo_blocked_kb")   BLOCKED: stop that project's dev server, then rerun"
  else
    l7="Turbopack cache bloat    -  0 KB   nothing over $(human "$TURBO_MIN_KB")"
  fi
  if [ "$chrome_running" = "1" ]; then
    l8="Chrome cache             -  $(human "$chrome_kb")   SKIPPED: quit Chrome first (logins/passwords are never touched)"
  else
    l8="Chrome cache             -  $(human "$chrome_kb")   risk: none, cache only - you stay signed in everywhere"
  fi
  l9="pnpm store               -  $(human "$pnpm_kb")   risk: none, existing node_modules are hardlinks and keep working"
  l10="Stray recordings         -  $(human "$media_kb")  ($media_count files)   YOUR FILES, not cache - opens a per-file picker"

  # Default-on: low/none risk items. Off by default: Claude vm_bundles (if
  # running), dormant node_modules, Chrome (if running), and always recordings.
  default_items="\"$l1\", \"$l2\", \"$l3\", \"$l4\""
  [ "$claude_running" = "0" ] && [ "$claude_kb" -gt 0 ] && default_items="$default_items, \"$l5\""
  [ "$turbo_count" -gt 0 ] && default_items="$default_items, \"$l7\""
  [ "$chrome_running" = "0" ] && [ "$chrome_kb" -gt 0 ] && default_items="$default_items, \"$l8\""
  [ "$pnpm_kb" -gt 0 ] && default_items="$default_items, \"$l9\""

  all_items="\"$l1\", \"$l2\", \"$l3\", \"$l4\", \"$l5\", \"$l6\", \"$l7\", \"$l8\", \"$l9\", \"$l10\""

  picked=$(osascript 2>/dev/null \
    -e "set theList to {$all_items}" \
    -e "set theDefaults to {$default_items}" \
    -e 'set chosen to choose from list theList with prompt "Select what to clean - Cmd-click or Shift-click to pick more than one." default items theDefaults with multiple selections allowed' \
    -e 'if chosen is false then return "CANCEL"' \
    -e 'set text item delimiters of AppleScript to "||"' \
    -e 'return chosen as string')

  if [ "$picked" = "CANCEL" ] || [ -z "$picked" ]; then
    printf '{"ts":"%s","action":"skip","reclaimable_kb":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$est_kb" >> "$LOG"
    exit 0
  fi

  case "$picked" in *".next caches"*)         do_next=1 ;; esac
  case "$picked" in *"Installer DMGs"*)       do_dmg=1 ;; esac
  case "$picked" in *"Docker unused images"*)
    if docker info >/dev/null 2>&1; then
      do_docker=1
    else
      # Picked it, but the daemon is down - say so instead of silently skipping.
      dchoice=$(osascript -e 'display dialog "You picked Docker, but Docker Desktop is not running or is stuck - reclaim cannot prune anything while the daemon is down.

Start it now and prune?" buttons {"Skip Docker", "Start Docker & prune"} default button "Start Docker & prune" with title "Disk Cleanup" with icon caution giving up after 120' 2>/dev/null)
      case "$dchoice" in
        *"Start Docker & prune"*)
          if start_docker; then
            do_docker=1
          else
            osascript -e 'display notification "Docker did not come up in time - skipped." with title "Disk Cleanup"' 2>/dev/null
          fi
          ;;
        *)
          osascript -e 'display notification "Docker skipped - daemon not running." with title "Disk Cleanup"' 2>/dev/null
          ;;
      esac
    fi
    ;;
  esac
  case "$picked" in *"npm cache"*)            do_npm=1 ;; esac
  case "$picked" in *"Claude vm_bundles"*)
    if [ "$claude_running" = "1" ]; then
      osascript -e 'display notification "Claude.app is running - vm_bundles left alone." with title "Disk Cleanup"' 2>/dev/null
    else
      do_claudevm=1
    fi
    ;;
  esac
  case "$picked" in *"Dormant node_modules"*)
    if [ "$dorm_count" -gt 0 ]; then
      # Per-project picker. Labels: "<size>  <project-path>"
      dorm_list=""
      while IFS=$'\t' read -r sz path; do
        proj=${path%/node_modules}
        # shorten $HOME to ~
        short=${proj/#$HOME/~}
        lbl="$(human "$sz")  -  $short"
        esc=${lbl//\"/\\\"}
        dorm_list="$dorm_list\"$esc\", "
      done < "$DORM_TMP"
      dorm_list="${dorm_list%, }"

      dorm_picked=$(osascript 2>/dev/null \
        -e "set theList to {$dorm_list}" \
        -e 'set chosen to choose from list theList with prompt "Which dormant node_modules to delete? No edits for '"$DORMANT_DAYS"'+ days. Cmd-click for more than one." with multiple selections allowed' \
        -e 'if chosen is false then return "CANCEL"' \
        -e 'set text item delimiters of AppleScript to "||"' \
        -e 'return chosen as string')

      if [ "$dorm_picked" != "CANCEL" ] && [ -n "$dorm_picked" ]; then
        dorm_selected_file="$STATE_DIR/.dorm-selected.$$"
        : > "$dorm_selected_file"
        # match selected labels back to paths
        printf '%s\n' "$dorm_picked" | awk -F'\\|\\|' '{for(i=1;i<=NF;i++)print $i}' \
        | while IFS= read -r label; do
            short_path=${label#*-  }
            full_path="${short_path/#\~/$HOME}"
            grep -F "	${full_path}/node_modules" "$DORM_TMP" \
              | awk -F'\t' '{print $2}' >> "$dorm_selected_file"
          done
        if [ -s "$dorm_selected_file" ]; then
          do_dorm=1
        fi
      fi
    fi
    ;;
  esac

  case "$picked" in *"Turbopack cache bloat"*)
    if [ "$turbo_count" -gt 0 ]; then
      do_turbo=1
    elif [ "$turbo_blocked" -gt 0 ]; then
      osascript -e 'display notification "Turbopack caches skipped - a dev server is still running for those projects." with title "Disk Cleanup"' 2>/dev/null
    fi
    ;;
  esac

  case "$picked" in *"Chrome cache"*)
    if [ "$chrome_running" = "1" ]; then
      osascript -e 'display notification "Chrome is running - cache left alone. Quit Chrome and rerun." with title "Disk Cleanup"' 2>/dev/null
    else
      do_chrome=1
    fi
    ;;
  esac

  case "$picked" in *"pnpm store"*) [ "$pnpm_kb" -gt 0 ] && do_pnpm=1 ;; esac

  case "$picked" in *"Stray recordings"*)
    if [ "$media_count" -gt 0 ]; then
      # Per-file picker. These are personal files, so nothing is pre-ticked.
      media_list=""
      while IFS=$'\t' read -r sz path; do
        short=${path/#$HOME/\~}
        lbl="$(human "$sz")  -  $short"
        esc=${lbl//\"/\\\"}
        media_list="$media_list\"$esc\", "
      done < "$MEDIA_TMP"
      media_list="${media_list%, }"

      media_picked=$(osascript 2>/dev/null \
        -e "set theList to {$media_list}" \
        -e 'set chosen to choose from list theList with prompt "Which recordings to DELETE PERMANENTLY? Your own files, not caches - nothing preselected. Cmd-click for more than one." with multiple selections allowed' \
        -e 'if chosen is false then return "CANCEL"' \
        -e 'set text item delimiters of AppleScript to "||"' \
        -e 'return chosen as string')

      if [ "$media_picked" != "CANCEL" ] && [ -n "$media_picked" ]; then
        media_selected_file="$STATE_DIR/.media-selected.$$"
        : > "$media_selected_file"
        printf '%s\n' "$media_picked" | awk -F'\\|\\|' '{for(i=1;i<=NF;i++)print $i}' \
        | while IFS= read -r label; do
            short_path=${label#*-  }
            full_path="${short_path/#\~/$HOME}"
            printf '%s\n' "$full_path" >> "$media_selected_file"
          done
        [ -s "$media_selected_file" ] && do_media=1
      fi
    fi
    ;;
  esac

  total_actions=$((do_next + do_dmg + do_docker + do_npm + do_claudevm + do_dorm \
                   + do_turbo + do_chrome + do_pnpm + do_media))
  if [ "$total_actions" -gt 0 ]; then
    action="clean"
  fi
fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

if [ "$action" = "clean" ]; then
  before=$(df -k / | awk 'NR==2{print $4}')
  removed_json=""

  if [ "$do_next" = "1" ] && [ -s "$NEXT_TMP" ]; then
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
      rm -rf "$d"
      removed_json="$removed_json{\"path\":\"$(json_escape "$d")\",\"kb\":${kb:-0}},"
    done < "$NEXT_TMP"
  fi

  if [ "$do_dmg" = "1" ] && [ -d "$DMG_DIR" ]; then
    for f in "$DMG_DIR"/*.dmg; do
      [ -f "$f" ] || continue
      kb=$(du -sk "$f" 2>/dev/null | awk '{print $1}')
      rm -f "$f"
      removed_json="$removed_json{\"path\":\"$(json_escape "$f")\",\"kb\":${kb:-0}},"
    done
  fi

  if [ "$do_docker" = "1" ] && docker info >/dev/null 2>&1; then
    # Log what actually went, not the pre-run estimate. Docker's "Reclaimable"
    # column counts images that a stopped container still references, so it
    # routinely overstates - measure real total size before and after instead.
    dk_before=$(docker_total_kb)
    DOCKER_TIMEOUT=900 docker system prune -af >/dev/null 2>&1   # a prune can take minutes
    dk_after=$(docker_total_kb)
    dk_freed=$(( ${dk_before:-0} - ${dk_after:-0} )); [ "$dk_freed" -lt 0 ] && dk_freed=0
    removed_json="$removed_json{\"path\":\"docker:system-prune-af\",\"kb\":${dk_freed},\"estimated_kb\":${docker_kb:-0}},"
  fi

  if [ "$do_npm" = "1" ] && [ -d "$NPM_CACHE" ]; then
    kb=$(du -sk "$NPM_CACHE" 2>/dev/null | awk '{print $1}')
    rm -rf "$NPM_CACHE"
    removed_json="$removed_json{\"path\":\"$(json_escape "$NPM_CACHE")\",\"kb\":${kb:-0}},"
  fi

  if [ "$do_claudevm" = "1" ] && [ -d "$CLAUDE_VM" ]; then
    kb=$(du -sk "$CLAUDE_VM" 2>/dev/null | awk '{print $1}')
    rm -rf "$CLAUDE_VM"
    removed_json="$removed_json{\"path\":\"$(json_escape "$CLAUDE_VM")\",\"kb\":${kb:-0}},"
  fi

  if [ "$do_dorm" = "1" ] && [ -n "$dorm_selected_file" ] && [ -s "$dorm_selected_file" ]; then
    while IFS= read -r nm; do
      [ -z "$nm" ] && continue
      kb=$(du -sk "$nm" 2>/dev/null | awk '{print $1}')
      rm -rf "$nm"
      removed_json="$removed_json{\"path\":\"$(json_escape "$nm")\",\"kb\":${kb:-0}},"
    done < "$dorm_selected_file"
    rm -f "$dorm_selected_file"
  fi

  # Turbopack: delete only the cache dir, keep the rest of .next. Re-check that
  # no dev server appeared for that project since the scan.
  if [ "$do_turbo" = "1" ] && [ -s "$TURBO_TMP" ]; then
    while IFS=$'\t' read -r sz reason nextdir; do
      [ -z "$nextdir" ] && continue
      [ "$reason" = "running" ] && continue
      [ "$(protected_reason "$(dirname "$nextdir")")" = "running" ] && continue
      for p in "$nextdir/dev/cache/turbopack" "$nextdir/cache/turbopack"; do
        [ -d "$p" ] || continue
        kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
        rm -rf "$p"
        removed_json="$removed_json{\"path\":\"$(json_escape "$p")\",\"kb\":${kb:-0}},"
      done
    done < "$TURBO_TMP"
  fi

  # Chrome: cache only, and only while Chrome is not running.
  if [ "$do_chrome" = "1" ] && [ -d "$CHROME_CACHE" ] && ! pgrep -x "Google Chrome" >/dev/null 2>&1; then
    kb=$(du -sk "$CHROME_CACHE" 2>/dev/null | awk '{print $1}')
    rm -rf "$CHROME_CACHE"
    removed_json="$removed_json{\"path\":\"$(json_escape "$CHROME_CACHE")\",\"kb\":${kb:-0}},"
  fi

  # pnpm: use the built-in prune so only unreferenced packages go.
  if [ "$do_pnpm" = "1" ] && command -v pnpm >/dev/null 2>&1; then
    kb_before=$(du -sk "$PNPM_STORE" 2>/dev/null | awk '{print $1}')
    pnpm store prune >/dev/null 2>&1
    kb_after=$(du -sk "$PNPM_STORE" 2>/dev/null | awk '{print $1}')
    removed_json="$removed_json{\"path\":\"pnpm:store-prune\",\"kb\":$(( ${kb_before:-0} - ${kb_after:-0} ))},"
  fi

  if [ "$do_media" = "1" ] && [ -n "$media_selected_file" ] && [ -s "$media_selected_file" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] || [ ! -f "$f" ] && continue
      kb=$(du -sk "$f" 2>/dev/null | awk '{print $1}')
      rm -f "$f"
      removed_json="$removed_json{\"path\":\"$(json_escape "$f")\",\"kb\":${kb:-0}},"
    done < "$media_selected_file"
    rm -f "$media_selected_file"
  fi

  removed_json="[${removed_json%,}]"
  after=$(df -k / | awk 'NR==2{print $4}')
  freed=$((after - before)); [ "$freed" -lt 0 ] && freed=0
  printf '{"ts":"%s","action":"clean","freed_kb":%s,"cleaned":{"next":%s,"dmg":%s,"docker":%s,"npm":%s,"claudevm":%s,"dormant":%s,"turbopack":%s,"chrome":%s,"pnpm":%s,"media":%s},"next_dirs":%s,"dmgs":%s,"dormant_count":%s,"turbo_count":%s,"turbo_blocked":%s,"protected":{"running":%s,"dirty":%s,"recent":%s},"free_after_kb":%s,"removed":%s}\n' \
    "$ts" "$freed" "$do_next" "$do_dmg" "$do_docker" "$do_npm" "$do_claudevm" "$do_dorm" \
    "$do_turbo" "$do_chrome" "$do_pnpm" "$do_media" \
    "$next_count" "$dmg_count" "$dorm_count" "$turbo_count" "$turbo_blocked" \
    "$prot_running" "$prot_dirty" "$prot_recent" "$after" "$removed_json" >> "$LOG"
  osascript -e "display notification \"Freed $(human "$freed") - $(human "$after") free now.\" with title \"Disk Cleanup\"" 2>/dev/null
else
  printf '{"ts":"%s","action":"skip","reclaimable_kb":%s,"protected":{"running":%s,"dirty":%s,"recent":%s}}\n' \
    "$ts" "$est_kb" "$prot_running" "$prot_dirty" "$prot_recent" >> "$LOG"
fi
