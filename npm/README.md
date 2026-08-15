# touchward

Installer for **Touchward** — turns a USB touchscreen into an **absolute** pointing device on macOS.

```bash
npx touchward install
```

> **This package is an installer, not the app.** Touchward is written in Swift and ships as a
> signed `.app`. npm is one way to fetch and place it — it downloads the disk image from GitHub
> Releases, checks it against a checksum pinned in this package, and copies the bundle into
> `/Applications`. Nothing runs on Node.
>
> If you would rather not go through npm:
> `brew install --cask nguyenthienthanh/tap/touchward`, or grab the
> [disk image](https://github.com/nguyenthienthanh/touchward/releases/latest) directly.

## What Touchward does

macOS has no driver that translates HID digitizer coordinates into a pointer position. On a
dual-mode panel the only thing that reaches the WindowServer is the Button 1 bit — a click with
no coordinates, which lands wherever the cursor already was. Touchward seizes the device, reads
the real coordinates, and posts its own mouse events at the point you actually touched.

Entirely user-space: no kernel extension, no SIP changes.

| | |
|---|---|
| Point, tap, drag | One finger, absolute — the cursor goes where you touch |
| Scroll | Two fingers, both axes |
| Zoom | Three fingers, spread or pinch |
| Type | An on-screen keyboard, iPad layout, on the touch panel itself |
| Your real mouse and keyboard | Never touched |

## Commands

```bash
npx touchward install      # download, verify the checksum, install into /Applications
npx touchward uninstall    # remove /Applications/Touchward.app
npx touchward version      # the app version this package installs
```

Installing is an explicit command rather than a `postinstall` hook on purpose — dropping an app
into `/Applications` as a side effect of `npm install` is not something a package should do
behind your back.

## After installing

Touchward needs exactly one permission:

**System Settings → Privacy & Security → Accessibility → enable Touchward**

That also covers reading the touch panel, so Touchward will **not** appear under Input
Monitoring. That is expected — do not go looking for a checkbox there.

Then `open -a Touchward`.

## Requirements

- macOS 13 or newer (developed and tested on 26.5.2, Apple silicon).
- A touchscreen that declares itself a HID `Digitizer / Touch Screen`, connected and displaying.
- Exactly one secondary display, or `TOUCHWARD_DISPLAY_ID` set — Touchward refuses to guess
  which screen is the panel rather than sending your cursor somewhere you cannot follow it.

The app is signed with a self-signed certificate, so Gatekeeper asks for confirmation on first
launch.

## Source, issues, docs

[github.com/nguyenthienthanh/touchward](https://github.com/nguyenthienthanh/touchward) — Swift,
Apache-2.0, 96 unit tests. Nothing about the device is hardcoded: no VID/PID, no serial, no byte
offsets; everything is read from the HID descriptor at runtime.
