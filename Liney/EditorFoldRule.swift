import UIKit

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

/// Applies `EditorFoldRule` to the editor's writing area on iOS 27.1 and later.
/// Earlier versions keep the writing area ending at the keyboard.
@MainActor
final class EditorFoldAvoidance: NSObject {
    private weak var editorView: UIView?
    private weak var writingArea: UIScrollView?
    /// The keyboard's end frame in screen coordinates; nil while it is hidden.
    private var keyboardEndFrame: CGRect?
    private var appliedInset: CGFloat = 0

    init(editorView: UIView, writingArea: UIScrollView) {
        self.editorView = editorView
        self.writingArea = writingArea
        super.init()
        guard #available(iOS 27.1, *) else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        // Reserved regions post no change notifications; a pose change only needs a fresh layout pass.
        editorView.addInteraction(UIHingeInteraction { [weak editorView] _, _ in editorView?.setNeedsLayout() })
    }

    /// Call from `viewDidLayoutSubviews`.
    func update() {
        guard #available(iOS 27.1, *), let editorView, let writingArea else { return }
        let keyboardFrame = keyboardEndFrame.flatMap { frame in
            editorView.window?.windowScene.map { editorView.convert(frame, from: $0.screen.coordinateSpace) }
        }
        let divisions = editorView.reservedRegions(kind: .division).map {
            EditorFoldRule.Division(frame: $0.frame, isActive: $0.isActive)
        }
        let inset = EditorFoldRule.writingAreaBottomInset(bounds: editorView.bounds, keyboardFrame: keyboardFrame, divisions: divisions)
        guard inset != appliedInset else { return }
        appliedInset = inset
        writingArea.contentInset.bottom = inset
        writingArea.verticalScrollIndicatorInsets.bottom = inset
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        keyboardEndFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        update()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardEndFrame = nil
        update()
    }
}
