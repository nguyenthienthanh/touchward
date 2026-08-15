import AppKit
import Carbon.HIToolbox

/// A button that works in an app which is never frontmost.
///
/// The app is an accessory and the panel refuses key status, so *every* click into the
/// keyboard is a first-mouse click. `NSButton` declines those by default, which would make
/// the whole keyboard inert rather than merely awkward.
final class KeyButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The on-screen keys. Deliberately plain and large: this is operated by a fingertip on a
/// 15" panel, so every key is a big hit target with a readable label and no icon-only keys.
final class KeyboardView: NSView {
    private let injector: KeyInjector
    private var shiftEngaged = false
    private var characterKeys: [(button: NSButton, cap: KeyCap)] = []
    private var allButtons: [NSButton] = []
    private let notice = NSTextField(labelWithString: "")

    /// A key's two faces. Derived pairs would be wrong for anything but letters:
    /// `"1".uppercased()` is `"1"`, so shift + 1 would silently type 1 instead of "!".
    struct KeyCap {
        let plain: String
        let shifted: String

        init(_ plain: String, _ shifted: String? = nil) {
            self.plain = plain
            self.shifted = shifted ?? plain.uppercased()
        }
    }

    private static let rows: [[KeyCap]] = [
        [KeyCap("1", "!"), KeyCap("2", "@"), KeyCap("3", "#"), KeyCap("4", "$"), KeyCap("5", "%"),
         KeyCap("6", "^"), KeyCap("7", "&"), KeyCap("8", "*"), KeyCap("9", "("), KeyCap("0", ")")],
        [KeyCap("q"), KeyCap("w"), KeyCap("e"), KeyCap("r"), KeyCap("t"),
         KeyCap("y"), KeyCap("u"), KeyCap("i"), KeyCap("o"), KeyCap("p")],
        [KeyCap("a"), KeyCap("s"), KeyCap("d"), KeyCap("f"), KeyCap("g"),
         KeyCap("h"), KeyCap("j"), KeyCap("k"), KeyCap("l"), KeyCap("'", "\"")],
        [KeyCap("z"), KeyCap("x"), KeyCap("c"), KeyCap("v"), KeyCap("b"),
         KeyCap("n"), KeyCap("m"), KeyCap(",", "<"), KeyCap(".", ">"), KeyCap("/", "?")],
    ]

    init(injector: KeyInjector) {
        self.injector = injector
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: touch driving

    /// The key a finger is currently resting on, so the release knows what to un-highlight.
    private weak var touchedButton: NSButton?

    /// Presses whatever key sits under a point in the global, top-left-origin space that
    /// CGEvent and the touch mapper use. Returns true when a key was hit.
    ///
    /// Driving the button directly, rather than synthesizing a click at that point, is the
    /// whole reason typing no longer drags the pointer onto the touchscreen: a synthetic
    /// `leftMouseDown` *is* a cursor move, so every keystroke used to yank the cursor off
    /// the main display and leave it parked on the keyboard.
    @discardableResult
    func pressKey(atGlobalPoint point: CGPoint) -> Bool {
        releaseKey()
        guard let button = button(atGlobalPoint: point), button.isEnabled else { return false }

        touchedButton = button
        button.highlight(true)
        // Fire on touch-down. On glass there is no way to slide off a key and cancel, and
        // waiting for the lift makes every keystroke feel late.
        if let action = button.action {
            NSApp.sendAction(action, to: button.target, from: button)
        }
        return true
    }

    /// The finger left the glass (or the keyboard). Only clears the highlight — the key
    /// already fired on the way down.
    func releaseKey() {
        touchedButton?.highlight(false)
        touchedButton = nil
    }

    private func button(atGlobalPoint point: CGPoint) -> NSButton? {
        guard let window, let primary = NSScreen.screens.first else { return nil }

        // Global CG space is top-left origin; AppKit's screen space is bottom-left.
        let screenPoint = NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        // `hitTest` takes a point in the *superview's* space. As the panel's content view
        // this view has no superview, and window space is then the same space; the map
        // keeps it correct if it is ever nested.
        let hitPoint = superview.map { $0.convert(windowPoint, from: nil) } ?? windowPoint

        // hitTest lands on whatever is topmost — for a bezelled button that is often an
        // inner cell view, so walk up to the button itself.
        var candidate = hitTest(hitPoint)
        while let view = candidate {
            if let button = view as? NSButton { return button }
            candidate = view.superview
        }
        return nil
    }

    /// Shown when macOS blocks synthetic keys. Saying so beats keys that quietly do nothing.
    func setSecureInputWarning(_ visible: Bool) {
        notice.stringValue = visible ? "Ô mật khẩu — dùng bàn phím thật" : ""
        notice.isHidden = !visible
        allButtons.forEach { $0.isEnabled = !visible }
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for row in Self.rows {
            stack.addArrangedSubview(rowStack(row.map { characterButton($0) }))
        }

        let bottom = [
            actionButton(title: "⇧ Shift", action: #selector(toggleShift)),
            characterButton(KeyCap(" ", " "), title: "Dấu cách"),
            actionButton(title: "⌫ Xoá", action: #selector(backspace)),
            actionButton(title: "↩ Enter", action: #selector(enter)),
        ]
        stack.addArrangedSubview(rowStack(bottom))

        notice.font = .systemFont(ofSize: 13, weight: .medium)
        notice.textColor = .systemOrange
        notice.alignment = .center
        notice.isHidden = true
        notice.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(notice)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -6),
            notice.leadingAnchor.constraint(equalTo: leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: trailingAnchor),
            notice.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            notice.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func rowStack(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func characterButton(_ cap: KeyCap, title: String? = nil) -> NSButton {
        let button = makeButton(title: title ?? cap.plain, action: #selector(tapKey(_:)))
        button.tag = characterKeys.count
        characterKeys.append((button, cap))
        return button
    }

    private func actionButton(title: String, action: Selector) -> NSButton {
        makeButton(title: title, action: action)
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = KeyButton(title: title, target: self, action: action)
        button.bezelStyle = .regularSquare
        button.font = .systemFont(ofSize: 20, weight: .regular)
        button.setButtonType(.momentaryPushIn)
        allButtons.append(button)
        return button
    }

    @objc private func tapKey(_ sender: NSButton) {
        guard characterKeys.indices.contains(sender.tag) else { return }
        let cap = characterKeys[sender.tag].cap

        flash(sender)
        injector.type(shiftEngaged ? cap.shifted : cap.plain)

        if shiftEngaged {
            shiftEngaged = false
            refreshKeyCaps()
        }
    }

    @objc private func toggleShift() {
        shiftEngaged.toggle()
        refreshKeyCaps()
    }

    @objc private func backspace() {
        injector.sendKey(CGKeyCode(kVK_Delete))
    }

    @objc private func enter() {
        injector.sendKey(CGKeyCode(kVK_Return))
    }

    /// The synthesized press and release land in the same run-loop turn, so the button's
    /// own highlight never renders. On glass with no haptics this is the only confirmation
    /// a key was hit.
    private func flash(_ button: NSButton) {
        button.highlight(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { button.highlight(false) }
    }

    private func refreshKeyCaps() {
        for entry in characterKeys where entry.cap.plain != " " {
            entry.button.title = shiftEngaged ? entry.cap.shifted : entry.cap.plain
        }
    }
}
