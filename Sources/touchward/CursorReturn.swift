import CoreGraphics
import Foundation

/// Sends the pointer home to the main display once the user is done touching.
///
/// The hard requirement is that this never fights the physical mouse. Two guards do
/// that: a listen-only event tap that notices real mouse motion (any event whose source
/// is not ours), and a quiet period after the last touch. If the user grabs the mouse
/// during that window, the return is cancelled outright.
final class CursorReturn {
    /// How long after the last touch to wait before returning the cursor.
    var quietPeriod: TimeInterval = 0.5
    /// Real mouse activity newer than this cancels a pending return.
    var mouseGrace: TimeInterval = 1.0

    private var lastRealMouseActivity: TimeInterval = 0
    private var pendingWorkItem: DispatchWorkItem?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The warp generates its own unmarked mouseMoved, which would otherwise read as the
    /// user grabbing the mouse. A flag cleared via async is useless here: that drains in
    /// microseconds while the event round-trips the WindowServer in milliseconds. Use a
    /// time window wide enough to cover the round trip.
    private var ignoreRealMouseUntil: TimeInterval = 0
    private let warpEchoWindow: TimeInterval = 0.15
    private var hasStopped = false

    /// Installs the passive observer. Listen-only: it never modifies or drops an event.
    func startObservingRealMouse() -> Bool {
        // Dragged events matter as much as moves: a real mouse drag lasting longer than
        // mouseGrace would otherwise look like idleness and let the cursor warp away
        // mid-gesture.
        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<CursorReturn>.fromOpaque(refcon).takeUnretainedValue()

            // macOS disables a tap that is slow or when the user changes input settings.
            // Without re-enabling, the only guard protecting the physical mouse silently
            // dies and the cursor starts warping out from under the user's hand.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                me.reEnable()
                return Unmanaged.passUnretained(event)
            }

            if Date().timeIntervalSinceReferenceDate > me.ignoreRealMouseUntil,
               event.getIntegerValueField(.eventSourceUserData) != EventSynthesizer.marker {
                me.noteRealMouseActivity()
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func noteRealMouseActivity() {
        lastRealMouseActivity = Date().timeIntervalSinceReferenceDate
        // The user took over — abandon any return we had queued.
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }

    /// Called when every finger has left the glass.
    func scheduleReturn(to mainDisplayCentre: CGPoint) {
        pendingWorkItem?.cancel()

        arm(after: quietPeriod, target: mainDisplayCentre)
    }

    private func arm(after delay: TimeInterval, target: CGPoint) {
        pendingWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasStopped else { return }

            let idleFor = Date().timeIntervalSinceReferenceDate - self.lastRealMouseActivity
            guard idleFor > self.mouseGrace else {
                // quietPeriod is shorter than mouseGrace, so the first attempt often lands
                // too early. Wait out the remainder rather than dropping the return, which
                // would leave the cursor stranded on the touchscreen for that whole session.
                self.arm(after: self.mouseGrace - idleFor, target: target)
                return
            }

            self.ignoreRealMouseUntil = Date().timeIntervalSinceReferenceDate + self.warpEchoWindow
            CGWarpMouseCursorPosition(target)
            // Re-couple the hardware mouse to the cursor after a warp.
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        pendingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelPendingReturn() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }

    func stop() {
        hasStopped = true
        cancelPendingReturn()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        }
        runLoopSource = nil
        tap = nil
    }
}
