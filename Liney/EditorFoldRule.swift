import CoreGraphics

/// Keeps the line being typed in the upper pane of a partially folded iPhone Duo.
///
/// While the keyboard is shown and an active horizontal division lies above the keyboard's
/// top edge, the editor's writing area ends at the division's top edge instead of the keyboard's.
enum EditorFoldRule {
    /// A division (fold) region in the editor's coordinate space, mapped from
    /// `UIView.ReservedRegion`, which has no public initializer.
    struct Division: Equatable, Sendable {
        var frame: CGRect
        var isActive: Bool
    }

    /// How far the writing area's bottom edge rises above the keyboard's top edge, in points.
    /// Zero leaves the writing area ending at the keyboard, as before.
    ///
    /// All frames are in the editor's coordinate space; `keyboardFrame` is the keyboard's end frame,
    /// or nil when it is hidden.
    static func writingAreaBottomInset(bounds: CGRect, keyboardFrame: CGRect?, divisions: [Division]) -> CGFloat {
        guard let keyboardFrame, keyboardFrame.intersects(bounds), keyboardFrame.minY < bounds.maxY else { return 0 }
        let keyboardTop = keyboardFrame.minY
        let divisionTop = divisions
            .filter { $0.isActive && $0.frame.width > $0.frame.height && $0.frame.minY < keyboardTop }
            .map(\.frame.minY)
            .max()
        guard let divisionTop else { return 0 }
        return max(0, keyboardTop - max(divisionTop, bounds.minY))
    }
}
