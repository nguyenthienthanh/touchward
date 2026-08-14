# TouchBridge

Biến màn hình cảm ứng USB thành thiết bị trỏ **tuyệt đối** trên macOS.

macOS không có driver dịch toạ độ HID digitizer thành vị trí con trỏ. Với màn hình
dual-mode như chip SiS trong máy này, thứ duy nhất tới được WindowServer là bit Button 1 —
một cú nhấn không kèm toạ độ, nên nó rơi vào đúng chỗ con trỏ đang đứng. TouchBridge giành
lấy thiết bị, đọc toạ độ thật, rồi tự bắn sự kiện chuột vào đúng điểm chạm.

Chạy hoàn toàn ở user-space: **không kernel extension, không tắt SIP.**

## Chạy thử

```bash
bash scripts/bundle.sh          # build + đóng gói + ký ad-hoc
open build/TouchBridge.app
```

Lần đầu macOS sẽ hỏi hai quyền. Nếu không thấy hộp thoại, bật tay trong
System Settings → Privacy & Security:

| Quyền | Dùng để |
|---|---|
| **Input Monitoring** | Mở và giành (seize) thiết bị HID |
| **Accessibility** | Bắn sự kiện chuột/phím, đọc phần tử đang focus |

Muốn xem log thì chạy thẳng binary thay vì `open`:

```bash
build/TouchBridge.app/Contents/MacOS/TouchBridge
```

> **Vì sao phải đóng gói .app?** TCC ghi nhớ quyền theo chữ ký. Binary trần từ
> `swift run` đổi danh tính mỗi lần build nên sẽ bị hỏi lại quyền liên tục. Bundle với
> bundle ID cố định thì quyền bám qua các lần build.

## Cử chỉ

| Thao tác | Kết quả |
|---|---|
| Chạm nhanh | Click trái tại điểm chạm |
| Giữ > 0,6 giây | Click phải |
| Một ngón kéo | Kéo thả (bôi chọn) |
| Hai ngón kéo | Cuộn, cả dọc lẫn ngang |
| Hai ngón chạm nhanh | Click phải |
| Chạm vào ô nhập | Hiện bàn phím ảo trên chính màn cảm ứng |
| Nhấc hết tay ra | Sau ~0,5 giây con trỏ về màn hình chính |

Cuộn bị ngược chiều? Đổi `contentFollowsFinger` trong `EventSynthesizer.swift` — đó là
chỗ duy nhất quyết định chiều.

## Kiến trúc

Tách đôi có chủ đích, để phần logic kiểm chứng được mà không cần quyền hệ thống:

```
TouchBridgeCore/          ← hàm thuần, 30 unit test, chạy `swift test` không cần TCC
  HIDReportParser         báo cáo 0x91 (digitizer 5 điểm) và 0x03 (mouse dự phòng)
  CoordinateMapper        0…4095 → toạ độ global, có calibration + clamp
  GestureRecognizer       state machine kiểu trackpad

touchbridge/              ← tầng hệ thống, không unit test được
  HIDTouchDevice          IOHIDManager, seize, feature report bật multitouch
  EventSynthesizer        CGEvent có đóng dấu nguồn
  CursorReturn            trả con trỏ + hàng rào bảo vệ chuột thật
  DisplayRegistry         nhận diện màn theo vendor/model/serial
  TouchPipeline           dây nối: byte vào, sự kiện chuột ra
  Keyboard/               NSPanel không-giành-focus + AX focus + key injection
```

```bash
swift test    # 30 test, không cần quyền gì
```

## Không đụng vào chuột và bàn phím thật

Đây là ràng buộc cứng, và có ba cơ chế giữ nó:

1. **Seize chỉ đúng một thiết bị.** Chuột và bàn phím vật lý đi đường riêng, TouchBridge
   không hề chạm vào.
2. **Event tap chỉ quan sát.** `CursorReturn` dùng `.listenOnly` — không sửa, không nuốt
   sự kiện nào. Nó chỉ để biết anh có đang cầm chuột không.
3. **Đóng dấu nguồn sự kiện.** Mọi sự kiện TouchBridge tạo ra mang một marker trong
   `eventSourceUserData`, nên phân biệt được với chuột thật mà không cần đoán.

Cộng thêm `localEventsSuppressionInterval = 0`: nếu thiếu dòng này, mỗi lần trả con trỏ
sẽ chặn chuột vật lý 0,25 giây và chuột sẽ có cảm giác bị hỏng.

## Giới hạn đã biết

- **Ô mật khẩu không gõ được bằng bàn phím ảo.** Khi Secure Input bật, macOS chặn phím
  tổng hợp trên toàn hệ thống. Đây là thiết kế bảo mật, không có đường vòng. TouchBridge
  phát hiện và hiện chữ "dùng bàn phím thật" thay vì im lặng nuốt phím.
- **App có cây Accessibility kém** (Qt, Java, Flutter, game) sẽ không kích hoạt bàn phím
  tự động. Electron/Chromium được xử lý bằng `AXManualAccessibility`.
- **Chưa có calibration UI.** `Calibration` đã có trong code và có test; còn thiếu màn
  hình chạm 4 góc để sinh ra hệ số.
- **Chưa có momentum scroll.** Cuộn hiện là 1:1 theo ngón.

## Nghiệm thu tay

Những thứ không tự động hoá được vì phụ thuộc phần cứng và TCC:

- [ ] Chạm góc trên-trái màn cảm ứng → con trỏ nhảy đúng góc đó, không phải màn chính
- [ ] Chạm 4 góc → không lệch quá vài mm (nếu lệch thì cần calibration)
- [ ] Giữ 1 giây → menu chuột phải hiện ra tại điểm chạm
- [ ] Hai ngón kéo trong trình duyệt → trang cuộn, đúng chiều
- [ ] Kéo một ngón qua đoạn văn bản → bôi chọn được
- [ ] Nhấc tay, đợi 1 giây → con trỏ về màn chính
- [ ] **Đang rê chuột thật thì chạm màn cảm ứng → chuột không khựng, không bị cướp**
- [ ] Gõ bàn phím vật lý khi bàn phím ảo đang hiện → chữ vẫn vào đúng app
- [ ] Chạm ô tìm kiếm trong Safari → bàn phím ảo hiện trên màn cảm ứng, gõ ra chữ
- [ ] Chạm ô mật khẩu → bàn phím ảo hiện cảnh báo thay vì gõ hụt
