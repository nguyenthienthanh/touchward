import AppKit
import ApplicationServices

/// Watches which UI element has keyboard focus so the keyboard can show itself only when
/// a text field is actually waiting for input.
///
/// Observers are per-process: registering against the system-wide element fails with
/// kAXErrorInvalidUIElement, so we tear down and rebuild the observer on every app switch.
final class FocusWatcher {
    struct Focus: Equatable {
        var isTextInput: Bool
        var isSecureField: Bool
        /// Where the field is, in the global top-left-origin space CGDisplayBounds uses.
        /// Nil when the app will not say — some apps expose no geometry at all.
        var bounds: CGRect?
    }

    /// The last state handed to the caller. Focus is polled as well as observed, and
    /// re-presenting the keyboard twice a second would fight the user's own window order.
    private var lastReported: Focus?

    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedPID: pid_t?
    private var onChange: ((Focus) -> Void)?
    private var activationToken: NSObjectProtocol?

    func start(onChange: @escaping (Focus) -> Void) {
        self.onChange = onChange

        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
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
        // Cmd-Tab back and forth re-activates the same app; rebuilding the observer each
        // time re-triggers AXManualAccessibility and a full round-trip for nothing.
        guard pid != observedPID else { return }
        teardown()

        let app = AXUIElementCreateApplication(pid)
        // Every AX read below is a blocking IPC call on the main thread, where the touch
        // heartbeat also lives. The default timeout is ~6s: long enough for a beachballing
        // app to stall the backstop that releases a held mouse button.
        AXUIElementSetMessagingTimeout(app, 0.25)

        // Chromium and Electron keep their web accessibility tree switched off until
        // something asks for it. Without this, focus in a web text field never fires.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
            me.reportCurrentFocus()
        }

        guard AXObserverCreate(pid, callback, &newObserver) == .success, let created = newObserver else {
            // Failing silently would strand a visible keyboard over an app that cannot
            // report focus at all.
            report(Focus(isTextInput: false, isSecureField: false, bounds: nil))
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        // Focus can leave a text field without the focused *element* changing — the window
        // changes, or the app quietly drops focus altogether. Watching only the element
        // notification is why the keyboard sometimes stayed up over a non-text view.
        for notification in [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXUIElementDestroyedNotification,
        ] {
            AXObserverAddNotification(created, app, notification as CFString, context)
        }
        // Common modes: in default mode these notifications stall while a control in our
        // own keyboard panel is tracking, which is exactly when focus tends to move.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)

        observer = created
        observedApp = app
        observedPID = pid

        reportCurrentFocus()
    }

    /// Re-reads focus on demand. Not every app emits an AX notification when focus leaves
    /// a text field — some emit nothing at all — so the keyboard polls this while it is on
    /// screen rather than trusting that a notification will arrive.
    func refresh() {
        reportCurrentFocus()
    }

    private func reportCurrentFocus() {
        guard let app = observedApp else {
            report(Focus(isTextInput: false, isSecureField: false, bounds: nil))
            return
        }

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused
        else {
            report(Focus(isTextInput: false, isSecureField: false, bounds: nil))
            return
        }

        // A misbehaving app can return something other than an element here. A force cast
        // would trap and take the touch driver down with it.
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            report(Focus(isTextInput: false, isSecureField: false, bounds: nil))
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

        report(Focus(isTextInput: role.map(textRoles.contains) ?? false,
                     isSecureField: isSecure,
                     bounds: bounds(of: target) ?? focusedWindowBounds(app)))
    }

    /// The field's own rectangle. AX reports it in the same global, top-left-origin space
    /// as `CGDisplayBounds`, so it can be tested against a display without conversion.
    private func bounds(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard read(element, kAXPositionAttribute, .cgPoint, &position),
              read(element, kAXSizeAttribute, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Fallback for apps that give the focused element no geometry — a web view's inner
    /// field often has none, but the window it lives in always does.
    private func focusedWindowBounds(_ app: AXUIElement) -> CGRect? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return bounds(of: window as! AXUIElement)
    }

    /// An app can answer with something that is not an `AXValue` at all; unwrapping that
    /// with a force cast would trap and take the touch driver down with it.
    private func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }

    private func read(_ element: AXUIElement, _ attribute: String,
                      _ type: AXValueType, _ into: UnsafeMutableRawPointer) -> Bool {
        guard let value = axValue(element, attribute) else { return false }
        return AXValueGetValue(value, type, into)
    }

    private func report(_ focus: Focus) {
        guard focus != lastReported else { return }
        lastReported = focus
        onChange?(focus)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func stop() {
        if let activationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(activationToken)
        }
        activationToken = nil
        teardown()
        onChange = nil
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
