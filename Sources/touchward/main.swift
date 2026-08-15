import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

// Touchward — makes a USB touchscreen behave like an absolute pointing device on macOS,
// without touching the physical mouse and keyboard paths.

/// Logs to stderr and to a file. The file matters: the app must be launched via `open` so
/// macOS assigns it its own TCC identity, and that detaches it from any terminal.
private let logFile: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true)
    // Named after the bundle rather than a literal, so renaming the app in one config
    // file cannot leave the log writing under the old name.
    let name = (Bundle.main.infoDictionary?["CFBundleName"] as? String)
        ?? ProcessInfo.processInfo.processName
    return dir.appendingPathComponent("\(name).log")
}()

func log(_ message: String) {
    let stamped = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    FileHandle.standardError.write(stamped.data(using: .utf8)!)

    guard let data = stamped.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logFile) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: logFile)
    }
}

// MARK: permissions

/// Reads the two TCC grants this app needs.
///
/// Both requests must happen *after* the app is running its event loop. macOS presents
/// these dialogs on behalf of a live process; asking from a bare `main` and exiting a
/// moment later means tccd has nothing to attach the dialog to and the user is never
/// asked at all.
enum Permissions {
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var inputMonitoring: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    static var inputMonitoringGranted: Bool {
        inputMonitoring == kIOHIDAccessTypeGranted
    }

    static var allGranted: Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    /// Triggers both system dialogs. Safe to call once only — repeating it re-opens the
    /// Accessibility alert on every poll.
    static func request() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Only the Accessibility pane. Granting it also satisfies input monitoring, and the
    /// app never appears in the Input Monitoring list — sending the user there to hunt for
    /// a checkbox that will never exist is worse than not opening anything.
    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func describe() -> String {
        let hid: String
        switch inputMonitoring {
        case kIOHIDAccessTypeGranted: hid = "đã cấp"
        case kIOHIDAccessTypeDenied: hid = "BỊ TỪ CHỐI"
        default: hid = "chưa hỏi"
        }
        return "Accessibility: \(accessibilityGranted ? "đã cấp" : "chưa cấp") · Input Monitoring: \(hid)"
    }
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
    private var lastFocusWasSecureField = false

    private var permissionPoll: Timer?
    private var hasRequestedPermissions = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("▶️  Touchward khởi động. \(Permissions.describe())")

        // Accessibility is asked for up front: its prompt is cheap and non-blocking.
        if !Permissions.accessibilityGranted {
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }

