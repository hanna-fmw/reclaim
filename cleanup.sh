#!/bin/bash
# Disk Cleanup - scan, ask, reclaim safe space, log. macOS launchd-friendly.
#
# Categories handled (each can be picked individually in the dialog):
#   1. .next caches             - Next.js build caches in ~/Documents projects
#   2. Installer DMGs           - leftover Screaming Frog auto-update DMGs
#   3. Docker unused images     - full prune (not just dangling) + build cache
#   4. npm cache                - ~/.npm/_cacache, rebuilds on next install
#   5. Claude vm_bundles        - sandbox VM bundles, redownloaded on demand
#   6. Dormant node_modules     - per-project picker, only projects untouched
#                                 for DORMANT_DAYS and not active work
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

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
set -u

STATE_DIR="$HOME/.disk-cleanup"
LOG="$STATE_DIR/history.jsonl"
LAST_RUN="$STATE_DIR/last-run"
DOCS="$HOME/Documents"
DMG_DIR="$HOME/.ScreamingFrogSEOSpider/AppUpdater"
NPM_CACHE="$HOME/.npm/_cacache"
CLAUDE_VM="$HOME/Library/Application Support/Claude/vm_bundles"
INTERVAL_DAYS=3
PROTECT_HOURS=24
DORMANT_DAYS=30
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
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
DORM_TMP="$STATE_DIR/.dormant.$$"
PLAN_TMP="$STATE_DIR/.plan.$$"
cleanup_temps() { rm -f "$RUNNING_TMP" "$NEXT_TMP" "$DORM_TMP" "$PLAN_TMP"; }
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

# --- collect safe .next caches ---
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

# --- Docker: estimate size of unused (reclaimable) images + build cache ---
docker_note="not running"
docker_kb=0
if docker info >/dev/null 2>&1; then
  # parse `docker system df` reclaimable column; falls back to 0 if Docker is shy
  docker_kb=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null \
    | awk -F'\t' 'BEGIN{t=0}
        { v=$2; sub(/ \(.*/,"",v); n=v+0;
          if (v ~ /GB/) n=n*1048576;
          else if (v ~ /MB/) n=n*1024;
          else if (v ~ /kB/ || v ~ /KB/) n=n;
          else if (v ~ /B/) n=n/1024;
          t+=n }
        END{ printf "%.0f", t }')
  docker_note="$(human "${docker_kb:-0}") unused images + build cache (volumes left alone)"
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
$(find "$DOCS" -type d -name node_modules -prune 2>/dev/null)
EOF
# sort biggest first for the per-project picker
if [ -s "$DORM_TMP" ]; then
  sort -rn "$DORM_TMP" -o "$DORM_TMP"
fi

est_kb=$((next_kb + dmg_kb + docker_kb + npm_kb + claude_kb + dorm_kb))
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

# --- dry: print plan, never delete ---
if [ "$MODE" = "dry" ]; then
  cat "$PLAN_TMP"
  echo ""
  echo "--- .next dirs that would be removed: ---"
  cat "$NEXT_TMP" 2>/dev/null
  echo "--- dormant node_modules (size  path): ---"
  awk -F'\t' '{printf "  %s  %s\n", $1, $2}' "$DORM_TMP" 2>/dev/null
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
dorm_selected_file=""
action="skip"

if [ "$MODE" = "yes" ]; then
  # Headless safe set. Skip dormant node_modules (needs per-project approval).
  # Skip Claude vm_bundles if Claude.app is running.
  do_next=1; do_dmg=1; do_docker=1; do_npm=1
  [ "$claude_running" = "0" ] && do_claudevm=1
  action="clean"
else
  # Interactive: main dialog (Cancel / Ask Claude / Continue) -> picker.
  # Pad with a wide invisible spacer line so the dialog renders wider.
  # AppleScript display dialog has no width param; width = widest line.
  spacer=$(printf '%*s' 160 '')
  plan_for_dialog=$(printf '%s\n%s' "$spacer" "$(cat "$PLAN_TMP")" | sed 's/"/\\"/g')
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

  # Default-on: low/none risk items. Off by default: Claude vm_bundles (if running), dormant.
  default_items="\"$l1\", \"$l2\", \"$l3\", \"$l4\""
  [ "$claude_running" = "0" ] && [ "$claude_kb" -gt 0 ] && default_items="$default_items, \"$l5\""

  all_items="\"$l1\", \"$l2\", \"$l3\", \"$l4\", \"$l5\", \"$l6\""

  picked=$(osascript 2>/dev/null \
    -e "set theList to {$all_items}" \
    -e "set theDefaults to {$default_items}" \
    -e 'set chosen to choose from list theList with prompt "Tick what to clean. Ticked-by-default items are the safe set." default items theDefaults with multiple selections allowed' \
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
  case "$picked" in *"Docker unused images"*) do_docker=1 ;; esac
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
        # shorten to ~/Documents/...
        short=${proj/#$HOME/~}
        lbl="$(human "$sz")  -  $short"
        esc=${lbl//\"/\\\"}
        dorm_list="$dorm_list\"$esc\", "
      done < "$DORM_TMP"
      dorm_list="${dorm_list%, }"

      dorm_picked=$(osascript 2>/dev/null \
        -e "set theList to {$dorm_list}" \
        -e 'set chosen to choose from list theList with prompt "Tick which dormant node_modules to delete. These projects had no edits for '"$DORMANT_DAYS"'+ days." with multiple selections allowed' \
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

  total_actions=$((do_next + do_dmg + do_docker + do_npm + do_claudevm + do_dorm))
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
    docker system prune -af >/dev/null 2>&1
    removed_json="$removed_json{\"path\":\"docker:system-prune-af\",\"kb\":${docker_kb:-0}},"
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

  removed_json="[${removed_json%,}]"
  after=$(df -k / | awk 'NR==2{print $4}')
  freed=$((after - before)); [ "$freed" -lt 0 ] && freed=0
  printf '{"ts":"%s","action":"clean","freed_kb":%s,"cleaned":{"next":%s,"dmg":%s,"docker":%s,"npm":%s,"claudevm":%s,"dormant":%s},"next_dirs":%s,"dmgs":%s,"dormant_count":%s,"protected":{"running":%s,"dirty":%s,"recent":%s},"free_after_kb":%s,"removed":%s}\n' \
    "$ts" "$freed" "$do_next" "$do_dmg" "$do_docker" "$do_npm" "$do_claudevm" "$do_dorm" \
    "$next_count" "$dmg_count" "$dorm_count" \
    "$prot_running" "$prot_dirty" "$prot_recent" "$after" "$removed_json" >> "$LOG"
  osascript -e "display notification \"Freed $(human "$freed") - $(human "$after") free now.\" with title \"Disk Cleanup\"" 2>/dev/null
else
  printf '{"ts":"%s","action":"skip","reclaimable_kb":%s,"protected":{"running":%s,"dirty":%s,"recent":%s}}\n' \
    "$ts" "$est_kb" "$prot_running" "$prot_dirty" "$prot_recent" >> "$LOG"
fi
