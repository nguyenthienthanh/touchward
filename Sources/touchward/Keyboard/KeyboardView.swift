import AppKit
import Carbon.HIToolbox

/// The on-screen keys, laid out the way iPadOS lays them out.
///
/// Matching a keyboard people already know is the whole point: the letters plane keeps
/// delete at the end of the top row and return at the end of the home row, shift sits at
/// both ends of the bottom letter row, and the plane switches live in the corners. Muscle
/// memory then transfers, and nothing has to be explained.
///
/// Operated by a fingertip on a 15" panel, so every key is a large hit target with a
/// readable label and no icon-only key whose meaning has to be guessed.
final class KeyboardView: NSView {

    enum Plane {
        case letters
        case numbers
        case symbols
    }

    /// What a key does. Split from its label so the same action can be drawn differently
    /// per plane, and so a shifted letter is never derived by uppercasing — `"1".uppercased()`
    /// is `"1"`, which would type 1 where the user asked for `!`.
    enum Action {
        case character(plain: String, shifted: String)
        case shift
        case delete
        case newline
        case tab
        case plane(Plane)
        case hide
        case spacer
    }

    struct Key {
        let action: Action
        let width: CGFloat
        let label: String?
        let shiftedLabel: String?

        init(_ action: Action, width: CGFloat = 1, label: String? = nil, shiftedLabel: String? = nil) {
            self.action = action
            self.width = width
            self.label = label
            self.shiftedLabel = shiftedLabel
        }

        static func char(_ plain: String, _ shifted: String? = nil, width: CGFloat = 1) -> Key {
            Key(.character(plain: plain, shifted: shifted ?? plain.uppercased()), width: width)
        }
    }

    /// Tap for one capital, tap twice for caps lock — as on iPadOS.
    enum ShiftState {
        case off
        case oneShot
        case locked

        var isUp: Bool { self != .off }
    }

    private let injector: KeyInjector
    private var plane: Plane = .letters
    private var shift: ShiftState = .off
    private var lastShiftTap: TimeInterval = 0
    private var buttons: [KeyButton] = []
    private let notice = NSTextField(labelWithString: "")

    /// Called when the user asks for the keyboard to get out of the way.
    var onHide: (() -> Void)?

    init(injector: KeyInjector) {
        self.injector = injector
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = KeyPalette.surface.cgColor

        notice.font = .systemFont(ofSize: 13, weight: .medium)
        notice.textColor = .systemOrange
        notice.alignment = .center
        notice.isHidden = true
        addSubview(notice)

        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = KeyPalette.surface.cgColor
    }

    /// Shown when macOS blocks synthetic keys. Saying so beats keys that quietly do nothing.
    func setSecureInputWarning(_ visible: Bool) {
        notice.stringValue = visible ? "Ô mật khẩu — dùng bàn phím thật" : ""
        notice.isHidden = !visible
        buttons.forEach { $0.isEnabled = !visible }
    }

    // MARK: layout

    private static let noticeHeight: CGFloat = 18
    private static let gap: CGFloat = 7
    private static let sidePadding: CGFloat = 8

    /// Every row totals the same number of units, so a letter is exactly as wide on one row
    /// as on the next — the thing that makes a keyboard feel machined rather than assembled.
    private static let rowUnits: CGFloat = 11.5

