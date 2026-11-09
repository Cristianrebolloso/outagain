import XCTest
import SwiftUI
import UIKit
@testable import OutAgain

@MainActor
final class AccentControlTests: XCTestCase {
    func testWhiteSwitchUpdatesBindingAndKeepsOnOffStatesDistinct() async throws {
        let model = AccentToggleModel()
        try await withHostedView(AccentToggleHarness(model: model)) { window, controller in
            let control = try XCTUnwrap(descendants(of: controller.view, type: UISwitch.self).first)
            XCTAssertFalse(control.isOn)
            XCTAssertNil(control.thumbTintColor, "Off uses the native thumb appearance")

            control.setOn(true, animated: false)
            control.sendActions(for: .valueChanged)
            XCTAssertTrue(model.isOn, "A real UIKit valueChanged event must update SwiftUI's binding")
            try await waitUntil { control.thumbTintColor != nil }
            XCTAssertGreaterThan(try luminance(XCTUnwrap(control.onTintColor)), 0.9)
            XCTAssertLessThan(try luminance(XCTUnwrap(control.thumbTintColor)), 0.25,
                              "An enabled white track needs a visibly dark thumb")
            try render(window, name: "white-switch-on")

            model.isOn = false
            try await waitUntil { !control.isOn && control.thumbTintColor == nil }
            XCTAssertFalse(control.isOn, "Model updates must reach the native switch")
            XCTAssertNil(control.thumbTintColor)
            try render(window, name: "white-switch-off")
        }
    }

    func testDisabledAndChangedAccentReachTheNativeControl() async throws {
        let model = AccentToggleModel()
        model.isOn = true
        try await withHostedView(AccentToggleHarness(model: model)) { _, controller in
            let control = try XCTUnwrap(descendants(of: controller.view, type: UISwitch.self).first)
            XCTAssertTrue(control.isEnabled)
            model.isEnabled = false
            try await waitUntil { !control.isEnabled }
            XCTAssertFalse(control.isEnabled)

            model.accent = .purple
            model.isEnabled = true
            try await waitUntil { control.isEnabled && control.thumbTintColor == nil }
            XCTAssertTrue(control.isOn)
            XCTAssertNil(control.thumbTintColor, "Colored accents keep the platform thumb")
        }
    }

    func testRenderActualSettingsWithWhiteAccent() async throws {
        let defaults = UserDefaults.standard
        let globalAccentKey = "OutAgain.accentColor"
        let oldGlobalAccent = defaults.object(forKey: globalAccentKey)
        let store = DuoLayoutFixtures.makeStore()
        let accountAccentKey = "OutAgain.accentColor.\(try XCTUnwrap(store.viewer?.id).uuidString)"
        let oldAccountAccent = defaults.object(forKey: accountAccentKey)
        defer {
            restore(oldGlobalAccent, key: globalAccentKey, defaults: defaults)
            restore(oldAccountAccent, key: accountAccentKey, defaults: defaults)
        }
        store.isDuoDevice = false
        store.accentColorChoice = .white
        let permissions = PermissionCenter()
        let feedAds = FeedAdStore()
        let view = NavigationStack { ProfileSettingsView() }
            .environment(store)
            .environment(permissions)
            .environment(feedAds)
            .environment(\.appAccent, Color.white)
            .environment(\.appBackgroundTheme, store.backgroundTheme)
            .environment(\.defaultBackgroundPhase, .default2)
            .environment(\.dynamicTypeSize, .large)
            .tint(.white)
            .preferredColorScheme(.dark)

        try await withHostedView(view) { window, controller in
            try render(window, name: "settings-white-top")
            let scrollView = try XCTUnwrap(descendants(of: controller.view, type: UIScrollView.self)
                .first { $0.contentSize.height > $0.bounds.height + 100 })
            let control = try XCTUnwrap(descendants(of: scrollView, type: UISwitch.self).first)
            let rect = control.convert(control.bounds, to: scrollView)
            let maximumOffset = max(-scrollView.adjustedContentInset.top,
                                    scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let targetY = min(maximumOffset, max(-scrollView.adjustedContentInset.top, rect.minY - 170))
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            try render(window, name: "settings-white-notifications")
        }
    }

    private func withHostedView<Content: View>(
        _ view: Content,
        operation: (UIWindow, UIHostingController<Content>) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .dark
        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        try await operation(window, controller)
    }

    private func descendants<T: UIView>(of view: UIView, type: T.Type) -> [T] {
        let own = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(of: $0, type: type) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "The hosted control did not update within one second")
    }

    private func luminance(_ color: UIColor) throws -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func render(_ window: UIWindow, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/outagain-ui-polish", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

@MainActor
private final class AccentToggleModel: ObservableObject {
    @Published var isOn = false
    @Published var isEnabled = true
    @Published var accent = Color.white
}

private struct AccentToggleHarness: View {
    @ObservedObject var model: AccentToggleModel

    var body: some View {
        Toggle("Push notifications", isOn: $model.isOn)
            .toggleStyle(AppAccentToggleStyle(accent: model.accent))
            .disabled(!model.isEnabled)
            .padding(24)
            .foregroundStyle(.white)
            .background(.black)
    }
}
