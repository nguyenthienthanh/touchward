import XCTest
@testable import TouchwardCore

/// The bug these pin down: a browser's own address bar raised the keyboard, but a field
/// inside a web page did not. Both are places you type; only one of them is a plain
/// `AXTextField`.
final class TextInputClassifierTests: XCTestCase {

    private func element(_ role: String?, subrole: String? = nil,
                         settable: Bool = false) -> FocusedElement {
        FocusedElement(role: role, subrole: subrole, isValueSettable: settable)
    }

    // MARK: native controls

    func testAnAddressBarIsATextField() {
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXTextField")))
    }

    func testTextAreaAndComboBoxCount() {
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXTextArea")))
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXComboBox")))
    }

    func testSearchFieldCountsByRoleOrBySubrole() {
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXSearchField")))
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXTextField", subrole: "AXSearchField")))
    }

    func testPasswordFieldCounts() {
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXTextField", subrole: "AXSecureTextField")))
    }

    // MARK: web content

    /// The actual defect. A page's field can arrive with a role this code has no business
    /// enumerating; what makes it a text input is that its value can be written.
    func testAWebFieldWithAWritableValueCountsWhateverItsRole() {
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXGroup", settable: true)))
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXUnknown", settable: true)))
        XCTAssertTrue(TextInputClassifier.isTextInput(element(nil, settable: true)))
    }

    func testContentEditableCounts() {
        XCTAssertTrue(TextInputClassifier.isTextInput(element("AXGroup", subrole: "AXContentEditable")))
    }

    // MARK: things that must not raise the keyboard

    /// Sliders and checkboxes have writable values too. Without the denylist, focusing one
    /// would throw a keyboard over the bottom of the screen for no reason.
    func testWritableControlsThatAreNotTypedIntoAreRejected() {
        for role in ["AXCheckBox", "AXSlider", "AXRadioButton", "AXPopUpButton", "AXStepper"] {
            XCTAssertFalse(TextInputClassifier.isTextInput(element(role, settable: true)), role)
        }
    }

    func testPlainContentIsRejected() {
        XCTAssertFalse(TextInputClassifier.isTextInput(element("AXStaticText")))
        XCTAssertFalse(TextInputClassifier.isTextInput(element("AXButton")))
        XCTAssertFalse(TextInputClassifier.isTextInput(element("AXLink", settable: true)))
        XCTAssertFalse(TextInputClassifier.isTextInput(element("AXWebArea")))
    }

    func testNothingFocusedIsNotATextInput() {
        XCTAssertFalse(TextInputClassifier.isTextInput(element(nil)))
    }

    // MARK: descending to the real field

    /// An app can answer "what has focus" with the web area or the scroll view that holds
    /// the field. Stopping there is exactly why the page input was missed.
    func testContainersAreWorthDescendingInto() {
        XCTAssertTrue(TextInputClassifier.isContainer(role: "AXWebArea"))
        XCTAssertTrue(TextInputClassifier.isContainer(role: "AXScrollArea"))
        XCTAssertTrue(TextInputClassifier.isContainer(role: "AXGroup"))
    }

    func testARealFieldIsNotDescendedInto() {
        XCTAssertFalse(TextInputClassifier.isContainer(role: "AXTextField"))
        XCTAssertFalse(TextInputClassifier.isContainer(role: nil))
    }
}
