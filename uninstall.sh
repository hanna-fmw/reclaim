#!/bin/bash
# Unload the launchd schedule and remove the CLI symlink.
# Leaves ~/.disk-cleanup/ (including history.jsonl) in place unless --purge is given.
set -u

LABEL="dev.reclaim"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "Schedule unloaded." || echo "Schedule was not loaded."
rm -f "$PLIST"
rm -f /opt/homebrew/bin/reclaim "$HOME/.local/bin/reclaim" 2>/dev/null
echo "CLI symlink removed."

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/.disk-cleanup"
  echo "Purged ~/.disk-cleanup (history and state deleted)."
else
  echo "Kept ~/.disk-cleanup (history + state). Use --purge to delete it too."
fi