    private var rows: [[Key]] {
        switch plane {
        case .letters:
            return [
                ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"].map { Key.char($0) }
                    + [Key(.delete, width: 1.5, label: "⌫")],
                [Key(.spacer, width: 0.5)]
                    + ["a", "s", "d", "f", "g", "h", "j", "k", "l"].map { Key.char($0) }
                    + [Key(.newline, width: 2, label: "return")],
                [Key(.shift, width: 1.25, label: "⇧")]
                    + ["z", "x", "c", "v", "b", "n", "m"].map { Key.char($0) }
                    + [Key.char(",", ";"), Key.char(".", ":")]
                    + [Key(.shift, width: 1.25, label: "⇧")],
                bottomRow,
            ]
        case .numbers:
            return [
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map { Key.char($0, $0) }
                    + [Key(.delete, width: 1.5, label: "⌫")],
                [Key(.spacer, width: 0.5)]
                    + ["-", "/", ":", ";", "(", ")", "$", "&", "@"].map { Key.char($0, $0) }
                    + [Key(.newline, width: 2, label: "return")],
                [Key(.plane(.symbols), width: 1.25, label: "#+=")]
                    + ["\"", ".", ",", "?", "!", "'", "%"].map { Key.char($0, $0) }
                    + [Key.char("*", "*"), Key.char("#", "#")]
                    + [Key(.plane(.symbols), width: 1.25, label: "#+=")],
                bottomRow,
            ]
        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { Key.char($0, $0) }
                    + [Key(.delete, width: 1.5, label: "⌫")],
                [Key(.spacer, width: 0.5)]
                    + ["_", "\\", "|", "~", "<", ">", "€", "£", "¥"].map { Key.char($0, $0) }
                    + [Key(.newline, width: 2, label: "return")],
                [Key(.plane(.numbers), width: 1.25, label: "123")]
                    + [".", ",", "?", "!", "'", "\"", "•"].map { Key.char($0, $0) }
                    + [Key.char("§", "§"), Key.char("¶", "¶")]
                    + [Key(.plane(.numbers), width: 1.25, label: "123")],
                bottomRow,
            ]
        }
    }

    private var bottomRow: [Key] {
        let toggle: Key = plane == .letters
            ? Key(.plane(.numbers), width: 1.5, label: ".?123")
            : Key(.plane(.letters), width: 1.5, label: "ABC")
        return [
            toggle,
            Key(.tab, width: 1, label: "⇥"),
            Key(.character(plain: " ", shifted: " "), width: 5.5, label: "dấu cách"),
            toggle,
            Key(.hide, width: 1.5, label: "⌨︎↓"),
        ]
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = rows.flatMap { $0 }.compactMap { key in
            guard case .spacer = key.action else {
                let button = KeyButton(key: key, target: self, action: #selector(keyTapped(_:)))
                addSubview(button)
                return button
            }
            return nil
        }
        refreshTitles()
        needsLayout = true
    }

    override func layout() {
        super.layout()

        notice.frame = NSRect(x: 0, y: bounds.height - Self.noticeHeight,
                              width: bounds.width, height: Self.noticeHeight)

        let grid = rows
        let usableHeight = bounds.height - Self.noticeHeight - Self.gap * CGFloat(grid.count + 1)
        let rowHeight = max(1, usableHeight / CGFloat(grid.count))
        var index = 0
        var y = Self.gap

        for row in grid {
            let gaps = Self.gap * CGFloat(max(0, row.count - 1))
            let available = bounds.width - Self.sidePadding * 2 - gaps
            let unit = available / Self.rowUnits
            var x = Self.sidePadding

            for key in row {
                let width = unit * key.width
                if case .spacer = key.action {
                    x += width + Self.gap
                    continue
                }
                guard index < buttons.count else { break }
                buttons[index].frame = NSRect(x: x, y: y, width: width, height: rowHeight)
                index += 1
                x += width + Self.gap
            }
            y += rowHeight + Self.gap
        }
    }

    // MARK: input

    /// The key a finger is resting on, so the release knows what to un-press.
    private weak var touchedKey: KeyButton?

    /// Presses whatever key sits under a point in the global, top-left-origin space that
    /// CGEvent and the touch mapper use. Returns true when a key was hit.
    ///
    /// Driving the button directly, rather than synthesizing a click there, is why typing
    /// no longer drags the pointer onto the touchscreen: a synthetic `leftMouseDown` *is* a
    /// cursor move.
    @discardableResult
    func pressKey(atGlobalPoint point: CGPoint) -> Bool {
        releaseKey()
        guard let button = key(atGlobalPoint: point), button.isEnabled else { return false }

        touchedKey = button
        button.isPressed = true
        // Fire on touch-down. On glass there is no way to slide off a key to cancel, and
        // waiting for the lift makes every keystroke feel late.
        perform(button.key)
        return true
    }

    /// The finger left the glass. Only clears the highlight — the key fired on the way down.
    func releaseKey() {
        touchedKey?.isPressed = false
        touchedKey = nil
    }

    private func key(atGlobalPoint point: CGPoint) -> KeyButton? {
        guard let window, let primary = NSScreen.screens.first else { return nil }

        // Global CG space is top-left origin; AppKit's screen space is bottom-left.
        let screenPoint = NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)

        return buttons.first { $0.frame.contains(local) }
    }

    @objc private func keyTapped(_ sender: KeyButton) {
        perform(sender.key)
    }

    private func perform(_ key: Key) {
        switch key.action {
        case .character(let plain, let shifted):
            injector.type(shift.isUp ? shifted : plain)
            if shift == .oneShot {
                shift = .off
                refreshTitles()
            }

        case .shift:
            let now = Date().timeIntervalSinceReferenceDate
            // A second tap inside the double-tap window locks it, as on iPadOS.
            if shift.isUp, now - lastShiftTap < 0.4 {
                shift = .locked
            } else {
                shift = shift.isUp ? .off : .oneShot
            }
            lastShiftTap = now
            refreshTitles()

        case .delete:
            injector.sendKey(CGKeyCode(kVK_Delete))

        case .newline:
            injector.sendKey(CGKeyCode(kVK_Return))

        case .tab:
            injector.sendKey(CGKeyCode(kVK_Tab))

        case .plane(let next):
            plane = next
            shift = .off
            rebuild()

        case .hide:
            onHide?()

        case .spacer:
            break
        }
    }

    private func refreshTitles() {
        for button in buttons {
            button.render(shifted: shift.isUp, shiftState: shift)
        }
    }
}

