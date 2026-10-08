import CoreGraphics
import Testing
@testable import Liney

struct EditorFoldRuleTests {
    /// iPhone Duo laptop pose as measured: a 669 × 951 pt editor, the division at y 455–495 pt,
    /// and the system keyboard's top edge at about y 505 pt.
    static let laptopBounds = CGRect(x: 0, y: 0, width: 669, height: 951)
    static let laptopKeyboard = CGRect(x: 0, y: 505, width: 669, height: 446)
    static let laptopDivision = CGRect(x: 0, y: 455, width: 669, height: 40)

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let keyboardFrame: CGRect?
        let divisions: [EditorFoldRule.Division]
        let expectedInset: CGFloat
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "laptop pose, keyboard up", keyboardFrame: laptopKeyboard,
             divisions: [.init(frame: laptopDivision, isActive: true)], expectedInset: 50),
        Case(name: "keyboard hidden", keyboardFrame: nil,
             divisions: [.init(frame: laptopDivision, isActive: true)], expectedInset: 0),
        Case(name: "keyboard moved off the bottom edge", keyboardFrame: laptopKeyboard.offsetBy(dx: 0, dy: 446),
             divisions: [.init(frame: laptopDivision, isActive: true)], expectedInset: 0),
        Case(name: "inactive division", keyboardFrame: laptopKeyboard,
             divisions: [.init(frame: laptopDivision, isActive: false)], expectedInset: 0),
        Case(name: "no division", keyboardFrame: laptopKeyboard, divisions: [], expectedInset: 0),
        Case(name: "vertical division", keyboardFrame: laptopKeyboard,
             divisions: [.init(frame: CGRect(x: 314, y: 0, width: 40, height: 951), isActive: true)], expectedInset: 0),
        Case(name: "division below the keyboard's top edge", keyboardFrame: CGRect(x: 0, y: 400, width: 669, height: 551),
             divisions: [.init(frame: laptopDivision, isActive: true)], expectedInset: 0)
    ]

    @Test(arguments: cases)
    func writingAreaEndsAtTheDivisionOnlyWhileTypingAboveIt(_ example: Case) {
        let inset = EditorFoldRule.writingAreaBottomInset(
            bounds: Self.laptopBounds, keyboardFrame: example.keyboardFrame, divisions: example.divisions
        )
        #expect(inset == example.expectedInset)
    }
}
