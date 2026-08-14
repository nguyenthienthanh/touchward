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

    /// Installs the passive observer. Listen-only: it never modifies or drops an event.
    func startObservingRealMouse() -> Bool {
        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, _, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<CursorReturn>.fromOpaque(refcon).takeUnretainedValue()

            if event.getIntegerValueField(.eventSourceUserData) != EventSynthesizer.marker {
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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
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

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let idleFor = Date().timeIntervalSinceReferenceDate - self.lastRealMouseActivity
            guard idleFor > self.mouseGrace else { return }

            CGWarpMouseCursorPosition(mainDisplayCentre)
            // Re-couple the hardware mouse to the cursor after a warp.
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        pendingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }

    func cancelPendingReturn() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }
}
