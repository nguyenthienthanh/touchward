import AppKit

/// A keyboard that must never take focus: the app it types into has to keep its caret.
///
/// `canBecomeKey` is overridden rather than relying on `becomesKeyOnlyIfNeeded`, because
/// a focusable control inside the panel can still promote it to key status otherwise.
final class KeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        // The style mask has a WindowServer-side counterpart that `setStyleMask` does not
        // re-sync, so .nonactivatingPanel must be set here and never mutated afterwards.
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false          // panels hide by default; ours must persist
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    /// Places the keyboard along the bottom of a specific screen and shows it without
    /// activating this app.
    func present(on screen: NSScreen, heightFraction: CGFloat = 0.42) {
        let frame = screen.frame
        let height = (frame.height * heightFraction).rounded()
        setFrame(
            NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: height),
            display: true
        )
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}

extension NSWindow {
    /// Frame in the global, top-left-origin space that CGEvent and CGDisplayBounds use.
    /// `NSWindow.frame` is bottom-left-origin with Y increasing upward, so comparing it
    /// against a mapped touch point directly would test the wrong half of the screen.
    var cgFrame: CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        return CGRect(x: frame.minX,
                      y: primary.frame.maxY - frame.maxY,
                      width: frame.width,
                      height: frame.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Never use `NSScreen.main` for this — that is the screen holding the key window,
    /// not the display we want to pin the keyboard to.
    static func matching(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}
