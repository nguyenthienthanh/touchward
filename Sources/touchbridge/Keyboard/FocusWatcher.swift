import AppKit
import ApplicationServices

/// Watches which UI element has keyboard focus so the keyboard can show itself only when
/// a text field is actually waiting for input.
///
/// Observers are per-process: registering against the system-wide element fails with
/// kAXErrorInvalidUIElement, so we tear down and rebuild the observer on every app switch.
final class FocusWatcher {
    struct Focus {
        var isTextInput: Bool
        var isSecureField: Bool
    }

    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedPID: pid_t?
    private var onChange: ((Focus) -> Void)?

    func start(onChange: @escaping (Focus) -> Void) {
        self.onChange = onChange

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observe(pid: app.processIdentifier)
        }

        if let front = NSWorkspace.shared.frontmostApplication {
            observe(pid: front.processIdentifier)
        }
    }

    private func observe(pid: pid_t) {
        teardown()

        let app = AXUIElementCreateApplication(pid)

        // Chromium and Electron keep their web accessibility tree switched off until
        // something asks for it. Without this, focus in a web text field never fires.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
            me.reportCurrentFocus()
        }

        guard AXObserverCreate(pid, callback, &newObserver) == .success, let created = newObserver else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        observedApp = app
        observedPID = pid

        reportCurrentFocus()
    }

    private func reportCurrentFocus() {
        guard let app = observedApp else { return }

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused
        else {
            onChange?(Focus(isTextInput: false, isSecureField: false))
            return
        }

        // A misbehaving app can return something other than an element here. A force cast
        // would trap and take the touch driver down with it.
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            onChange?(Focus(isTextInput: false, isSecureField: false))
            return
        }
        let target = element as! AXUIElement
        let role = stringAttribute(target, kAXRoleAttribute)
        let subrole = stringAttribute(target, kAXSubroleAttribute)

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String)

        onChange?(Focus(isTextInput: role.map(textRoles.contains) ?? false, isSecureField: isSecure))
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func teardown() {
        if let observer, let app = observedApp {
            AXObserverRemoveNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedApp = nil
        observedPID = nil
    }
}
