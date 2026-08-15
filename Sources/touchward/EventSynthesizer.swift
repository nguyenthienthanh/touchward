import CoreGraphics
import Foundation
import TouchwardCore

/// Posts synthetic pointer events on behalf of the touchscreen.
///
/// Every event carries a marker in the source's user data so the rest of the app can
/// tell its own events apart from the physical mouse without touching the real input
/// path. We only ever inject; we never modify or swallow the user's own events.
final class EventSynthesizer {
    /// Arbitrary constant. Any observer can read it back from `.eventSourceUserData`.
    static let marker: Int64 = 0x5A_17C4

    private let source: CGEventSource

    /// True when the finger's motion should carry the content with it, matching how a
    /// phone behaves. Flip this if scrolling feels inverted on your setup — it is the
    /// only place polarity is decided.
    var contentFollowsFinger = true

    init?() {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = EventSynthesizer.marker

        // Without this, every warp freezes the physical mouse for 0.25s. That would make
        // the real mouse feel broken each time the cursor returns to the main display.
        source.localEventsSuppressionInterval = 0

        self.source = source
    }

    func apply(_ event: GestureEvent) {
        switch event {
        case .leftClick(let p):
            post(.leftMouseDown, at: p, button: .left)
            post(.leftMouseUp, at: p, button: .left)

        case .rightClick(let p):
            post(.rightMouseDown, at: p, button: .right)
            post(.rightMouseUp, at: p, button: .right)

        case .dragBegan(let p):
            pressLeft(at: p)

        case .dragMoved(let p):
            post(.leftMouseDragged, at: p, button: .left)

        case .dragEnded(let p):
            releaseLeft(at: p)

        case .scroll(let dx, let dy, let centre):
            // A scroll wheel event carries no location: macOS delivers it to whatever sits
            // under the *pointer*. Two fingers never moved the pointer, so every scroll was
            // being delivered to whatever window the cursor happened to be resting on —
            // usually on the other display, which reads as "scrolling does nothing".
            moveCursor(to: centre)
            postScroll(dx: dx, dy: dy)

        case .pinch(let scale, let centre):
            moveCursor(to: centre)
            postZoom(scale: scale)

        case .sessionEnded:
            // Carrying a remainder into an unrelated later gesture can emit a step in the
            // wrong direction on its first frame.
            residualX = 0
            residualY = 0
            zoomResidual = 0
            // The cursor is about to be warped home by CursorReturn, so a remembered
            // position from this session would suppress a needed move in the next one.
            lastCursorPoint = nil
        }
    }

    /// How far the hand must open before one zoom step is sent, as a ratio. Each step is a
    /// Command + `=` or Command + `-`, which is what View ▸ Zoom In / Zoom Out is bound to
    /// in nearly every Mac app.
    ///
    /// There is no public CGEvent for a magnification gesture, so the choice is between
    /// this and Command + scroll. Command + scroll is aimed at the window under the pointer,
    /// which sounds better until an app that does not implement it scrolls the document
    /// instead: the zoom gesture would move the page. A zoom keystroke an app does not
    /// implement does nothing at all, which is the failure worth having.
    private let zoomStep: CGFloat = 1.10

    /// Ratios multiply, so they are accumulated in log space: two frames of 1.05 make one
    /// step, and no single frame has to be large enough to trigger on its own.
    private var zoomResidual: CGFloat = 0

    private func postZoom(scale: CGFloat) {
        guard scale > 0, scale.isFinite else { return }

        zoomResidual += CoreGraphics.log(scale)
        let threshold = CoreGraphics.log(zoomStep)
        guard threshold > 0, abs(zoomResidual) >= threshold else { return }

        // A fast spread can cross several steps in one frame; send them all, or a quick
        // gesture would be quietly clipped to a single step.
        let steps = Int((abs(zoomResidual) / threshold).rounded(.towardZero))
        let zoomingIn = zoomResidual > 0
        zoomResidual -= CGFloat(steps) * threshold * (zoomingIn ? 1 : -1)

        for _ in 0..<min(steps, 8) {
            postKey(zoomingIn ? Self.equalsKey : Self.minusKey, flags: .maskCommand)
        }
    }

    /// ANSI key codes. Command + `=` rather than Command + `+`: the shift needed to reach
    /// `+` changes what the app sees, and Zoom In is bound to the unshifted key.
    private static let equalsKey: CGKeyCode = 24
    private static let minusKey: CGKeyCode = 27

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        down.flags = flags
        down.post(tap: .cghidEventTap)
        // Modifiers cleared on the way up, or the target app can be left holding Command.
        up.flags = []
        up.post(tap: .cghidEventTap)
    }

    /// Direct press/release, bypassing gesture classification. The on-screen keyboard uses
    /// these: a key must go down the instant a finger lands and up when it leaves, with no
    /// tap-duration or movement test in between.
    func pressLeft(at point: CGPoint) {
        post(.leftMouseDown, at: point, button: .left)
    }

    func releaseLeft(at point: CGPoint) {
        post(.leftMouseUp, at: point, button: .left)
    }

    /// Parks the pointer without pressing anything, so a location-less event (the scroll
    /// wheel) is routed to the window the fingers are actually on.
    private var lastCursorPoint: CGPoint?

    private func moveCursor(to point: CGPoint) {
        guard lastCursorPoint != point else { return }
        lastCursorPoint = point
        post(.mouseMoved, at: point, button: .left)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        // Apps that gate on clickCount >= 1 (custom text views, web content) ignore a
        // click that arrives with 0.
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        default:
            break
        }
        event.post(tap: .cghidEventTap)
    }

    /// Scroll wheel deltas are integers, but a slow two-finger drag produces sub-pixel
    /// movement per frame. Rounding each frame independently would floor every one of them
    /// to zero and the page would simply not move. Carry the remainder instead.
    private var residualX: CGFloat = 0
    private var residualY: CGFloat = 0

    private func postScroll(dx: CGFloat, dy: CGFloat) {
        residualX += dx
        residualY += dy

        // A degenerate display rect can produce NaN, and Int32(NaN) traps — a crash here
        // would abort the process while a mouse button may be held down.
        guard residualX.isFinite, residualY.isFinite else {
            residualX = 0
            residualY = 0
            return
        }

        let stepX = residualX.rounded(.towardZero)
        let stepY = residualY.rounded(.towardZero)
        guard stepX != 0 || stepY != 0 else { return }

        residualX -= stepX
        residualY -= stepY

        let sign: Int32 = contentFollowsFinger ? 1 : -1
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: sign * Int32(stepY),
                                  wheel2: sign * Int32(stepX),
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

}