/// One key. Flat, rounded and layer-drawn, because an `NSButton` bezel on a 15" panel reads
/// as a desktop control rather than something to press with a finger.
final class KeyButton: NSButton {
    let key: KeyboardView.Key

    var isPressed = false {
        didSet { needsDisplay = true; updateColors() }
    }

    init(key: KeyboardView.Key, target: AnyObject, action: Selector) {
        self.key = key
        super.init(frame: .zero)
        self.target = target
        self.action = action

        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        render(shifted: false, shiftState: .off)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Every click into this keyboard is a first-mouse click — the app is an accessory and
    /// the panel refuses key status. `NSButton` declines those by default, which would make
    /// the whole keyboard inert.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isSpecial: Bool {
        switch key.action {
        case .character: return false
        default: return true
        }
    }

    func render(shifted: Bool, shiftState: KeyboardView.ShiftState) {
        let text: String
        switch key.action {
        case .character(let plain, let shiftedText):
            text = key.label ?? (shifted ? shiftedText : plain)
        case .shift:
            text = shiftState == .locked ? "⇪" : "⇧"
        default:
            text = key.label ?? ""
        }

        let isLockedShift: Bool
        if case .shift = key.action { isLockedShift = shiftState.isUp } else { isLockedShift = false }

        let size: CGFloat = isSpecial ? 17 : 21
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: isLockedShift ? KeyPalette.activeLabel : KeyPalette.label,
        ])
        isLatched = isLockedShift
        updateColors()
    }

    /// Shift-locked keys stay visually engaged; `isPressed` is the momentary touch.
    private var isLatched = false

    private func updateColors() {
        let base = isLatched
            ? KeyPalette.active
            : (isSpecial ? KeyPalette.specialKey : KeyPalette.key)
        layer?.backgroundColor = (isPressed ? KeyPalette.pressed : base).cgColor
    }

    override func updateLayer() {
        updateColors()
    }
}

/// One place for the keyboard's colours, light and dark. Flat, high contrast, no gradients.
enum KeyPalette {
    static let surface = dynamic(light: NSColor(white: 0.82, alpha: 1), dark: NSColor(white: 0.13, alpha: 1))
    static let key = dynamic(light: .white, dark: NSColor(white: 0.42, alpha: 1))
    static let specialKey = dynamic(light: NSColor(white: 0.70, alpha: 1), dark: NSColor(white: 0.28, alpha: 1))
    static let pressed = dynamic(light: NSColor(white: 0.88, alpha: 1), dark: NSColor(white: 0.55, alpha: 1))
    static let active = dynamic(light: .white, dark: NSColor(white: 0.62, alpha: 1))
    static let label = dynamic(light: .black, dark: .white)
    static let activeLabel = dynamic(light: .black, dark: .black)

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