        requestInputMonitoringThenBegin()
    }

    /// Order matters more than anything else in this file.
    ///
    /// Opening a HID device without permission does not raise a prompt — it silently
    /// records a *denial*, and macOS never asks twice. So the open attempt must not happen
    /// until access has been asked for and granted, or the app burns its one chance to ask
    /// and the user is left with a permission they were never offered.
    private func requestInputMonitoringThenBegin() {
        switch Permissions.inputMonitoring {
        case kIOHIDAccessTypeGranted:
            begin()

        case kIOHIDAccessTypeDenied:
            log("""
                ⚠️  Quyền theo dõi thiết bị nhập đang bị từ chối, macOS sẽ không hỏi lại.
                    Cách sửa: bật Accessibility cho Touchward — quyền đó bao trùm luôn
                    việc đọc màn cảm ứng, nên app KHÔNG cần xuất hiện trong danh sách
                    Input Monitoring.
                      System Settings → Privacy & Security → Accessibility
                    Nếu vẫn kẹt, xoá trạng thái cũ rồi mở lại app:
                      tccutil reset All com.ethannguyen.touchward
                """)
            Permissions.openSettings()
            pollUntilGranted()

        default:
            log("⏳ Đang xin quyền Input Monitoring…")
            // An accessory app is never frontmost, and macOS declines to raise a TCC
            // dialog on behalf of a process the user is not looking at. Become a regular
            // app just long enough to be asked, then drop back so nothing steals focus
            // from the app being typed into.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // IOHIDRequestAccess blocks until the user answers. On the main thread it would
            // freeze the very run loop the dialog is drawn on, and TCC records a denial.
            DispatchQueue.global(qos: .userInitiated).async {
                let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                    log("   Kết quả: \(granted ? "đã cấp" : "chưa cấp")")
                    if granted {
                        self.begin()
                    } else {
                        Permissions.openSettings()
                        self.pollUntilGranted()
                    }
                }
            }
        }
    }

    /// Waits for the grant rather than quitting, so the user does not have to find and
    /// relaunch the app after ticking a checkbox.
    ///
    /// Only Accessibility is watched. The HID answer is cached per process and cannot
    /// change while this one runs — waiting for it here is the same deadlock as trying to
    /// open the device before asking: a condition that can never become true. Accessibility
    /// is both the thing the user can actually toggle and, once granted, the thing that
    /// makes the HID access succeed after a relaunch.
    private func pollUntilGranted() {
        guard permissionPoll == nil else { return }

        log("""

            Bật Touchward ở đây rồi app tự chạy tiếp:
              System Settings → Privacy & Security → Accessibility

            Accessibility bao trùm cả việc đọc màn cảm ứng, nên Touchward sẽ KHÔNG
            hiện trong danh sách Input Monitoring — đó là bình thường.
            """)

        var ticks = 0
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }

            guard Permissions.accessibilityGranted else {
                // Say so periodically: a silent log is indistinguishable from a crash,
                // which is exactly how this looked the first time it happened.
                ticks += 1
                if ticks % 20 == 0 {
                    log("… vẫn đang chờ cấp quyền. \(Permissions.describe())")
                }
                return
            }

            self.permissionPoll?.invalidate()
            self.permissionPoll = nil
            log("✅ Accessibility đã cấp — khởi động lại để áp dụng.")
            self.relaunch()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPoll = timer
    }

    /// Clicking the app again while it is already running does nothing visible, because it
    /// is an agent with no window — it looks like a crash. Use the reopen as a nudge to
    /// re-check and report where things stand.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        log("↻ Mở lại. \(Permissions.describe())")
        if Permissions.accessibilityGranted && !Permissions.inputMonitoringGranted {
            log("   Quyền đã có nhưng tiến trình này giữ câu trả lời cũ — khởi động lại.")
            relaunch()
        }
        return true
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            exit(0)
        }
    }

    private func begin() {
        guard let touchDisplay = DisplayRegistry.touchDisplay(),
              let mainDisplay = DisplayRegistry.mainDisplay() else {
            log("""
                ❌ Không xác định được màn hình nào là màn cảm ứng \
                (đang có \(DisplayRegistry.activeDisplays().count) màn hình).
                Rút bớt màn phụ khác rồi chạy lại, hoặc đặt TOUCHBRIDGE_DISPLAY_ID=<id>.
                """)
            exit(1)
        }

        touchDisplayID = touchDisplay
        log("🖥  Màn cảm ứng: display \(touchDisplay) bounds \(CGDisplayBounds(touchDisplay))")

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

        // The device is started first: everything downstream is sized from what it
        // declares, so there is nothing to configure until it has answered.
        let profile: DeviceProfile
        switch device.start(onFrame: { [weak self] frame in
            self?.pipeline?.handle(frame)
        }) {
        case .success(let discovered):
            profile = discovered
            log("🔎 \(profile.productName): \(Int(profile.logicalMaxX))×\(Int(profile.logicalMaxY)) "
                + "logical, tối đa \(profile.maxContacts) điểm chạm")
            log(device.isSeized
                ? "✅ Đã giành thiết bị cảm ứng (seize) — macOS thôi tự sinh click."
                : "⚠️  Không seize được thiết bị; macOS có thể vẫn sinh click ma tại con trỏ.")
            // Deliberately not phrased as success: the panel accepted this report last
            // time and went on sending mouse reports anyway. What mode it is really in is
            // reported below, from the usages that actually arrive.
            log(device.inputModeSet
                ? "↪︎ Đã gửi lệnh bật multitouch (chưa chắc panel nghe theo)."
                : "ℹ️  Panel không nhận lệnh đổi chế độ nhập.")
        case .failure(let error):
            log("❌ \(error.description)")
            exit(1)
        }

        guard let pipeline = TouchPipeline(profile: profile,
                                           touchDisplay: touchDisplay,
                                           mainDisplay: mainDisplay,
                                           cursorReturn: cursorReturn) else {
            log("❌ Không tạo được CGEventSource.")
            exit(1)
        }
        self.pipeline = pipeline
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

        setUpKeyboard()
        log("▶️  Touchward đang chạy. Ctrl-C để thoát.")
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

        // Order is load-bearing: the pipeline releases any held button through a still
        // live event source, and cursorReturn.stop() then cancels the warp that release
        // just armed. Reversing these two lines lets a warp fire after teardown.
        pipeline?.stop()
        device.stop()
        focusWatcher.stop()
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

    private func setUpKeyboard() {
        let view = KeyboardView(injector: injector)
        let panel = KeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300))
        panel.contentView = view

        self.panel = panel
        self.keyboardView = view

        // Touches landing on the keyboard bypass gesture classification entirely.
        pipeline?.directTouchRegion = { [weak panel] in
            guard let panel, panel.isVisible else { return nil }
            return panel.cgFrame
        }
        // The key is driven straight from the touch point. Synthesizing a click instead
        // would move the pointer onto the keyboard on every keystroke.
        pipeline?.pressKey = { [weak view] point in
            view?.pressKey(atGlobalPoint: point) ?? false
        }
        pipeline?.releaseKey = { [weak view] in
            view?.releaseKey()
        }

        focusWatcher.start { [weak self] focus in
            // Read the display ID fresh rather than capturing it: replugging the panel
            // mints a new CGDirectDisplayID, and a captured stale one silently resolves to
            // no screen — the keyboard would simply stop appearing, with no error.
            guard let self else { return }

            // Dismissal must not depend on finding the screen: if the panel is unplugged
            // while the keyboard is up, a later non-text focus still has to put it away.
            guard focus.isTextInput else {
                panel.dismiss()
                self.stopSecureInputPolling()
                return
            }
            guard let displayID = self.touchDisplayID,
                  let screen = NSScreen.matching(displayID: displayID) else { return }

            self.lastFocusWasSecureField = focus.isSecureField
            view.setSecureInputWarning(focus.isSecureField || self.injector.isSecureInputActive)
            panel.present(on: screen)
            self.startSecureInputPolling()
        }
    }

    /// Secure input has no notification, so poll while the keyboard is on screen.
    private func startSecureInputPolling() {
        guard secureInputPoll == nil else { return }
        secureInputPoll = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            guard let self else { return }
            // The AX subrole ("this is a password field") and the system flag ("synthetic
            // keys are blocked right now") are different facts and routinely disagree.
            self.keyboardView?.setSecureInputWarning(
                self.lastFocusWasSecureField || self.injector.isSecureInputActive)
        }
    }

    private func stopSecureInputPolling() {
        secureInputPoll?.invalidate()
        secureInputPoll = nil
    }
}

// MARK: entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, nothing to steal focus
let controller = AppController()
app.delegate = controller
app.run()
