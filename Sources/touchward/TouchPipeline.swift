import CoreGraphics
import Foundation
import TouchwardCore

/// Wires the pure core to the system layer: bytes in, pointer events out.
final class TouchPipeline {
    private var mapper: CoordinateMapper
    private var recognizer = GestureRecognizer()
    private var palmFilter: PalmFilter
    private let synthesizer: EventSynthesizer
    private let cursorReturn: CursorReturn
    private var mainCentre: CGPoint
    private var heartbeat: Timer?

    /// Global-coordinate rect of the on-screen keyboard while it is visible.
    /// Touches inside it bypass gesture classification entirely.
    var directTouchRegion: (() -> CGRect?)?
    private var directPress: CGPoint?

    private let profile: DeviceProfile

    init?(profile: DeviceProfile,
          touchDisplay: CGDirectDisplayID,
          mainDisplay: CGDirectDisplayID,
          cursorReturn: CursorReturn) {
        guard let synthesizer = EventSynthesizer() else { return nil }
        self.synthesizer = synthesizer
        self.cursorReturn = cursorReturn
        self.profile = profile
        // Ranges come from the device's descriptor, so a panel with a different resolution
        // maps correctly without anyone editing a constant.
        self.mapper = CoordinateMapper(logicalMaxX: profile.logicalMaxX,
                                       logicalMaxY: profile.logicalMaxY,
                                       displayBounds: CGDisplayBounds(touchDisplay))
        self.palmFilter = PalmFilter(logicalMax: profile.logicalMax)
        self.mainCentre = DisplayRegistry.centre(of: mainDisplay)
    }

    /// Drives the clock-dependent half of the recognizer: long press on a still finger, and
    /// the backstop that releases a drag whose report stream died.
    func start() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.recognizer.hasActiveGesture else { return }
            self.emit(self.recognizer.tick(at: Clock.now()))
        }
        // Common mode: in default mode the heartbeat stalls while a control in our own
        // keyboard panel is tracking — exactly when a held button most needs the backstop.
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// Re-reads geometry after a resolution change or a display being moved.
    func refreshGeometry(touchDisplay: CGDirectDisplayID, mainDisplay: CGDirectDisplayID) {
        mapper = CoordinateMapper(logicalMaxX: profile.logicalMaxX,
                                  logicalMaxY: profile.logicalMaxY,
                                  displayBounds: CGDisplayBounds(touchDisplay),
                                  calibration: mapper.calibration)
        mainCentre = DisplayRegistry.centre(of: mainDisplay)
    }

    var calibration: Calibration {
        get { mapper.calibration }
        set { mapper.calibration = newValue }
    }

    func handle(_ raw: TouchFrame) {
        let frame = palmFilter.reject(raw)

        // A live touch means the user is not on the mouse — drop any queued cursor return.
        if !frame.contacts.isEmpty {
            cursorReturn.cancelPendingReturn()
        }

        let mapped = mapper.map(frame)

        // Keys must respond to the finger landing and leaving, full stop. Routing them
        // through the pointer recognizer meant a 0.4s press typed nothing (past the tap
        // window, short of the long press) and a 0.7s press fired a right click onto the
        // key — the single worst defect in the keyboard.
        if handleDirectTouch(mapped) { return }

        emit(recognizer.handle(mapped))
    }

    /// Returns true when the frame was consumed as a key press.
    private func handleDirectTouch(_ frame: MappedFrame) -> Bool {
        guard let region = directTouchRegion?() else {
            releaseDirectPress()
            return false
        }

        if directPress == nil {
            // Never hijack a gesture already in flight elsewhere on the screen.
            guard !recognizer.hasActiveGesture,
                  frame.contacts.count == 1,
                  let contact = frame.contacts.first,
                  region.contains(contact.point) else { return false }

            synthesizer.pressLeft(at: contact.point)
            directPress = contact.point
            return true
        }

        if let contact = frame.contacts.first(where: { region.contains($0.point) }) {
            directPress = contact.point
            return true
        }

        releaseDirectPress()
        return true
    }

    private func releaseDirectPress() {
        guard let point = directPress else { return }
        synthesizer.releaseLeft(at: point)
        directPress = nil
    }

    /// Closes out anything in flight. Called on quit, on unplug, and on sleep, so a pointer
    /// button is never left logically pressed for the rest of the login session.
    func releaseEverything() {
        // The key press is a held left button too — it must be let go on quit and unplug.
        releaseDirectPress()
        emit(recognizer.forceRelease())
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        releaseEverything()
    }

    private func emit(_ events: [GestureEvent]) {
        for event in events {
            if case .sessionEnded = event {
                cursorReturn.scheduleReturn(to: mainCentre)
            } else {
                synthesizer.apply(event)
            }
        }
    }
}
