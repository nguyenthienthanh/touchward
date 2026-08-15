import AppKit

/// Holds the two things the panel can be: the full keyboard, or the small tab it shrinks
/// into. Touches arrive as points in global display space and are handed to whichever of
/// the two is currently on screen.
///
/// A minimised keyboard matters more here than on a tablet: this panel sits over another
/// machine's screen, and a keyboard with no way out would simply cover the bottom of it.
final class KeyboardSurface: NSView {
    let keyboard: KeyboardView
    let tab: MinimizedTab

    private(set) var isMinimized = false

    /// Asked for by a key press or a tap on the tab. The panel does the resizing.
    var onMinimizeRequest: (() -> Void)?
    var onRestoreRequest: (() -> Void)?

    init(injector: KeyInjector) {
        keyboard = KeyboardView(injector: injector)
        tab = MinimizedTab()
        super.init(frame: .zero)

        addSubview(keyboard)
        addSubview(tab)
        tab.isHidden = true

        keyboard.onHide = { [weak self] in self?.onMinimizeRequest?() }
        tab.onTap = { [weak self] in self?.onRestoreRequest?() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        keyboard.frame = bounds
        tab.frame = bounds
    }

    func setMinimized(_ minimized: Bool) {
        isMinimized = minimized
        keyboard.isHidden = minimized
        tab.isHidden = !minimized
        keyboard.releaseKey()
        needsLayout = true
    }

    // MARK: touch entry points

    @discardableResult
    func pressKey(atGlobalPoint point: CGPoint) -> Bool {
        isMinimized ? tab.press(atGlobalPoint: point) : keyboard.pressKey(atGlobalPoint: point)
    }

    func releaseKey() {
        keyboard.releaseKey()
        tab.release()
    }

    func setSecureInputWarning(_ visible: Bool) {
        keyboard.setSecureInputWarning(visible)
    }
}

/// What the keyboard shrinks to: one large, labelled target that brings it back. Deliberately
/// not an icon on its own — a bare glyph on a strange panel is a guessing game.
final class MinimizedTab: NSView {
    var onTap: (() -> Void)?

    private let label = NSTextField(labelWithString: "⌨︎ Keyboard")
    private var isPressed = false {
        didSet { updateColors() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = KeyPalette.label
        label.alignment = .center
        addSubview(label)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        onTap?()
    }

    @discardableResult
    func press(atGlobalPoint point: CGPoint) -> Bool {
        guard let window, let primary = NSScreen.screens.first else { return false }
        let screenPoint = NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard bounds.contains(local) else { return false }

        isPressed = true
        onTap?()
        return true
    }

    func release() {
        isPressed = false
    }

    private func updateColors() {
        layer?.backgroundColor = (isPressed ? KeyPalette.pressed : KeyPalette.specialKey).cgColor
        label.textColor = KeyPalette.label
    }

    override func updateLayer() {
        updateColors()
    }
}
