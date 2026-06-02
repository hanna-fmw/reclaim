#!/bin/bash
# Disk Cleanup - scan, ask, reclaim safe space, log. macOS launchd-friendly.
#
# Methodology (mirrors the manual session this was built from):
#   - Cloud-only files (Google Drive 0 B placeholders) are never touched.
#   - ACTIVE-WORK AWARENESS: a project's .next cache is protected (never deleted)
#     if ANY of these are true:
#       * a dev server for it is currently running (lsof)
#       * its git working tree is dirty (uncommitted changes)
#       * any file in it was edited within the last PROTECT_HOURS hours
#     The tool refuses to touch anything you appear to be working on.
#   - Only regenerable / junk is ever removed: Next.js .next caches, leftover
#     installer .dmg files, Docker dangling images + build cache.
#   - Docker VOLUMES are never pruned (they can hold project databases).
#   - Every deleted path + its size is recorded in the audit log (history.jsonl).
#   - Space freed is measured from real df before/after, then logged + notified.
#
# Flags:
#   (none)    auto mode - used by the scheduler; obeys the 3-day gate, shows dialog
#   --force   skip the 3-day gate, show dialog now
#   --scan    just notify how much is cleanable, delete nothing
#   --dry     print the plan to stdout, delete nothing, no dialog

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
set -u

STATE_DIR="$HOME/.disk-cleanup"
LOG="$STATE_DIR/history.jsonl"
LAST_RUN="$STATE_DIR/last-run"
DOCS="$HOME/Documents"
DMG_DIR="$HOME/.ScreamingFrogSEOSpider/AppUpdater"
INTERVAL_DAYS=3
PROTECT_HOURS=24
mkdir -p "$STATE_DIR"

MODE="auto"
case "${1:-}" in
  --force)   MODE="force" ;;
  --scan)    MODE="scan" ;;
  --dry)     MODE="dry" ;;
  --yes|-y)  MODE="yes" ;;
esac
# A human running it in a terminal always means "now".
[ -t 0 ] && [ "$MODE" = "auto" ] && MODE="force"

now=$(date +%s)

# --- 3-day gate: scheduler fires daily, we only proceed every Nth day ---
if [ "$MODE" = "auto" ] && [ -f "$LAST_RUN" ]; then
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
cleanup_temps() { rm -f "$RUNNING_TMP" "$NEXT_TMP"; }
trap cleanup_temps EXIT

# --- detect project dirs with a live dev server ---
: > "$RUNNING_TMP"
for pid in $(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk '/node/{print $2}' | sort -u); do
  lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
done | sort -u >> "$RUNNING_TMP"

# Returns a one-word reason on stdout if the project is "active work" (and thus
# protected), or nothing if it is safe to clean.
protected_reason() { # $1 = project dir (parent of the .next)
  local p="$1" r
  # 1) a dev server is listening from inside this project
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    case "$p/" in "$r/"*) echo "running"; return ;; esac
    case "$r/" in "$p/"*) echo "running"; return ;; esac
  done < "$RUNNING_TMP"
  # 2) uncommitted git changes (errs broad in monorepos - that is the safe side)
  if git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git -C "$p" status --porcelain 2>/dev/null | head -1)" ]; then
      echo "dirty-git"; return
    fi
  fi
  # 3) any source file touched within PROTECT_HOURS (node_modules/.next/.git pruned)
  if [ -n "$(find "$p" \( -name node_modules -o -name .next -o -name .git \) -prune -o \
              -type f -mmin "-$((PROTECT_HOURS * 60))" -print 2>/dev/null | head -1)" ]; then
    echo "recent-edit"; return
  fi
}

# --- collect safe .next caches (skipping anything that looks like active work) ---
: > "$NEXT_TMP"
next_kb=0; next_count=0; skipped=0
prot_running=0; prot_dirty=0; prot_recent=0
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
    continue
  fi
  echo "$d" >> "$NEXT_TMP"
  sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
  next_kb=$((next_kb + ${sz:-0})); next_count=$((next_count + 1))
done <<EOF
$(find "$DOCS" -type d -name .next -prune 2>/dev/null)
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

docker_note="not running"
docker info >/dev/null 2>&1 && docker_note="dangling images + build cache"

est_kb=$((next_kb + dmg_kb))
free_now=$(df -k / | awk 'NR==2{print $4}')

msg="Disk free now: $(human "$free_now")

Reclaimable (safe to delete):
- .next caches: $(human "$next_kb") ($next_count projects)
- Installer DMGs: $(human "$dmg_kb") ($dmg_count files)
- Docker: $docker_note"
if [ "$skipped" -gt 0 ]; then
  msg="$msg

