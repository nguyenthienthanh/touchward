import AppKit
import Carbon.HIToolbox

/// The on-screen keys. Deliberately plain and large: this is operated by a fingertip on a
/// 15" panel, so every key is a big hit target with a readable label and no icon-only keys.
final class KeyboardView: NSView {
    private let injector: KeyInjector
    private var shiftEngaged = false
    private var keyButtons: [NSButton] = []
    private let notice = NSTextField(labelWithString: "")

    private static let rows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", "'"],
        ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"],
    ]

    init(injector: KeyInjector) {
        self.injector = injector
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shown when macOS blocks synthetic keys. Saying so beats keys that quietly do nothing.
    func setSecureInputWarning(_ visible: Bool) {
        notice.stringValue = visible ? "Ô mật khẩu — dùng bàn phím thật" : ""
        notice.isHidden = !visible
        keyButtons.forEach { $0.isEnabled = !visible }
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for row in Self.rows {
            stack.addArrangedSubview(rowStack(row.map { keyButton(title: $0, payload: $0) }))
        }

        let bottom = [
            keyButton(title: "⇧ Shift", payload: nil, action: #selector(toggleShift)),
            keyButton(title: "Dấu cách", payload: " "),
            keyButton(title: "⌫ Xoá", payload: nil, action: #selector(backspace)),
            keyButton(title: "↩ Enter", payload: nil, action: #selector(enter)),
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

    private func keyButton(title: String, payload: String?, action: Selector? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action ?? #selector(tapKey(_:)))
        button.bezelStyle = .regularSquare
        button.font = .systemFont(ofSize: 20, weight: .regular)
        button.setButtonType(.momentaryPushIn)
        if let payload {
            button.identifier = NSUserInterfaceItemIdentifier(payload)
        }
        keyButtons.append(button)
        return button
    }

    @objc private func tapKey(_ sender: NSButton) {
        guard let payload = sender.identifier?.rawValue else { return }
        injector.type(shiftEngaged ? payload.uppercased() : payload)

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

    private func refreshKeyCaps() {
        for button in keyButtons {
            guard let payload = button.identifier?.rawValue, payload.count == 1, payload != " " else { continue }
            button.title = shiftEngaged ? payload.uppercased() : payload.lowercased()
        }
    }
}
