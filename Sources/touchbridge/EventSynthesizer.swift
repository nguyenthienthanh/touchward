import CoreGraphics
import Foundation
import TouchBridgeCore

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
            post(.leftMouseDown, at: p, button: .left)

        case .dragMoved(let p):
            post(.leftMouseDragged, at: p, button: .left)

        case .dragEnded(let p):
            post(.leftMouseUp, at: p, button: .left)

        case .scroll(let dx, let dy, _):
            postScroll(dx: dx, dy: dy)

        case .sessionEnded:
            break  // CursorReturn owns this
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
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

    /// Belt and braces for quit paths: release the left button wherever the cursor is.
    func releaseLeftButtonIfHeld(at point: CGPoint) {
        post(.leftMouseUp, at: point, button: .left)
    }
}
