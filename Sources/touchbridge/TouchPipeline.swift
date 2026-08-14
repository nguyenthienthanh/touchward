import CoreGraphics
import Foundation
import TouchBridgeCore

/// Wires the pure core to the system layer: bytes in, pointer events out.
final class TouchPipeline {
    private var mapper: CoordinateMapper
    private var recognizer = GestureRecognizer()
    private var latch = ReportStreamLatch()
    private let synthesizer: EventSynthesizer
    private let cursorReturn: CursorReturn
    private var mainCentre: CGPoint
    private var heartbeat: Timer?

    init?(touchDisplay: CGDirectDisplayID, mainDisplay: CGDirectDisplayID, cursorReturn: CursorReturn) {
        guard let synthesizer = EventSynthesizer() else { return nil }
        self.synthesizer = synthesizer
        self.cursorReturn = cursorReturn
        self.mapper = CoordinateMapper(displayBounds: CGDisplayBounds(touchDisplay))
        self.mainCentre = DisplayRegistry.centre(of: mainDisplay)
    }

    /// Drives the clock-dependent half of the recognizer: long press on a still finger, and
    /// the backstop that releases a drag whose report stream died.
    func start() {
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.recognizer.hasActiveGesture else { return }
            self.emit(self.recognizer.tick(at: Date().timeIntervalSinceReferenceDate))
        }
    }

    /// Re-reads geometry after a resolution change or a display being moved.
    func refreshGeometry(touchDisplay: CGDirectDisplayID, mainDisplay: CGDirectDisplayID) {
        mapper = CoordinateMapper(displayBounds: CGDisplayBounds(touchDisplay),
                                  calibration: mapper.calibration)
        mainCentre = DisplayRegistry.centre(of: mainDisplay)
    }

    var calibration: Calibration {
        get { mapper.calibration }
        set { mapper.calibration = newValue }
    }

    func handleReport(id: UInt8, bytes: [UInt8], time: TimeInterval) {
        guard let frame = HIDReportParser.parse(reportID: id, bytes: bytes, time: time) else { return }

        // The controller can emit both its digitizer and its mouse collection. A mouse
        // report carries at most one contact, so letting both through reads as a finger
        // lifting mid-scroll, or as a drag ending while the finger is still down.
        guard latch.accepts(reportID: id, hasContacts: !frame.contacts.isEmpty) else { return }

        // A live touch means the user is not on the mouse — drop any queued cursor return.
        if !frame.contacts.isEmpty {
            cursorReturn.cancelPendingReturn()
        }

        emit(recognizer.handle(mapper.map(frame)))
    }

    /// Closes out anything in flight. Called on quit, on unplug, and on sleep, so a pointer
    /// button is never left logically pressed for the rest of the login session.
    func releaseEverything() {
        emit(recognizer.forceRelease())
        latch.reset()
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
