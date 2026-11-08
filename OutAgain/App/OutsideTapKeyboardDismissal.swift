import SwiftUI
import UIKit

/// Observe outside taps without taking touches away from buttons or scrolling.
/// Installing on this scene's window also covers sheets and the photo composer.
struct OutsideTapKeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardTapInstallerView {
        KeyboardTapInstallerView()
    }

    func updateUIView(_ uiView: KeyboardTapInstallerView, context: Context) {}

    static func dismantleUIView(_ uiView: KeyboardTapInstallerView, coordinator: ()) {
        uiView.uninstall()
    }
}

final class KeyboardTapInstallerView: UIView, UIGestureRecognizerDelegate {
    private weak var installedWindow: UIWindow?
    private lazy var outsideTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window !== installedWindow else { return }
        uninstall()
        window?.addGestureRecognizer(outsideTap)
        installedWindow = window
    }

    func uninstall() {
        installedWindow?.removeGestureRecognizer(outsideTap)
        installedWindow = nil
    }

    @objc private func dismissKeyboard() {
        installedWindow?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A tap in an input must still focus it, position the caret, or select
        // text. The keyboard itself lives outside this content window.
        var touchedView = touch.view
        while let view = touchedView {
            if view is UITextField || (view as? UITextView)?.isEditable == true { return false }
            touchedView = view.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}
