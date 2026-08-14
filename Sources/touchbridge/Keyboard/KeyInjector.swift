import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Types into whatever app currently has focus.
///
/// Two paths on purpose. Real virtual keycodes are what terminals, games and IME-aware
/// fields understand; a Unicode payload with keycode 0 is ignored by those. So we resolve
/// a character to a keycode against the *current* layout first and only fall back to the
/// Unicode payload for characters the layout cannot produce. That fallback is what makes
/// Vietnamese diacritics and emoji work when the layout has no key for them.
final class KeyInjector {
    private let source: CGEventSource?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    /// True when macOS has secure input on. Synthetic keystrokes are dropped system-wide
    /// while it is, by design — surface it instead of silently swallowing keys.
    var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    func type(_ text: String) {
        for character in text {
            if let (keyCode, flags) = Self.keyCode(for: character) {
                sendKey(keyCode, flags: flags)
            } else {
                sendUnicode(String(character))
            }
        }
    }

    func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        down.flags = flags
        down.post(tap: .cghidEventTap)

        // Clear modifiers on the way up or the target app can see a stuck modifier.
        up.flags = []
        up.post(tap: .cghidEventTap)
    }

    private func sendUnicode(_ string: String) {
        var utf16 = Array(string.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        guard !utf16.isEmpty else { return }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)

        // Payload on keyDown only: AppKit inserts there, and a consumer that reads both
        // edges would otherwise insert the character twice.
        up.post(tap: .cghidEventTap)
    }

    // MARK: layout reverse-mapping

    /// Builds character → (keycode, modifiers) for the active layout, so we emit real key
    /// presses whenever the layout can produce the character.
    private static var layoutCache: (source: TISInputSource, table: [Character: (CGKeyCode, CGEventFlags)])?

    private static func keyCode(for character: Character) -> (CGKeyCode, CGEventFlags)? {
        guard let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }

        if let cache = layoutCache, cache.source == current {
            return cache.table[character]
        }

        let table = buildTable(for: current)
        layoutCache = (current, table)
        return table[character]
    }

    private static func buildTable(for input: TISInputSource) -> [Character: (CGKeyCode, CGEventFlags)] {
        guard let raw = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var table: [Character: (CGKeyCode, CGEventFlags)] = [:]
        let modifierStates: [(UInt32, CGEventFlags)] = [(0, []), (UInt32(shiftKey >> 8), .maskShift)]

        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }

            for keyCode in 0..<CGKeyCode(128) {
                for (modifierKey, flags) in modifierStates {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)

                    let status = UCKeyTranslate(
                        layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifierKey,
                        UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState, chars.count, &length, &chars
                    )

                    guard status == noErr, length == 1,
                          let scalar = String(utf16CodeUnits: chars, count: length).first,
                          !scalar.unicodeScalars.allSatisfy({
                              $0.properties.generalCategory == .control
                          })
                    else { continue }

                    // First writer wins: lower key codes are the primary keys.
                    if table[scalar] == nil {
                        table[scalar] = (keyCode, flags)
                    }
                }
            }
        }
        return table
    }
}
