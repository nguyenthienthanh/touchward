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

[ -d "$APP" ] || { echo "✗ Chưa có $APP — chạy scripts/build-app.sh trước"; exit 1; }

if pgrep -f "${APP_NAME}" >/dev/null 2>&1; then
  echo "▸ Đang chạy — tắt trước khi thay thế…"
  pkill -f "${APP_NAME}" || true
  sleep 1
fi

if [ -d "$TARGET" ]; then
  echo "▸ Gỡ bản cũ ở ${TARGET}…"
  rm -rf "$TARGET"
fi

echo "▸ Cài vào ${TARGET}…"
if ! cp -R "$APP" "$TARGET" 2>/dev/null; then
  echo "  cần quyền quản trị để ghi vào /Applications"
  sudo cp -R "$APP" "$TARGET"
fi

echo
echo "✓ Đã cài ${APP_NAME} ${VERSION}"
echo
echo "Chạy:  open -a \"${APP_NAME}\""
echo "Log:   tail -f ~/Library/Logs/${APP_NAME}.log"
echo "Tắt:   pkill -f ${APP_NAME}"
echo
echo "Lần đầu chạy cần cấp hai quyền (thiếu một là app thoát ngay):"
echo "  System Settings → Privacy & Security → Input Monitoring → ${APP_NAME}"
echo "  System Settings → Privacy & Security → Accessibility    → ${APP_NAME}"
