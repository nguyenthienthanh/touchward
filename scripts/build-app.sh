#!/bin/bash
# Builds a signed .app bundle from the Swift package.
#
# The bundle is not optional packaging polish: TCC keys Accessibility and Input Monitoring
# grants to a code signature and a path, so a bare binary is re-prompted on every rebuild
# and can never hold a permission for long.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/appconfig.sh

CONFIG="${1:-release}"
APP="${OUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"

echo "▸ Biên dịch (${CONFIG})…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/${PRODUCT}"
[ -f "$BIN" ] || { echo "✗ Không thấy binary tại $BIN"; exit 1; }

# Regenerate the icon so it can never drift from the code that draws it.
if [ ! -f Resources/AppIcon.icns ] || [ scripts/makeicon.swift -nt Resources/AppIcon.icns ]; then
  echo "▸ Vẽ icon…"
  ICONTOOL="$(mktemp -d)/makeicon"
  swiftc -O scripts/makeicon.swift -o "$ICONTOOL"
  rm -rf Resources/AppIcon.iconset
  "$ICONTOOL" Resources/AppIcon.iconset >/dev/null
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "▸ Dựng ${APP}…"
rm -rf "$APP"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "$BIN" "${CONTENTS}/MacOS/${APP_NAME}"
cp Resources/AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"

# Info.plist is generated, not stored, so the display name and identifier can never fall
# out of step with appconfig.sh.
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Agent app: no Dock icon and no menu bar. Nothing here may steal focus from the
       app being typed into. -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Ethan Nguyen</string>
</dict>
PLIST
echo "</plist>" >> "${CONTENTS}/Info.plist"

IDENTITY="${SIGNING_IDENTITY:-}"
if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "▸ Ký bằng \"$IDENTITY\"…"
else
  echo "▸ Ký ad-hoc (chưa có chứng chỉ — chạy scripts/make-signing-cert.sh để quyền không mất mỗi lần build)…"
  IDENTITY="-"
fi

codesign --force --deep --sign "$IDENTITY" \
         --identifier "${BUNDLE_ID}" \
         --options runtime --timestamp=none "$APP" 2>&1 | sed 's/^/  /'

codesign --verify --strict "$APP" && echo "  chữ ký hợp lệ"

echo "✓ ${APP}"
