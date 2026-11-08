import SwiftUI

/// Scene-local measurements of the whole compact window, including its native
/// controls. Never cache the narrower scroll-view or card width as a pane size.
@Observable
final class DuoLayoutContinuity {
    private(set) var compactWindowWidth: CGFloat?
    private(set) var windowSize: CGSize = .zero
    private(set) var isWide = false

    func observe(size: CGSize, isCompact: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        windowSize = size
        isWide = !isCompact && size.width > size.height
        if isCompact && size.width < size.height { compactWindowWidth = size.width }
    }

    func pageWidth(in windowWidth: CGFloat) -> CGFloat {
        min(compactWindowWidth ?? windowWidth / 2, windowWidth / 2)
    }
}

/// Read the scene window, whose bounds remain valid while a sheet changes the
/// presenting view's safe area. Sheet content retains this same observable
/// object when the device folds, even if its captured environment was compact.
struct DuoSceneLayoutObserver: UIViewRepresentable {
    let continuity: DuoLayoutContinuity

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.continuity = continuity
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.continuity = continuity
        view.measureWindow()
    }

    final class ObserverView: UIView {
        weak var continuity: DuoLayoutContinuity?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            measureWindow()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measureWindow()
        }

        func measureWindow() {
            guard let window, let continuity else { return }
            let size = window.bounds.size
            let isCompact = window.traitCollection.horizontalSizeClass == .compact
            DispatchQueue.main.async { [weak self, weak window, weak continuity] in
                guard self?.window === window, let window, window.bounds.size == size else { return }
                continuity?.observe(size: size, isCompact: isCompact)
            }
        }
    }
}

private struct DuoLayoutContinuityKey: EnvironmentKey {
    static let defaultValue: DuoLayoutContinuity? = nil
}

private struct DuoPresentationWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var duoLayoutContinuity: DuoLayoutContinuity? {
        get { self[DuoLayoutContinuityKey.self] }
        set { self[DuoLayoutContinuityKey.self] = newValue }
    }

    var duoPresentationWidth: CGFloat? {
        get { self[DuoPresentationWidthKey.self] }
        set { self[DuoPresentationWidthKey.self] = newValue }
    }
}
