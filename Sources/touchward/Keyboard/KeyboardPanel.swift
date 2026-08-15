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

    /// The screen the keyboard was last shown on, so minimising and restoring do not have
    /// to resolve the display again — and cannot land the panel on the wrong one.
    private var host: NSScreen?
    private(set) var isMinimized = false

    /// Places the keyboard along the bottom of a specific screen and shows it without
    /// activating this app.
    func present(on screen: NSScreen, heightFraction: CGFloat = 0.42) {
        host = screen
        self.heightFraction = heightFraction
        applyGeometry()
        orderFrontRegardless()
    }

    private var heightFraction: CGFloat = 0.42

    /// Shrinks the keyboard to a small tab, or brings it back. The tab is deliberately left
    /// on screen rather than hidden: a keyboard that vanished with no way back would strand
    /// the user on a machine whose physical keyboard may be out of reach.
    func setMinimized(_ minimized: Bool) {
        isMinimized = minimized
        applyGeometry()
        orderFrontRegardless()
    }

    private func applyGeometry() {
        guard let screen = host else { return }
        let frame = screen.frame

        if isMinimized {
            let size = NSSize(width: 190, height: 58)
            let margin: CGFloat = 18
            setFrame(NSRect(x: frame.maxX - size.width - margin,
                            y: frame.minY + margin,
                            width: size.width, height: size.height),
                     display: true)
        } else {
            let height = (frame.height * heightFraction).rounded()
            setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: height),
                     display: true)
        }
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
