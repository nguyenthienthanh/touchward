import CoreGraphics
import Foundation
import TouchBridgeCore

/// Wires the pure core to the system layer: bytes in, pointer events out.
final class TouchPipeline {
    private var mapper: CoordinateMapper
    private var recognizer = GestureRecognizer()
    private let synthesizer: EventSynthesizer
    private let cursorReturn: CursorReturn
    private var mainCentre: CGPoint

    init?(touchDisplay: CGDirectDisplayID, mainDisplay: CGDirectDisplayID, cursorReturn: CursorReturn) {
        guard let synthesizer = EventSynthesizer() else { return nil }
        self.synthesizer = synthesizer
        self.cursorReturn = cursorReturn
        self.mapper = CoordinateMapper(displayBounds: CGDisplayBounds(touchDisplay))
        self.mainCentre = DisplayRegistry.centre(of: mainDisplay)
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

        // A live touch means the user is not on the mouse — drop any queued cursor return.
        if !frame.contacts.isEmpty {
            cursorReturn.cancelPendingReturn()
        }

        let mapped = mapper.map(frame)
        for event in recognizer.handle(mapped) {
            if case .sessionEnded = event {
                cursorReturn.scheduleReturn(to: mainCentre)
            } else {
                synthesizer.apply(event)
            }
        }
    }
}
