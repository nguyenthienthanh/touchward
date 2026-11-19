# Contributing to Touchward

Thanks for helping. Touchward is a small macOS user-space tool (Swift) that turns a USB touchscreen into an absolute pointing device. The maintainer is Ethan Nguyen.

## Setup

- macOS 13 or newer, Xcode command line tools (`xcode-select --install`).
- No third-party dependencies; Swift Package Manager only.

```bash
swift build                 # compile
swift test                  # unit tests, no system permissions required
```

For the full app build, signing certificate, install and run steps, follow "Build and run" in the [README](README.md) (`scripts/make-signing-cert.sh`, `scripts/build-app.sh`, `scripts/install.sh`, optional `scripts/make-dmg.sh`).

## Where code goes

- `Sources/TouchwardCore`: pure logic (HID report parsing, gesture and mapping rules). No IOKit, no AppKit. Anything that can be tested without a system grant belongs here, with a test in `Tests/TouchwardCoreTests`.
- `Sources/touchward` is the executable: it talks to IOKit/AppKit and the display; keep it thin.
- Do not hardcode device identifiers. Behaviour must be derived from what the device reports (see "Nothing about the device is hardcoded" in the README).
- Safety first: touch behaviour stays off until the panel is connected and on, and the app must exit cleanly and never leave a real input device seized.

## Before you open a PR or commit

- `swift test` passes and covers the change.
- User-facing behaviour changes update `README.md` and `README.vi.md` together.
- Hardware claims (tested panels, controllers) come from a real run, not assumption; say which hardware you used.

## Secrets and signing

Never commit signing identities, certificates, keychain exports, tokens or `.env*` files. The signing certificate is created locally per machine by `scripts/make-signing-cert.sh`. Maintainer check before pushing:

```bash
~/Projects/Personal/workspace/bin/secrets-scan.sh ~/Projects/Personal/touchward
```

## Commits

The maintainer commits small changes to `main`; contributors open a PR from a branch. Message style: `type(scope): what and why`. Use `git pull --rebase --autostash` if a push is rejected.
