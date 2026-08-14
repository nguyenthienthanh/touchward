#!/bin/bash
# Builds TouchBridge.app.
#
# The bundle exists for one reason: TCC remembers Accessibility and Input Monitoring
# grants per code signature. A bare `swift run` binary gets a fresh identity on every
# rebuild, so macOS re-prompts every single time. A bundle with a stable identifier and
# an ad-hoc signature keeps the grant.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/TouchBridge.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/touchbridge"
[ -f "$BIN" ] || { echo "✗ Không tìm thấy binary tại $BIN"; exit 1; }

echo "▸ Đóng gói ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/TouchBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. Stable as long as the bundle id and binary path stay the same,
# which is all TCC needs to keep the grant across rebuilds.
echo "▸ Ký (ad-hoc)…"
codesign --force --sign - --identifier com.ethannguyen.touchbridge \
         --options runtime --timestamp=none "$APP" 2>&1 | sed 's/^/  /'

echo "✓ Xong: $APP"
echo
echo "Chạy:  open $APP     (hoặc $APP/Contents/MacOS/TouchBridge để xem log)"
echo
echo "Lần đầu chạy macOS sẽ hỏi hai quyền. Nếu không thấy hộp thoại, bật tay:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  System Settings → Privacy & Security → Input Monitoring"