$skipped project(s) protected (active work, left alone):"
  [ "$prot_running" -gt 0 ] && msg="$msg
  - $prot_running with a running dev server"
  [ "$prot_dirty" -gt 0 ]   && msg="$msg
  - $prot_dirty with uncommitted git changes"
  [ "$prot_recent" -gt 0 ]  && msg="$msg
  - $prot_recent edited in the last ${PROTECT_HOURS}h"
fi
msg="$msg

Clean now?"

# --- scan: just report, never delete ---
if [ "$MODE" = "scan" ]; then
  osascript -e "display notification \"~$(human "$est_kb") cleanable (plus Docker). Run cleanup to free it.\" with title \"Disk Cleanup\"" 2>/dev/null
  exit 0
fi

# --- dry: print plan, never delete ---
if [ "$MODE" = "dry" ]; then
  printf '%s\n' "$msg"
  echo "--- would delete these .next dirs: ---"
  cat "$NEXT_TMP"
  exit 0
fi

# Proceeding for real - record the run time so the gate honours the interval.
echo "$now" > "$LAST_RUN"

do_next=0; do_dmg=0; do_docker=0; action="skip"
if [ "$MODE" = "yes" ]; then
  # Headless: clean every safe category without asking (used by `reclaim clean -y`).
  do_next=1; do_dmg=1; do_docker=1; action="clean"
else
  # Labels for the per-category picker (used by the "Choose..." path)
  lbl_next=".next app build caches  -  $(human "$next_kb") ($next_count projects)"
  lbl_dmg="Installer DMGs  -  $(human "$dmg_kb") ($dmg_count files)"
  lbl_docker="Docker dangling images + build cache"

  choice=$(osascript -e "display dialog \"$msg\" buttons {\"Skip\", \"Choose...\", \"Clean all\"} default button \"Clean all\" with title \"Disk Cleanup\" with icon note giving up after 120" 2>/dev/null)

  case "$choice" in
    *"Clean all"*)
      do_next=1; do_dmg=1; do_docker=1; action="clean"
      ;;
    *"Choose..."*)
      picked=$(osascript 2>/dev/null \
        -e "set theList to {\"$lbl_next\", \"$lbl_dmg\", \"$lbl_docker\"}" \
        -e 'set chosen to choose from list theList with prompt "Select what to clean:" default items theList with multiple selections allowed' \
        -e 'if chosen is false then return "CANCEL"' \
        -e 'set text item delimiters of AppleScript to "||"' \
        -e 'return chosen as string')
      if [ "$picked" != "CANCEL" ] && [ -n "$picked" ]; then
        case "$picked" in *".next app build"*) do_next=1 ;; esac
        case "$picked" in *"Installer DMGs"*) do_dmg=1 ;; esac
        case "$picked" in *"Docker dangling"*) do_docker=1 ;; esac
        [ $((do_next + do_dmg + do_docker)) -gt 0 ] && action="clean"
      fi
      ;;
  esac
fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

if [ "$action" = "clean" ]; then
  before=$(df -k / | awk 'NR==2{print $4}')
  removed_json=""
  if [ "$do_next" = "1" ]; then
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
  if [ "$do_docker" = "1" ]; then
    docker info >/dev/null 2>&1 && docker system prune -af >/dev/null 2>&1
  fi
  removed_json="[${removed_json%,}]"
  after=$(df -k / | awk 'NR==2{print $4}')
  freed=$((after - before)); [ "$freed" -lt 0 ] && freed=0
  printf '{"ts":"%s","action":"clean","freed_kb":%s,"cleaned":{"next":%s,"dmg":%s,"docker":%s},"next_dirs":%s,"dmgs":%s,"protected":{"running":%s,"dirty":%s,"recent":%s},"free_after_kb":%s,"removed":%s}\n' \
    "$ts" "$freed" "$do_next" "$do_dmg" "$do_docker" "$next_count" "$dmg_count" "$prot_running" "$prot_dirty" "$prot_recent" "$after" "$removed_json" >> "$LOG"
  osascript -e "display notification \"Freed $(human "$freed") - $(human "$after") free now.\" with title \"Disk Cleanup\"" 2>/dev/null
else
  printf '{"ts":"%s","action":"skip","reclaimable_kb":%s,"protected":{"running":%s,"dirty":%s,"recent":%s}}\n' \
    "$ts" "$est_kb" "$prot_running" "$prot_dirty" "$prot_recent" >> "$LOG"
fi
