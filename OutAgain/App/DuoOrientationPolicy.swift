import SwiftUI
import UIKit

@MainActor
enum DuoOrientationPolicy {
    private static let portraitWindows = NSHashTable<UIWindow>.weakObjects()

    static func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let window else { return .portrait }
        if portraitWindows.contains(window) { return .portrait }
        return window.traitCollection.userInterfaceIdiom == .pad ? .all : .portrait
    }

    static func update(window: UIWindow?, hasHinge: Bool, isClosed: Bool) {
        guard let window, let scene = window.windowScene else { return }
        if portraitWindows.contains(window) != hasHinge {
            if hasHinge { portraitWindows.add(window) }
            else { portraitWindows.remove(window) }
            var controller = window.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        // Duo's inner display explicitly ignores supported orientation masks.
        // Keep the portrait policy whenever this window has a hinge, including
        // tent use of the outer display, without restricting the inner one.
        if isClosed && scene.effectiveGeometry.interfaceOrientation != .portrait {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}

struct DuoOrientationPolicyView: UIViewRepresentable {
    @Environment(AppStore.self) private var store
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        #if canImport(SwiftUICore, _version: 8.1)
        if #available(iOS 27.1, *) {
            view.addInteraction(UIHingeInteraction { [weak view] _, update in
                guard let view else { return }
                // Keep device identity through folds and transient display
                // updates; ordinary iPhones never acquire this capability.
                if update.hinge != nil { store.isDuoDevice = true }
                DuoOrientationPolicy.update(window: view.window, hasHinge: update.hinge != nil,
                                            isClosed: update.hinge?.status == .closed)
            })
        }
        #endif
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
