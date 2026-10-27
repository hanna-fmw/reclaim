#!/bin/bash
# Daily disk check, run by a bb automation. Under MIN_FREE_GB free: clean the
# low-risk set (cleanup.sh --yes), then report. Prints a line either way so the
# automation's run log shows what happened. Runs this folder's own cleanup.sh.
# With the ops shared library on this Mac (`paths get ops`), PATH comes from it and a disk
# still low after cleaning goes to its notifier (Slack #system, once, and again when fixed);
# without it, a macOS notification.
HERE="$(cd "$(dirname "$0")" && pwd)"
OPS="$(paths get ops 2>/dev/null || "$HOME/.local/bin/paths" get ops 2>/dev/null)"
if [ -n "$OPS" ] && [ -f "$OPS/lib/lib.sh" ]; then
  . "$OPS/lib/lib.sh"; PATH="$(job_path)"; export PATH
else
  export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  notify() { local m; m="$(cat)"; [ -n "$m" ] && osascript -e "display notification \"$m\" with title \"Disk Cleanup\"" 2>/dev/null; true; }
fi
MIN_FREE_GB=${MIN_FREE_GB:-15}
free_gb() { df -g / | awk 'NR==2{print $4}'; }

before=$(free_gb)
if [ "$before" -ge "$MIN_FREE_GB" ]; then echo "ok: ${before} GB free"; notify disk </dev/null; exit 0; fi

bash "$HERE/cleanup.sh" --yes >/dev/null 2>&1
after=$(free_gb)
echo "cleaned: ${before} -> ${after} GB free"
if [ "$after" -ge "$MIN_FREE_GB" ]; then
  notify disk </dev/null  # cleaned enough: any earlier "still low" is fixed
else
  echo "still low after cleaning caches (under ${MIN_FREE_GB} GB free): ask tech-lead to run reclaim, and restart the Mac when you can" | notify disk
fi
