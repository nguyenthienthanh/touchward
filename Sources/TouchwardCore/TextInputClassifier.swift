import Foundation

/// What the accessibility tree said about the element that has keyboard focus.
public struct FocusedElement: Equatable, Sendable {
    public let role: String?
    public let subrole: String?
    /// True when the element's value can be written — the strongest signal that something
    /// is a field you type into, and often the only signal a web control gives.
    public let isValueSettable: Bool

    public init(role: String?, subrole: String?, isValueSettable: Bool) {
        self.role = role
        self.subrole = subrole
        self.isValueSettable = isValueSettable
    }
}

/// Decides whether focus has landed somewhere the on-screen keyboard should come up.
///
/// Kept pure and out of the AX layer so the rules can be tested: the interesting cases are
/// all about what different toolkits *call* a text field, and the answers are not obvious.
/// A browser's own address bar is a plain `AXTextField`, but a field inside a web page is
/// whatever the engine chose to expose — frequently a role this code has no business
/// enumerating by hand.
public enum TextInputClassifier {

    /// Roles that are a text input by definition.
    private static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
    ]

    /// Subroles that mark a text input even when the role is generic.
    private static let textSubroles: Set<String> = [
        "AXSearchField",
        "AXSecureTextField",
        "AXContentEditable",
    ]

    /// Controls whose value is writable but which are emphatically not typed into. Without
    /// this list the settable-value rule below would raise the keyboard for every checkbox
    /// and slider that happens to take focus.
    private static let nonTextRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXMenuItem",
        "AXSlider",
        "AXIncrementor",
        "AXStepper",
        "AXDisclosureTriangle",
        "AXScrollBar",
        "AXTabGroup",
        "AXToolbar",
        "AXImage",
        "AXLink",
        "AXStaticText",
        "AXList",
        "AXTable",
        "AXOutline",
        "AXRow",
        "AXCell",
    ]

    public static func isTextInput(_ element: FocusedElement) -> Bool {
        if let subrole = element.subrole, textSubroles.contains(subrole) { return true }
        if let role = element.role, textRoles.contains(role) { return true }

        // The fallback that makes web pages work. A field inside a page may come back as
        // AXGroup, AXUnknown or a role nobody has heard of, but if the accessibility tree
        // says its value can be written, it is somewhere text goes.
        guard element.isValueSettable else { return false }
        guard let role = element.role else { return true }
        return !nonTextRoles.contains(role)
    }

    /// Containers worth descending into. An application's focused element is sometimes the
    /// web area or the scroll view holding the real field rather than the field itself,
    /// and stopping there is why a page's input never raised the keyboard while the
    /// browser's own address bar did.
    private static let containerRoles: Set<String> = [
        "AXWebArea",
        "AXGroup",
        "AXScrollArea",
        "AXSplitGroup",
        "AXUnknown",
        "AXWindow",
        "AXApplication",
    ]

    public static func isContainer(role: String?) -> Bool {
        guard let role else { return false }
        return containerRoles.contains(role)
    }
}
