#!/bin/bash
# Deploy reclaim from this project folder to the runtime location, put the CLI on
# PATH, and load the launchd schedule. Re-run any time after editing the source.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.disk-cleanup"
PLIST_NAME="dev.reclaim.plist"
PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LABEL="dev.reclaim"

mkdir -p "$DEST"
cp "$SRC/cleanup.sh" "$DEST/cleanup.sh"
cp "$SRC/reclaim"    "$DEST/reclaim"
chmod +x "$DEST/cleanup.sh" "$DEST/reclaim"

# Put the CLI on PATH (prefer Homebrew bin, fall back to ~/.local/bin).
if [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ]; then
  ln -sf "$DEST/reclaim" /opt/homebrew/bin/reclaim
  echo "Linked: /opt/homebrew/bin/reclaim"
else
  mkdir -p "$HOME/.local/bin"
  ln -sf "$DEST/reclaim" "$HOME/.local/bin/reclaim"
  echo "Linked: ~/.local/bin/reclaim (ensure ~/.local/bin is on your PATH)"
fi

# Load the launchd schedule (substitute __HOME__ placeholders at install time so
# the plist works for whichever user is installing).
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__HOME__|$HOME|g" "$SRC/$PLIST_NAME" > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed. Schedule loaded (daily 08:45, acts every ~3 days)."
echo "Try: reclaim status"
