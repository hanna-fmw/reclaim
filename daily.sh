#!/bin/bash
# Daily disk check, run by a bb automation. Under MIN_FREE_GB free: clean the
# low-risk set (cleanup.sh --yes), then report. Prints a line either way so the
# automation's run log shows what happened.
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
MIN_FREE_GB=${MIN_FREE_GB:-15}
free_gb() { df -g / | awk 'NR==2{print $4}'; }

tell() {
  if command -v slack-post >/dev/null; then slack-post tech-lead "$1"
  else osascript -e "display notification \"$1\" with title \"Disk Cleanup\"" 2>/dev/null; fi
}

before=$(free_gb)
if [ "$before" -ge "$MIN_FREE_GB" ]; then echo "ok: ${before} GB free"; exit 0; fi

bash "$HOME/.disk-cleanup/cleanup.sh" --yes >/dev/null 2>&1
after=$(free_gb)
echo "cleaned: ${before} -> ${after} GB free"
if [ "$after" -ge "$MIN_FREE_GB" ]; then
  tell "🟢 Disk was low (${before} GB free). Cleaned caches, now ${after} GB free."
else
  tell "🟡 Disk still low: ${after} GB free after cleaning caches. Ask tech-lead to run reclaim, and restart the Mac when you can."
fi
