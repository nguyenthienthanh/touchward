#!/bin/bash
# Installs into /Applications and hands back the permission steps.
#
# /Applications rather than ~/Applications on purpose: TCC keys its grants to the path as
# well as the signature, so an app that later moves has to be granted permission all over
# again. Installing where it will live avoids making the user do that twice.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/appconfig.sh

APP="${OUT_DIR}/${APP_NAME}.app"
TARGET="/Applications/${APP_NAME}.app"

[ -d "$APP" ] || { echo "✗ No $APP yet — run scripts/build-app.sh first"; exit 1; }

if pgrep -f "${APP_NAME}" >/dev/null 2>&1; then
  echo "▸ Already running — quitting it before replacing…"
  pkill -f "${APP_NAME}" || true
  sleep 1
fi

if [ -d "$TARGET" ]; then
  echo "▸ Removing the old copy at ${TARGET}…"
  rm -rf "$TARGET"
fi

echo "▸ Installing into ${TARGET}…"
if ! cp -R "$APP" "$TARGET" 2>/dev/null; then
  echo "  administrator rights are needed to write to /Applications"
  sudo cp -R "$APP" "$TARGET"
fi

echo
echo "✓ Installed ${APP_NAME} ${VERSION}"
echo
echo "Run:   open -a \"${APP_NAME}\""
echo "Log:   tail -f ~/Library/Logs/${APP_NAME}.log"
echo "Quit:  pkill -f ${APP_NAME}"
echo
echo "The first run needs permission (the app waits until it is granted):"
echo "  System Settings → Privacy & Security → Input Monitoring → ${APP_NAME}"
echo "  System Settings → Privacy & Security → Accessibility    → ${APP_NAME}"
