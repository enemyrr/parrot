#!/usr/bin/env bash
#
# Build parrot and install it for yourself: app in /Applications, CLI on your
# PATH, daemon registered to start at login. No sudo.
#
#   ./scripts/install-local.sh
#
# Re-run it after any change — it stops the old daemon, replaces the app, and
# starts the new one.
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="parrot"
APP_DEST="/Applications/$APP_NAME.app"
BIN_IN_APP="$APP_DEST/Contents/MacOS/$APP_NAME"

# Prefer a PATH dir we own, so the whole install stays sudo-free. Fall back to
# /usr/local/bin only if the user's PATH doesn't include a personal bin.
if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
  CLI_DIR="$HOME/.local/bin"
elif [[ ":$PATH:" == *":$HOME/bin:"* ]]; then
  CLI_DIR="$HOME/bin"
else
  CLI_DIR="/usr/local/bin"
fi
CLI_LINK="$CLI_DIR/$APP_NAME"

./scripts/bundle.sh

# Stop before replacing: a running daemon holds the old binary, and two copies
# would fight over the same hotkey.
if [[ -x "$BIN_IN_APP" ]] || command -v "$APP_NAME" >/dev/null 2>&1; then
  echo "==> stopping any running parrot"
  "$APP_NAME" stop >/dev/null 2>&1 || true
fi

echo "==> installing $APP_DEST"
if [[ -w /Applications ]]; then
  rm -rf "$APP_DEST"
  cp -R "dist/$APP_NAME.app" "$APP_DEST"
else
  echo "    /Applications needs elevation"
  sudo rm -rf "$APP_DEST"
  sudo cp -R "dist/$APP_NAME.app" "$APP_DEST"
fi

echo "==> linking CLI: $CLI_LINK"
if [[ -w "$CLI_DIR" ]] || mkdir -p "$CLI_DIR" 2>/dev/null; then
  ln -sf "$BIN_IN_APP" "$CLI_LINK"
else
  sudo ln -sf "$BIN_IN_APP" "$CLI_LINK"
fi

# A leftover real binary earlier on PATH would shadow the symlink and quietly
# keep running the old build.
SHADOW="$(command -v "$APP_NAME" 2>/dev/null || true)"
if [[ -n "$SHADOW" && "$SHADOW" != "$CLI_LINK" && ! -L "$SHADOW" ]]; then
  echo
  echo "    warning: $SHADOW comes earlier on your PATH than $CLI_LINK"
  echo "             remove it so the CLI matches the app:  sudo rm $SHADOW"
fi

echo "==> starting the daemon"
"$BIN_IN_APP" start

echo
echo "✓ installed"
echo "  app:  $APP_DEST"
echo "  cli:  $CLI_LINK"
echo "  run 'parrot status' any time to check on it"
