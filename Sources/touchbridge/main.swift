import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

// TouchBridge — makes a USB touchscreen behave like an absolute pointing device on macOS,
// without touching the physical mouse and keyboard paths.

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

// MARK: permissions

/// Both grants are TCC prompts. Neither needs SIP disabled or a kernel extension.
func ensurePermissions() -> Bool {
    var ok = true

    if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
        log("⚠️  Thiếu quyền Accessibility — cần để bắn sự kiện chuột/phím và đọc focus.")
        ok = false
    }

    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log("⚠️  Thiếu quyền Input Monitoring — cần để đọc màn cảm ứng.")
        ok = false
    }

    return ok
}

// MARK: wiring

final class AppController: NSObject, NSApplicationDelegate {
    private let device = HIDTouchDevice()
    private let cursorReturn = CursorReturn()
    private let injector = KeyInjector()
    private let focusWatcher = FocusWatcher()

    private var pipeline: TouchPipeline?
    private var panel: KeyboardPanel?
    private var keyboardView: KeyboardView?
    private var touchDisplayID: CGDirectDisplayID?
    private var secureInputPoll: Timer?
    private var hasShutDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let touchDisplay = DisplayRegistry.touchDisplay(),
              let mainDisplay = DisplayRegistry.mainDisplay() else {
            log("❌ Không xác định được màn cảm ứng. Đang có \(DisplayRegistry.activeDisplays().count) màn hình.")
            NSApp.terminate(nil)
            return
        }

        touchDisplayID = touchDisplay
        log("🖥  Màn cảm ứng: display \(touchDisplay) bounds \(CGDisplayBounds(touchDisplay))")

        guard let pipeline = TouchPipeline(touchDisplay: touchDisplay,
                                           mainDisplay: mainDisplay,
                                           cursorReturn: cursorReturn) else {
            log("❌ Không tạo được CGEventSource.")
            NSApp.terminate(nil)
            return
        }
        self.pipeline = pipeline

        installShutdownHandlers()

        if !cursorReturn.startObservingRealMouse() {
            log("⚠️  Không cài được event tap quan sát chuột thật — con trỏ vẫn sẽ trả về, "
                + "nhưng sẽ không tránh được lúc anh đang cầm chuột.")
        }

        // Unplugging mid-drag would otherwise leave the left button logically pressed.
        device.onDisconnect = { [weak self] in
            DispatchQueue.main.async {
                log("🔌 Màn cảm ứng đã rút. Nhả mọi nút đang giữ.")
                self?.pipeline?.releaseEverything()
            }
        }

        switch device.start(onReport: { [weak pipeline] id, bytes, time in
            pipeline?.handleReport(id: id, bytes: bytes, time: time)
        }) {
        case .success:
            log(device.isSeized
                ? "✅ Đã giành thiết bị cảm ứng (seize) — macOS thôi tự sinh click."
                : "⚠️  Không seize được thiết bị; macOS có thể vẫn sinh click ma tại con trỏ.")
            log(device.inputModeSet
                ? "✅ Đã chuyển sang chế độ multitouch."
                : "ℹ️  Không đổi được chế độ nhập; nếu chỉ nhận 1 điểm chạm thì panel đang ở mouse mode.")
        case .failure(let error):
            log("❌ \(error.description)")
            NSApp.terminate(nil)
            return
        }

        pipeline.start()

        DisplayRegistry.onReconfiguration { [weak self] in
            DispatchQueue.main.async { self?.geometryChanged() }
        }

        // Waking from sleep can drop the final report of whatever was in flight.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pipeline?.releaseEverything()
        }

        setUpKeyboard(on: touchDisplay)
        log("▶️  TouchBridge đang chạy. Ctrl-C để thoát.")
    }

    /// A held drag must not survive the process. Ctrl-C is the documented way to quit, and
    /// SIGINT bypasses AppKit entirely — so both paths need the same release.
    private func installShutdownHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutDown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    func applicationWillTerminate(_ notification: Notification) {
        shutDown()
    }

    private func shutDown() {
        guard !hasShutDown else { return }
        hasShutDown = true

        pipeline?.stop()          // releases any held button first
        device.stop()
        cursorReturn.stop()
        stopSecureInputPolling()
        panel?.dismiss()
    }

    private func geometryChanged() {
        guard let touch = DisplayRegistry.touchDisplay(), let main = DisplayRegistry.mainDisplay() else { return }
        touchDisplayID = touch
        pipeline?.refreshGeometry(touchDisplay: touch, mainDisplay: main)
        if let screen = NSScreen.matching(displayID: touch), panel?.isVisible == true {
            panel?.present(on: screen)
        }
    }

    private func setUpKeyboard(on touchDisplay: CGDirectDisplayID) {
        let view = KeyboardView(injector: injector)
        let panel = KeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300))
        panel.contentView = view

        self.panel = panel
        self.keyboardView = view

        focusWatcher.start { [weak self] focus in
            guard let self, let screen = NSScreen.matching(displayID: touchDisplay) else { return }

            if focus.isTextInput {
                view.setSecureInputWarning(focus.isSecureField || self.injector.isSecureInputActive)
                panel.present(on: screen)
                self.startSecureInputPolling()
            } else {
                panel.dismiss()
                self.stopSecureInputPolling()
            }
        }
    }

    /// Secure input has no notification, so poll while the keyboard is on screen.
    private func startSecureInputPolling() {
        guard secureInputPoll == nil else { return }
        secureInputPoll = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.keyboardView?.setSecureInputWarning(self.injector.isSecureInputActive)
        }
    }

    private func stopSecureInputPolling() {
        secureInputPoll?.invalidate()
        secureInputPoll = nil
    }
}

// MARK: entry point

guard ensurePermissions() else {
    log("""

    Cấp quyền rồi chạy lại:
      System Settings → Privacy & Security → Accessibility
      System Settings → Privacy & Security → Input Monitoring
    """)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, nothing to steal focus
let controller = AppController()
app.delegate = controller
app.run()
