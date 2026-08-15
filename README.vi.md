# Touchward

[🇬🇧 English](README.md) · **Tiếng Việt**

[![release](https://img.shields.io/github/v/release/nguyenthienthanh/touchward)](https://github.com/nguyenthienthanh/touchward/releases/latest)
[![npm](https://img.shields.io/npm/v/touchward)](https://www.npmjs.com/package/touchward)
[![Homebrew](https://img.shields.io/badge/homebrew-nguyenthienthanh%2Ftap-orange)](https://github.com/nguyenthienthanh/homebrew-tap)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black)](#yêu-cầu)
[![license](https://img.shields.io/github/license/nguyenthienthanh/touchward)](LICENSE)

Biến màn hình cảm ứng USB thành thiết bị trỏ **tuyệt đối** trên macOS.

macOS không có driver dịch toạ độ HID digitizer thành vị trí con trỏ. Với màn hình
dual-mode — loại dùng chip SiS — thứ duy nhất tới được WindowServer là bit Button 1: một cú
nhấn không kèm toạ độ, nên nó rơi vào đúng chỗ con trỏ đang đứng. Touchward giành lấy thiết
bị, đọc toạ độ thật, rồi tự bắn sự kiện chuột vào đúng điểm anh chạm.

Chạy hoàn toàn ở user-space: **không kernel extension, không tắt SIP.**

---

## Tính năng

### Màn cảm ứng thành một thiết bị trỏ thật sự

- **Trỏ tuyệt đối.** Con trỏ tới đúng chỗ ngón tay đặt xuống, không phải trượt đi từ chỗ nó
  đang đứng. Chạm để click, giữ để click phải.
- **Một ngón kéo** để bôi chọn chữ và di chuyển vật, y như giữ nút chuột.
- **Hai ngón cuộn**, cả hai chiều, và cuộn vào đúng cửa sổ dưới ngón tay chứ không phải cửa
  sổ đang có con trỏ.
- **Ba ngón xoè ra / chụm vào để thu phóng.** Hai ngón đã dành cho cuộn, nên thu phóng lấy
  cử chỉ mà không gì khác giành.
- **Con trỏ tự về nhà.** Nửa giây sau khi anh nhấc tay, con trỏ quay về giữa màn hình chính,
  để lần sau cầm chuột là nó đã ở đúng chỗ anh chờ.

### Bàn phím ảo biết tự tránh đường

- **Bố cục iPadOS** để chuyển thẳng thói quen tay: delete cuối hàng trên, return cuối hàng
  giữa, shift hai đầu hàng chữ dưới, `.?123` / `#+=` đổi mặt phím ở góc. Chạm shift một lần
  được một chữ hoa, chạm đúp thì khoá hoa.
- **Chỉ hiện với ô nhập nằm trên màn cảm ứng.** Ô ở màn chính thì anh gõ bằng bàn phím thật
  đang ngay trước mặt.
- **`⌨︎↓` thu nhỏ thành một tab** ở góc, chạm tab là mở lại.
- **Nói rõ khi macOS chặn.** Lúc Secure Input bật, phím tổng hợp bị từ chối trên toàn hệ
  thống — thay vì nuốt phím, bàn phím báo anh dùng bàn phím thật.
- **Gõ không kéo con trỏ đi.** Phím được gọi thẳng từ điểm chạm chứ không bắn click giả lên
  panel.

### Không đụng vào thứ của người khác

- **Chuột và bàn phím thật nguyên vẹn.** Chỉ đúng một thiết bị bị seize, event tap chỉ quan
  sát, và mọi sự kiện tổng hợp đều đóng dấu nên không bao giờ lẫn với đồ thật. Xem
  [Không đụng vào thiết bị nhập thật](#không-đụng-vào-thiết-bị-nhập-thật).
- **Không kernel extension, không tắt SIP, không login item.** Một app user-space, một
  quyền.
- **Không hardcode gì về phần cứng.** Dải toạ độ, số điểm chạm, bố cục ngón đều lấy từ
  descriptor của chính thiết bị, nên một panel code này chưa từng thấy vẫn chạy mà không ai
  phải sửa hằng số. Xem [Không hardcode gì về thiết bị](#không-hardcode-gì-về-thiết-bị).
- **Một cú kéo không bao giờ để kẹt nút chuột.** Ctrl-C, thoát app, máy ngủ, rút cáp USB đều
  nhả thứ đang giữ, và luồng report chết giữa chừng thì có hạn 2 giây bắt lại.
- **Nó nói ra nó đang làm gì.** Một file log ghi lại đã chọn màn nào, panel báo gì, và vì sao
  bàn phím hiện hay không hiện.

---

## Phần cứng đã kiểm chứng

Mọi số liệu dưới đây đọc từ máy đang chạy, không chép từ datasheet.

### Màn hình cảm ứng

| | |
|---|---|
| Màn hình | **VSP VP1560FST1** — màn di động cảm ứng 15.6", 1920×1080 IPS, 60 Hz |
| Nơi mua | [FPT Shop](https://fptshop.com.vn/man-hinh/vsp-vp1560fst1156-inch-full-hd-ips-60-hz) · [TMINS](https://tmins.vn/products/man-hinh-di-dong-vsp-vp1560fst1-15-6-inch-fhd-60hz-5ms-ips-cam-ung) |
| Kết nối | USB-C (cảm ứng + hình), macOS thấy là màn 1920×1080 |

### Chip cảm ứng — phần quan trọng cho màn hình khác

Đây là con chip, không phải cái màn. **Màn nào dùng cùng controller này thì hành xử y hệt**,
bất kể logo trên viền — mà chip SiS thì cực phổ biến trong các màn di động cảm ứng
white-label.

| | |
|---|---|
| Controller | **SiS HID Touch Controller** — Silicon Integrated Systems Corp. ([vendor 0x0457](https://devicehunt.com/view/type/usb/vendor/0457)) |
| USB ID | VID `0x0457` (1111), PID `0x0819` (2073), device release `0x0200` |
| Kết nối | USB HID |
| Dải logic | 4095 × 4095 |
| Số điểm chạm | 5 |
| Report digitizer | ID `0x91` — năm collection Finger (Tip Switch, Confidence, Contact Id, X, Y, Width, Height) cùng Contact Count và Scan Time |
| Report mouse-compat | ID `0x03` — X/Y trên trang Generic Desktop cùng Button 1 |
| Device Configuration | Usage `0x0D:0x0E`, feature report ID `7`, chứa Input Mode (`0x52`) và Device Index (`0x53`) |

Mặc định controller này nằm ở **mouse-compatibility mode** và chỉ báo một điểm chạm — đó
chính là lý do không thể cuộn hai ngón cho tới khi Input Mode được đổi sang `2`. Touchward
làm việc đó lúc khởi động rồi **đọc ngược giá trị** để chắc chắn panel thật sự nghe theo —
xem [Xử lý sự cố](#xử-lý-sự-cố).

Nếu màn của anh dùng chip khác thì vẫn có cơ hội chạy: không có gì trong code khoá theo các
ID này. Việc nhận thiết bị dựa trên HID usage (`Digitizer / Touch Screen`), dải toạ độ lấy
từ descriptor, và các khe ngón được map từ chính collection mà thiết bị khai báo. Ai thử
trên phần cứng khác — chạy được hay không — đều rất đáng báo lại.

### Máy chủ

| | |
|---|---|
| macOS | **26.5.2** (build 25F84) |
| Máy | Apple M1 Max |
| Toolchain | Swift 6.0.3 / Xcode command line tools |
| Yêu cầu tối thiểu | macOS 13 (khai báo trong `Package.swift`; nhưng chỉ mới test trên 26.5.2) |
| Bố trí lúc test | Màn cảm ứng 1920×1080 đặt bên trái màn chính 2560×1440 |

---

## Yêu cầu

- macOS 13 trở lên (đã test trên 26.5.2).
- Xcode command line tools: `xcode-select --install`.
- Một màn cảm ứng khai báo là HID `Digitizer / Touch Screen`, đã cắm và **đang hiện hình** —
  macOS phải thấy nó như một màn hình.
- Đúng một màn phụ, hoặc đặt `TOUCHWARD_DISPLAY_ID`. Touchward từ chối đoán màn nào là màn
  cảm ứng khi có nhiều lựa chọn.

Cứ để Touchward chạy kể cả khi không cắm gì. **Mọi hành vi cảm ứng đều tắt cho tới khi panel
được cắm *và* đang bật màn** — màn ở chế độ chờ thường vẫn cấp điện cho cổng USB, nên bộ số
hoá vẫn báo điểm chạm cho một màn hình không ai nhìn thấy; hành động theo đó sẽ đẩy con trỏ
tới chỗ anh không dõi theo được. App sẽ chờ, ghi rõ trong log, và tự bật lên khi panel sẵn
sàng.

---

## Cài đặt

Ba đường tới cùng một bản `.app` đã ký. Chọn đường nào tiện nhất — hoặc
[tự build](#build-và-chạy).

### Tải ảnh đĩa

[**Tải Touchward 1.0.0**](https://github.com/nguyenthienthanh/touchward/releases/latest)
→ mở file `.dmg` → kéo **Touchward** vào Applications.

### Homebrew

```bash
brew install --cask nguyenthienthanh/tap/touchward
```

### npm

```bash
npx touchward install
```

Gói npm là **trình cài**, không phải app: nó tải ảnh đĩa từ bản phát hành ở trên, đối chiếu
checksum đã ghim sẵn, rồi chép bundle vào `/Applications`. Việc cài là một lệnh gõ rõ ràng
chứ không phải hook `postinstall` — một gói npm không nên tự đặt app vào `/Applications`
sau lưng người dùng. Gỡ ra bằng `npx touchward uninstall`.

### Rồi cấp đúng một quyền

Cài kiểu nào cũng vậy: Touchward không làm gì cho tới khi anh bật nó ở
**System Settings → Privacy & Security → Accessibility**. Quyền này bao luôn việc đọc màn
cảm ứng, nên Touchward sẽ **không** xuất hiện trong Input Monitoring — đó là bình thường,
[giải thích ở mục Quyền](#quyền).

App ký bằng chứng chỉ tự ký, nên lần mở đầu tiên Gatekeeper sẽ hỏi xác nhận.

---

## Build và chạy

Bốn lệnh, theo thứ tự. Chạy từ thư mục gốc của repo.

### 1. Tạo chứng chỉ ký nội bộ (một lần cho mỗi máy)

```bash
bash scripts/make-signing-cert.sh
```

macOS nhớ quyền đã cấp theo **chữ ký** của app. Chữ ký ad-hoc có kèm hash của binary, nên
mỗi lần build lại là một app hoàn toàn mới và anh phải cấp Accessibility lại từ đầu. Một
chứng chỉ tự ký cố định giữ cho danh tính không đổi. Nó nằm trong login keychain và không
dùng vào việc gì khác.

### 2. Build app bundle

```bash
bash scripts/build-app.sh          # release; truyền `debug` nếu muốn bản debug
```

Cho ra `Artifacts/Touchward.app`, đã vẽ icon và ký. Việc đóng gói .app không phải cho đẹp:
binary trần từ `swift run` không giữ được quyền TCC.

### 3. Cài đặt

```bash
bash scripts/install.sh
```

Chép app vào `/Applications`. Đường dẫn này quan trọng — TCC gắn quyền theo cả vị trí lẫn
chữ ký, nên app dời chỗ về sau sẽ phải xin quyền lại từ đầu.

### 4. Chạy

```bash
open -a Touchward
```

Touchward là app phụ trợ: không icon Dock, không cửa sổ. Muốn biết nó đang làm gì:

```bash
tail -f ~/Library/Logs/Touchward.log
```

Tắt: `pkill -f Touchward`.

### Tuỳ chọn: tạo ảnh đĩa để chia sẻ

```bash
bash scripts/make-dmg.sh           # Artifacts/Touchward-1.0.0.dmg
```

### Chạy test

```bash
swift test                         # 96 test, không cần quyền gì
```

`TouchwardCore` là logic thuần, không IOKit không AppKit, đúng để phần parse, cử chỉ và ánh
xạ toạ độ kiểm chứng được mà không cần quyền hệ thống nào.

---

## Quyền

Lần đầu chạy macOS sẽ hỏi **Accessibility**. Cấp xong là Touchward tự chạy tiếp. Nếu không
thấy hộp thoại, bật tay tại:

**System Settings → Privacy & Security → Accessibility → Touchward**

| Quyền | Dùng để |
|---|---|
| **Accessibility** | Điều khiển con trỏ, gõ phím, đọc phần tử đang focus — **và đọc luôn màn cảm ứng** |

> Chỉ cần **một** quyền này. Nó bao trùm luôn quyền theo dõi thiết bị nhập, nên Touchward
> sẽ **không xuất hiện** trong danh sách Input Monitoring. Đó là bình thường — đừng đi tìm
> một ô đánh dấu không bao giờ có ở đó.

Nếu Input Monitoring từng bị từ chối, macOS sẽ không hỏi lại. Xoá trạng thái cũ rồi mở lại
app:

```bash
tccutil reset All com.ethannguyen.touchward
```

---

## Cử chỉ

| Thao tác | Kết quả |
|---|---|
| Chạm nhanh | Click trái tại điểm chạm |
| Giữ > 0,6 giây | Click phải |
| Một ngón kéo | Kéo — bôi chọn chữ, di chuyển vật |
| Hai ngón kéo | Cuộn, cả hai chiều |
| Ba ngón xoè ra / chụm vào | Phóng to / thu nhỏ |
| Hai ngón chạm nhanh | Click phải |
| Chạm ô nhập trên màn cảm ứng | Bàn phím ảo hiện trên chính màn cảm ứng |
| Nhấc hết tay | Sau ~0,5 giây con trỏ về màn hình chính |

Cuộn bị ngược chiều? Đổi `contentFollowsFinger` trong `EventSynthesizer.swift` — đó là chỗ
duy nhất quyết định chiều.

**Thu phóng dùng ba ngón chứ không phải hai**, vì hai ngón đã dành cho cuộn. Cứ mỗi ~10% mở
ra hoặc khép lại là một lần Command + `=` / Command + `-` — đúng phím tắt của View ▸ Zoom In
/ Zoom Out trong gần như mọi app Mac. macOS không có API công khai cho cử chỉ phóng to thật;
Command + cuộn thì nhắm đúng cửa sổ dưới ngón tay, nhưng app nào không hỗ trợ nó sẽ **cuộn
tài liệu** thay vì phóng — còn phím tắt mà app không hỗ trợ thì đơn giản là không xảy ra gì.
Đánh đổi: **lệnh phóng đi vào app đang được focus**, nên chạm vào cửa sổ trước nếu nó chưa
được chọn.

## Bàn phím ảo

Bố cục theo iPadOS để chuyển thẳng thói quen tay: delete cuối hàng trên, return cuối hàng
giữa, shift hai đầu hàng chữ dưới cùng, `.?123` / `#+=` đổi mặt phím ở góc. Chạm shift một
lần được một chữ hoa, chạm đúp thì khoá hoa.

- **`⌨︎↓` thu nhỏ bàn phím** thành một tab có nhãn ở góc phải dưới. Chạm tab để mở lại.
- **Chỉ hiện với ô nhập nằm trên màn cảm ứng.** Ô ở màn chính thì anh gõ bằng bàn phím thật
  ngay trước mặt; dựng bàn phím ảo trên panel cho nó chỉ là nhiễu.
- Phím được gọi thẳng từ điểm chạm chứ không qua click giả, nên gõ không kéo con trỏ sang
  panel.

---

## Kiến trúc

Tách đôi có chủ đích, để phần logic kiểm chứng được mà không cần quyền hệ thống:

```
TouchwardCore/          ← hàm thuần, 96 unit test, `swift test` không cần quyền TCC
  TouchValueAssembler     ghép frame từ (usage, value) đã decode — không offset byte
  SlotTracker             trạng thái từng ngón cho report multitouch
  PalmFilter              ngưỡng theo dải thật của thiết bị, không theo hằng số
  CoordinateMapper        raw → toạ độ global, có calibration + clamp
  GestureRecognizer       state machine kiểu trackpad

touchward/              ← tầng hệ thống, không unit test được
  HIDTouchDevice          tìm thiết bị theo HID usage, đọc profile, yêu cầu multitouch
  EventSynthesizer        CGEvent có đóng dấu nguồn
  CursorReturn            trả con trỏ về, và tránh đường chuột thật
  DisplayRegistry         suy ra màn cảm ứng, hoặc báo lỗi rõ ràng
  TouchPipeline           dây nối: frame vào, sự kiện chuột ra
  Keyboard/               NSPanel không giành focus, theo dõi AX focus, bơm phím
```

## Không hardcode gì về thiết bị

Nguyên tắc: **hỏi thiết bị, đừng đoán.** Không có VID/PID, serial màn hình, số điểm chạm,
dải toạ độ hay offset byte nào ghi cứng trong code:

| Thứ cần biết | Lấy từ đâu |
|---|---|
| Thiết bị nào là màn cảm ứng | HID usage `Digitizer / Touch Screen` |
| Dải toạ độ X, Y | `IOHIDElementGetLogicalMax` của chính element X/Y |
| Số điểm chạm tối đa | Đếm element Tip Switch trong descriptor |
| Report ID để bật multitouch | Element Input Mode kiểu Feature |
| Giá trị này của ngón nào | Cookie của element, map về collection Finger của nó |
| Bố cục report | Không cần — IOKit decode sẵn, code chỉ đọc `(usage, value)` |
| Ngưỡng loại lòng bàn tay | Tỉ lệ trên dải thật của thiết bị |

Ngoại lệ duy nhất là màn hình: macOS không có API nối thiết bị USB với `CGDirectDisplayID`.
Nếu chỉ có đúng một màn phụ, app suy ra; nhiều hơn thì app **báo lỗi rõ ràng** thay vì đoán
bừa. Đặt `TOUCHWARD_DISPLAY_ID=<id>` để chỉ định thẳng.

## Không đụng vào thiết bị nhập thật

Đây là ràng buộc cứng, giữ bằng ba cơ chế:

1. **Chỉ seize đúng một thiết bị.** Chuột và bàn phím vật lý đi đường riêng, Touchward
   không hề chạm vào.
2. **Event tap chỉ quan sát.** `CursorReturn` dùng `.listenOnly` — không sửa, không nuốt sự
   kiện nào. Nó chỉ để biết anh có đang cầm chuột hay không.
3. **Mọi sự kiện tổng hợp đều đóng dấu.** Sự kiện của Touchward mang marker trong
   `eventSourceUserData`, nên phân biệt với chuột thật bằng dữ kiện chứ không phải suy đoán.

Cộng thêm `localEventsSuppressionInterval = 0`: thiếu dòng này thì mỗi lần trả con trỏ sẽ
chặn chuột vật lý 0,25 giây và chuột có cảm giác bị hỏng.

## An toàn khi thoát

Một cú kéo đang dở mà process chết sẽ để lại nút chuột trái **kẹt ở trạng thái nhấn trên
toàn hệ thống** — máy coi như hỏng cho tới khi anh click chuột thật. Bốn đường thoát đều
được bịt: `SIGINT`/`SIGTERM` (Ctrl-C), `applicationWillTerminate`, rút cáp USB
(`IOHIDManagerRegisterDeviceRemovalCallback`), và máy vào sleep. State machine còn có hạn 2
giây: luồng report chết giữa lúc kéo thì nút vẫn được nhả.

---

## Xử lý sự cố

Bắt đầu từ log — nó được viết để nói đúng chuyện đã xảy ra:

```bash
tail -f ~/Library/Logs/Touchward.log
```

| Dòng log | Nghĩa là |
|---|---|
| `Input Mode currently reads: 2` · `Multitouch enabled…` | Panel đã ở chế độ multitouch. Cuộn hai ngón sẽ chạy. |
| `The panel refused to switch to multitouch` | Controller vẫn ở mouse mode. Trỏ, chạm, kéo vẫn được; cuộn thì không. |
| `The panel is in mouse-compatibility mode` | Cùng ý đó, báo ngay lúc khởi động. |
| `Mapped 5 finger slots from the descriptor` | Đã tìm và map được các collection ngón. |
| `The panel reports 2 contacts` | Ngón thứ hai thật sự đã tới nơi. |
| `Could not seize the device` | macOS vẫn đang điều khiển con trỏ từ panel; sẽ có click ma. |
| `Waiting for a touchscreen` | Chưa có panel dùng được: chưa cắm, hoặc cắm rồi nhưng màn đang tắt. Mọi thứ liên quan cảm ứng đều tắt cho tới khi có. |
| `No usable touch display` | Panel biến mất giữa chừng. Cảm ứng và bàn phím tạm ngưng; thứ đang giữ đã được nhả. |
| `Touch display is back` | Panel trở lại, cảm ứng sống lại. |
| Nhiều màn phụ cùng lúc | Touchward không đoán màn nào là panel. Đặt `TOUCHWARD_DISPLAY_ID=<id>`. |

**Chạm mà không có gì xảy ra.** Kiểm tra Accessibility đã cấp chưa (dòng log đầu tiên nói
rõ). Rồi kiểm tra app có đang chạy không: `pgrep -fl Touchward`.

**Con trỏ nhảy sai chỗ.** Panel và màn hình bị lệch nhau — đối chiếu bounds của màn cảm ứng
trong log với cái panel anh đang chạm.

**Không cuộn được.** Tìm mấy dòng Input Mode ở trên. Nếu panel từ chối multitouch thì đó là
phần cứng, không phải code cử chỉ.

---

## Giới hạn đã biết

- **Ô mật khẩu không gõ được bằng bàn phím ảo.** Khi Secure Input bật, macOS chặn phím tổng
  hợp trên toàn hệ thống. Đó là thiết kế bảo mật, không có đường vòng. Touchward phát hiện
  và hiện chữ "dùng bàn phím thật" thay vì im lặng nuốt phím.
- **App có cây Accessibility kém** (Qt, Java, Flutter, game) sẽ không tự kích hoạt bàn phím.
  Electron/Chromium được xử lý bằng `AXManualAccessibility`.
- **Chưa có giao diện calibration.** `Calibration` đã có trong code và có test; còn thiếu
  màn chạm 4 góc để sinh ra hệ số.
- **Chưa có momentum scroll.** Cuộn hiện là 1:1 theo ngón.
- **Tầng hệ thống chưa có test.** `EventSynthesizer`, `CursorReturn`, `HIDTouchDevice` gắn
  cứng vào `CGEventSource`, đồng hồ và IOKit nên chưa có chỗ chèn test. Muốn kiểm chứng bất
  biến "mọi `leftMouseDown` đều có `leftMouseUp` tương ứng" thì cần tách một protocol
  `PointerSink` — đáng làm nếu code này sống lâu.

## Nghiệm thu tay

Những thứ không tự động hoá được vì phụ thuộc phần cứng và TCC:

- [ ] Chạm góc trên-trái màn cảm ứng → con trỏ nhảy đúng góc đó, không phải màn chính
- [ ] Chạm 4 góc → không lệch quá vài mm
- [ ] Giữ 1 giây → menu chuột phải hiện ra tại điểm chạm
- [ ] Hai ngón kéo trong trình duyệt → trang cuộn, đúng chiều
- [ ] Ba ngón xoè ra trong trình duyệt → trang phóng to; chụm vào → thu nhỏ
- [ ] Ba ngón trượt ngang mà không xoè → không phóng, cũng không cuộn
- [ ] Kéo một ngón qua đoạn văn bản → bôi chọn được
- [ ] Nhấc tay, đợi 1 giây → con trỏ về màn chính
- [ ] **Đang rê chuột thật thì chạm màn cảm ứng → chuột không khựng, không bị cướp**
- [ ] Gõ bàn phím vật lý khi bàn phím ảo đang hiện → chữ vẫn vào đúng app
- [ ] Chạm ô tìm kiếm trong Safari trên panel → bàn phím ảo hiện và gõ ra chữ
- [ ] Focus vào ô nhập ở màn **chính** → bàn phím ảo **không** hiện
- [ ] Chạm `⌨︎↓` → bàn phím thu thành tab; chạm tab → mở lại
- [ ] Chạm ô mật khẩu → bàn phím ảo hiện cảnh báo thay vì gõ hụt
- [ ] **Ctrl-C giữa lúc đang kéo → nút chuột không kẹt** (thử: kéo, giữ nguyên tay, Ctrl-C)
- [ ] Rút cáp USB giữa lúc đang kéo → nút chuột không kẹt

---

## Tài liệu

- [`docs/plan.vi.html`](docs/plan.vi.html) — bản thiết kế ban đầu, tiếng Việt, viết trước
  khi code và giữ lại làm tư liệu. Một số chỗ đã bị thực tế phần cứng phủ nhận.
