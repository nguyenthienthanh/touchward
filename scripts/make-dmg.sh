#!/bin/bash
# Builds the distributable disk image: the app beside a shortcut to /Applications, which
# is the drag-and-drop install every Mac user already knows. No installer package, because
# nothing here needs to run as root or touch anything outside /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/appconfig.sh

APP="${OUT_DIR}/${APP_NAME}.app"
[ -d "$APP" ] || { echo "✗ No $APP yet — run scripts/build-app.sh first"; exit 1; }

# Spaces in a volume name make the mount path awkward to type; strip them for the file
# name while keeping the readable name on the mounted volume.
SAFE_NAME="$(echo "$APP_NAME" | tr -d ' ')"
DMG="${OUT_DIR}/${SAFE_NAME}-${VERSION}.dmg"
STAGE="$(mktemp -d)"

echo "▸ Staging the disk image contents…"
cp -R "$APP" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

# A short read-me on the volume, in both languages: this app is useless until Accessibility
# is granted, and a user who does not know that will conclude it is broken.
cat > "${STAGE}/READ ME FIRST.txt" <<TXT
${APP_NAME} ${VERSION}

INSTALL
  Drag ${APP_NAME} onto the Applications folder next to it.

FIRST RUN
  macOS asks for Accessibility. The app cannot work without it:

    • Accessibility — to move the pointer, type, and read the touchscreen

  If no dialog appears, enable it by hand:
    System Settings → Privacy & Security → Accessibility

  That one grant also covers reading input devices, so the app will NOT appear
  in the Input Monitoring list. Do not go looking for it there.

  The permission is used for the touchscreen only. Your real mouse and keyboard
  are never touched.

LOG
  tail -f ~/Library/Logs/${APP_NAME}.log

QUIT
  pkill -f ${APP_NAME}
TXT

cat > "${STAGE}/ĐỌC TRƯỚC.txt" <<TXT
${APP_NAME} ${VERSION}

CÀI ĐẶT
  Kéo ${APP_NAME} vào thư mục Applications bên cạnh.

LẦN ĐẦU CHẠY
  macOS sẽ hỏi quyền Accessibility. Thiếu nó thì app không chạy được:

    • Accessibility — để điều khiển con trỏ, gõ phím, và đọc màn cảm ứng

  Nếu không thấy hộp thoại, bật tay ở:
    System Settings → Privacy & Security → Accessibility

  Quyền này bao trùm luôn việc đọc thiết bị nhập, nên app sẽ KHÔNG hiện
  trong danh sách Input Monitoring — đừng đi tìm ở đó.

  Quyền này chỉ dùng cho màn cảm ứng. Chuột và bàn phím thật không bị đụng tới.

XEM LOG
  tail -f ~/Library/Logs/${APP_NAME}.log

TẮT APP
  pkill -f ${APP_NAME}
TXT

echo "▸ Creating ${DMG}…"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" \
               -srcfolder "$STAGE" \
               -ov -format UDZO \
               -quiet \
               "$DMG"

rm -rf "$STAGE"

SIZE="$(du -h "$DMG" | cut -f1)"
echo "✓ ${DMG} (${SIZE})"
