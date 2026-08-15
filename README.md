# Touchward

**English** · [🇻🇳 Tiếng Việt](README.vi.md)

[![release](https://img.shields.io/github/v/release/nguyenthienthanh/touchward)](https://github.com/nguyenthienthanh/touchward/releases/latest)
[![npm](https://img.shields.io/npm/v/touchward)](https://www.npmjs.com/package/touchward)
[![Homebrew](https://img.shields.io/badge/homebrew-nguyenthienthanh%2Ftap-orange)](https://github.com/nguyenthienthanh/homebrew-tap)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black)](#requirements)
[![license](https://img.shields.io/github/license/nguyenthienthanh/touchward)](LICENSE)

Turns a USB touchscreen into an **absolute** pointing device on macOS.

macOS has no driver that translates HID digitizer coordinates into a pointer position. On a
dual-mode panel — the kind built around an SiS controller — the only thing that reaches the
WindowServer is the Button 1 bit: a click with no coordinates, which lands wherever the
cursor already was. Touchward seizes the device, reads the real coordinates, and posts its
own mouse events at the point you actually touched.

Entirely user-space: **no kernel extension, no SIP changes.**

---

## Features

### The touch panel becomes a real pointing device

- **Absolute pointing.** The cursor goes exactly where your finger lands, rather than
  drifting from wherever it happened to be. Tap to click, hold for a right click.
- **One-finger drag** selects text and moves things, the same as holding a mouse button.
- **Two-finger scroll**, both axes, delivered to the window under your fingers rather than
  to whatever had the cursor.
- **Three-finger spread and pinch to zoom.** Two fingers were already scrolling, so zoom
  takes the gesture nothing else claims.
- **The cursor comes home.** Half a second after you lift your hand, the pointer returns to
  the middle of your main display, so the mouse is where you expect it next time.

### An on-screen keyboard that stays out of the way

- **iPadOS layout**, so muscle memory transfers: delete ends the top row, return ends the
  home row, shift sits at both ends of the bottom letter row, `.?123` / `#+=` switch planes
  from the corners. Tap shift for one capital, double-tap to lock it.
- **Only for fields on the touchscreen.** A text field on your main display is typed into
  with the real keyboard already in front of it.
- **`⌨︎↓` shrinks it to a tab** in the corner, and the tab taps back to full size.
- **It says when macOS is blocking it.** Synthetic keystrokes are refused system-wide while
  Secure Input is on, so instead of swallowing keys the keyboard tells you to use the
  physical one.
- **Typing never moves the pointer.** Keys are driven from the touch point directly, not by
  synthesising a click on the panel.

### It keeps its hands to itself

- **Your real mouse and keyboard are untouched.** Exactly one device is seized, the event
  tap only listens, and every synthetic event is stamped so it is never confused with the
  real thing. See [Hands off the real input devices](#hands-off-the-real-input-devices).
- **No kernel extension, no SIP changes, no login item.** One user-space app, one
  permission.
- **Nothing about the hardware is hardcoded.** Coordinate ranges, contact count and finger
  layout all come from the device's own descriptor, so a panel this code has never seen
  works without anyone editing a constant. See
  [Nothing about the device is hardcoded](#nothing-about-the-device-is-hardcoded).
- **A drag can never leave a button stuck.** Ctrl-C, quit, sleep and USB unplug all release
  what is held, and a dead report stream is caught by a 2-second backstop.
- **It says what it is doing.** One log file records which display it picked, what the panel
  reported, and why the keyboard did or did not come up.

---

## Tested hardware

Everything below was read off the running machine, not copied from a datasheet.

### Touchscreen

| | |
|---|---|
| Monitor | **VSP VP1560FST1** — 15.6" portable touch monitor, 1920×1080 IPS, 60 Hz |
| Where to buy | [FPT Shop](https://fptshop.com.vn/man-hinh/vsp-vp1560fst1156-inch-full-hd-ips-60-hz) · [TMINS](https://tmins.vn/products/man-hinh-di-dong-vsp-vp1560fst1-15-6-inch-fhd-60hz-5ms-ips-cam-ung) |
| Connection | USB-C (touch + video), reported to macOS as display 1920×1080 |

### Touch controller — the part that matters for other monitors

This is the chip, not the monitor. **Any panel built on the same controller should behave
identically**, whatever badge is on the bezel — and SiS controllers are extremely common in
white-label portable touch monitors.

| | |
|---|---|
| Controller | **SiS HID Touch Controller** — Silicon Integrated Systems Corp. ([vendor 0x0457](https://devicehunt.com/view/type/usb/vendor/0457)) |
| USB IDs | VID `0x0457` (1111), PID `0x0819` (2073), device release `0x0200` |
| Transport | USB HID |
| Logical range | 4095 × 4095 |
| Contacts | 5 |
| Digitizer input report | ID `0x91` — five Finger collections (Tip Switch, Confidence, Contact Id, X, Y, Width, Height) plus Contact Count and Scan Time |
| Mouse-compatibility report | ID `0x03` — X/Y on the Generic Desktop page plus Button 1 |
| Device Configuration | Usage `0x0D:0x0E`, feature report ID `7`, holding Input Mode (`0x52`) and Device Index (`0x53`) |

Out of the box this controller sits in **mouse-compatibility mode** and reports a single
contact, which is why two-finger scrolling is impossible until Input Mode is switched to
`2`. Touchward does that at startup and then **reads the value back** to confirm the panel
actually obeyed — see [Troubleshooting](#troubleshooting).

If your panel uses a different controller it may still work: nothing in the code is keyed
to these IDs. Matching is by HID usage (`Digitizer / Touch Screen`), ranges come from the
descriptor, and the finger slots are mapped from the collections the device declares.
Reports of other hardware — working or not — are welcome.

### Host

| | |
|---|---|
| macOS | **26.5.2** (build 25F84) |
| Mac | Apple M1 Max |
| Toolchain | Swift 6.0.3 / Xcode command line tools |
| Minimum target | macOS 13 (declared in `Package.swift`; only tested on 26.5.2) |
| Layout when tested | Touch panel 1920×1080 placed to the left of a 2560×1440 main display |

---

## Requirements

- macOS 13 or newer (tested on 26.5.2).
- Xcode command line tools: `xcode-select --install`.
- A touchscreen that declares itself a HID `Digitizer / Touch Screen`, connected and
  showing a picture — macOS must already see it as a display.
- Exactly one secondary display, or `TOUCHWARD_DISPLAY_ID` set. Touchward refuses to guess
  which screen is the touch panel when several could be.

Touchward is safe to leave running with nothing plugged in. **Every touch behaviour is off
until the panel is connected *and* switched on** — a monitor in standby usually keeps its
USB side powered, so the digitizer goes on reporting contacts for a screen nobody can see,
and acting on those would move the cursor somewhere you cannot follow it. The app waits,
says so in the log, and comes up by itself when the panel does.

---

## Install

Three ways to the same signed `.app`. Pick whichever you already have to hand — or
[build it yourself](#build-and-run).

### Disk image

[**Download Touchward 1.0.0**](https://github.com/nguyenthienthanh/touchward/releases/latest)
→ open the `.dmg` → drag **Touchward** into Applications.

### Homebrew

```bash
brew install --cask nguyenthienthanh/tap/touchward
```

### npm

```bash
npx touchward install
```

The npm package is an *installer*, not the app: it fetches the disk image from the release
above, checks it against a pinned checksum, and copies the bundle into `/Applications`.
Installing is an explicit command rather than a `postinstall` hook, because dropping an app
into `/Applications` as a side effect of `npm install` is not something a package should do
behind your back. `npx touchward uninstall` takes it back out.

### Then grant the one permission

However you installed it, Touchward does nothing until you enable it under
**System Settings → Privacy & Security → Accessibility**. That single grant also covers
reading the touch panel, so Touchward will **not** appear under Input Monitoring — that is
expected, and [explained below](#permissions).

The app is signed with a self-signed certificate, so Gatekeeper asks for confirmation the
first time you open it.

---

## Build and run

Four commands, in order. Run them from the repository root.

### 1. Create the local signing certificate (once per machine)

```bash
bash scripts/make-signing-cert.sh
```

macOS remembers permission grants against an app's *signature*. With an ad-hoc signature
that includes the binary's hash, so every rebuild looks like a brand new app and you have
to grant Accessibility again. A stable self-signed certificate keeps the identity constant.
It is created in your login keychain and used for nothing else.

### 2. Build the app bundle

```bash
bash scripts/build-app.sh          # release; pass `debug` for a debug build
```

Produces `Artifacts/Touchward.app`, icon drawn and signature applied. The bundle is not
packaging polish: a bare binary from `swift run` cannot hold a TCC permission.

### 3. Install it

```bash
bash scripts/install.sh
```

Copies the app to `/Applications`. That path matters — TCC keys grants to the location as
well as the signature, so an app that moves later has to be granted permission all over
again.

### 4. Run it

```bash
open -a Touchward
```

Touchward is an accessory app: no Dock icon, no window. Watch what it is doing with:

```bash
tail -f ~/Library/Logs/Touchward.log
```

To quit: `pkill -f Touchward`.

### Optional: a distributable disk image

```bash
bash scripts/make-dmg.sh           # Artifacts/Touchward-1.0.0.dmg
```

### Running the tests

```bash
swift test                         # 96 tests, no permissions required
```

`TouchwardCore` is pure logic with no IOKit and no AppKit, precisely so the parsing,
gesture and mapping rules can be verified without any system grants.

---

## Permissions

On first run macOS asks for **Accessibility**. Grant it and Touchward carries on by itself.
If no dialog appears, enable it by hand:

**System Settings → Privacy & Security → Accessibility → Touchward**

| Permission | What it is used for |
|---|---|
| **Accessibility** | Moving the pointer, typing, reading which UI element has focus — **and reading the touchscreen** |

> Only that **one** permission is needed. It also covers input monitoring, so Touchward
> will **not appear** in the Input Monitoring list. That is expected — do not go hunting
> for a checkbox that will never be there.

If Input Monitoring was denied at some point, macOS will not ask again. Clear the state
and reopen the app:

```bash
tccutil reset All com.ethannguyen.touchward
```

---

## Gestures

| Action | Result |
|---|---|
| Quick tap | Left click at the touched point |
| Hold > 0.6 s | Right click |
| One finger, drag | Drag — selects text, moves things |
| Two fingers, drag | Scroll, both axes |
| Three fingers, spread or pinch | Zoom in / out |
| Two fingers, quick tap | Right click |
| Touch a text field on the panel | On-screen keyboard appears on the touch panel |
| Lift every finger | After ~0.5 s the cursor returns to the main display |

Scrolling inverted for you? Flip `contentFollowsFinger` in `EventSynthesizer.swift` — that
is the only place polarity is decided.

**Zoom is three fingers, not two,** because two fingers are already scrolling. Each ~10% of
opening or closing sends one Command + `=` / Command + `-`, which is what View ▸ Zoom In /
Zoom Out is bound to in nearly every Mac app. There is no public API for a real
magnification gesture; Command + scroll would aim at the window under your fingers, but in
an app that does not implement it the zoom would scroll the document instead. A zoom
keystroke an app does not implement does nothing at all. The trade-off: **zoom goes to the
focused app**, so tap the window first if it is not already frontmost.

## On-screen keyboard

Laid out the way iPadOS lays it out, so muscle memory transfers: delete ends the top row,
return ends the home row, shift sits at both ends of the bottom letter row, and `.?123` /
`#+=` switch planes from the corners. Tap shift for one capital, double-tap to lock it.

- **`⌨︎↓` shrinks it** to a small labelled tab in the bottom-right corner. Tap the tab to
  bring it back.
- **It only appears for text fields that are on the touchscreen.** A field on your main
  display is typed into with the real keyboard in front of it; putting a keyboard on the
  panel for it is noise.
- Keys are driven straight from the touch point rather than by a synthetic click, so typing
  never drags the pointer onto the panel.

---

## Architecture

Split deliberately, so the logic is verifiable without system permissions:

```
TouchwardCore/          ← pure functions, 96 unit tests, `swift test` needs no TCC grants
  TouchValueAssembler     builds frames from decoded (usage, value) pairs — no byte offsets
  SlotTracker             per-finger state for multitouch reports
  PalmFilter              threshold scaled to the device's own range, not a constant
  CoordinateMapper        raw → global coordinates, with calibration and clamping
  GestureRecognizer       trackpad-shaped state machine

touchward/              ← system layer, not unit-testable
  HIDTouchDevice          finds the device by HID usage, reads its profile, asks for multitouch
  EventSynthesizer        CGEvents stamped with a source marker
  CursorReturn            sends the cursor home, and stays out of the real mouse's way
  DisplayRegistry         works out which display is the touchscreen, or fails loudly
  TouchPipeline           the wiring: frames in, pointer events out
  Keyboard/               non-activating NSPanel, AX focus watching, key injection
```

## Nothing about the device is hardcoded

The rule is **ask the device, do not guess**. No vendor ID, product ID, monitor serial,
contact count, coordinate range or byte offset is written into the code:

| What is needed | Where it comes from |
|---|---|
| Which device is the touchscreen | HID usage `Digitizer / Touch Screen` |
| X and Y range | `IOHIDElementGetLogicalMax` on the actual X/Y elements |
| Maximum contacts | Counting Tip Switch elements in the descriptor |
| Report ID for enabling multitouch | The Input Mode element of type Feature |
| Which finger a value belongs to | The element's cookie, mapped to its Finger collection |
| Report layout | Not needed — IOKit decodes it; the code reads `(usage, value)` |
| Palm rejection threshold | A fraction of the device's own declared range |

The one exception is the display: macOS offers no API linking a USB device to a
`CGDirectDisplayID`. With exactly one secondary display Touchward infers it; with more it
**says so and stops** rather than guessing. Set `TOUCHWARD_DISPLAY_ID=<id>` to be explicit.

## Hands off the real input devices

A hard constraint, held by three mechanisms:

1. **Exactly one device is seized.** Your physical mouse and keyboard travel their own path
   and Touchward never touches it.
2. **The event tap only listens.** `CursorReturn` uses `.listenOnly` — it modifies nothing
   and swallows nothing. It exists solely to notice that you have picked up the mouse.
3. **Every synthetic event is stamped.** Touchward's events carry a marker in
   `eventSourceUserData`, so its own events are told apart from the real mouse by fact
   rather than by inference.

Plus `localEventsSuppressionInterval = 0`: without it, every cursor return would freeze the
physical mouse for 0.25 s and the mouse would feel broken.

## Safe exit

A drag in flight when the process dies would leave the left mouse button **logically held
down across the whole system** — the machine feels broken until you click a real mouse. All
four exits are covered: `SIGINT`/`SIGTERM` (Ctrl-C), `applicationWillTerminate`, USB unplug
(`IOHIDManagerRegisterDeviceRemovalCallback`), and sleep. The state machine also has a
2-second backstop: if the report stream dies mid-drag, the button is released anyway.

---

## Troubleshooting

Start with the log — it is written to say what actually happened:

```bash
tail -f ~/Library/Logs/Touchward.log
```

| Line | Meaning |
|---|---|
| `Input Mode currently reads: 2` · `Multitouch enabled…` | The panel is in multitouch. Two-finger scrolling will work. |
| `The panel refused to switch to multitouch` | The controller stayed in mouse mode. Pointing, tapping and dragging work; scrolling cannot. |
| `The panel is in mouse-compatibility mode` | Same thing, stated at startup. |
| `Mapped 5 finger slots from the descriptor` | Finger collections were found and mapped. |
| `The panel reports 2 contacts` | A second finger genuinely arrived. |
| `Could not seize the device` | macOS is still driving the pointer from the panel too; expect phantom clicks. |
| `Waiting for a touchscreen` | No usable panel: not connected, or connected with its monitor switched off. Everything touch-related stays off until one appears. |
| `No usable touch display` | The panel went away while running. Touch input and the keyboard are suspended; anything held down was released. |
| `Touch display is back` | It reappeared and touch input is live again. |
| Several secondary displays attached | Touchward will not guess which is the panel. Set `TOUCHWARD_DISPLAY_ID=<id>`. |

**Touching the panel does nothing.** Check Accessibility is granted (the first log line
says). Then check the app is running at all: `pgrep -fl Touchward`.

**The cursor jumps to the wrong place.** The panel and the display are mismatched — verify
the touch display bounds in the log against the panel you are touching.

**Nothing scrolls.** Look for the Input Mode lines above. If the panel refused multitouch,
that is the hardware, not the gesture code.

---

## Known limitations

- **Password fields cannot be typed into with the on-screen keyboard.** macOS blocks
  synthetic keystrokes system-wide while Secure Input is on. That is a security design, and
  there is no way around it. Touchward detects it and says "use the physical keyboard"
  instead of silently swallowing keys.
- **Apps with a poor Accessibility tree** (Qt, Java, Flutter, games) will not raise the
  keyboard automatically. Electron/Chromium is handled via `AXManualAccessibility`.
- **No calibration UI yet.** `Calibration` exists in the code and is tested; what is missing
  is a four-corner screen to produce the coefficients.
- **No momentum scrolling.** Scrolling is 1:1 with the finger.
- **The system layer has no tests.** `EventSynthesizer`, `CursorReturn` and `HIDTouchDevice`
  bind directly to `CGEventSource`, the clock and IOKit, so there is no seam to test
  through. Verifying the invariant "every `leftMouseDown` has a matching `leftMouseUp`"
  would need a `PointerSink` protocol — worth doing if this code lives long.

## Manual acceptance

Things that cannot be automated because they depend on hardware and TCC:

- [ ] Touch the top-left corner of the panel → the cursor lands there, not on the main display
- [ ] Touch all four corners → off by no more than a few millimetres
- [ ] Hold for one second → the context menu opens at the touched point
- [ ] Two-finger drag in a browser → the page scrolls, in the right direction
- [ ] Three fingers spread in a browser → the page zooms in; pinch → out
- [ ] Three fingers slid across the panel without opening → nothing zooms and nothing scrolls
- [ ] One-finger drag across a paragraph → text is selected
- [ ] Lift your hand, wait a second → the cursor returns to the main display
- [ ] **Touch the panel while moving the real mouse → the mouse does not stutter or get hijacked**
- [ ] Type on the physical keyboard while the on-screen keyboard is up → text still goes to the right app
- [ ] Touch a search field in Safari on the panel → the keyboard appears and types
- [ ] Focus a text field on the *main* display → the keyboard does **not** appear
- [ ] Tap `⌨︎↓` → the keyboard shrinks to a tab; tap the tab → it comes back
- [ ] Touch a password field → the keyboard shows the warning instead of typing nothing
- [ ] **Ctrl-C mid-drag → the mouse button is not stuck** (drag, keep your finger down, Ctrl-C)
- [ ] Unplug the USB cable mid-drag → the mouse button is not stuck

---

## Documents

- [`docs/plan.vi.html`](docs/plan.vi.html) — the original design note, in Vietnamese,
  written before implementation and kept for the record. Some of it is superseded by what
  the hardware turned out to actually do.
