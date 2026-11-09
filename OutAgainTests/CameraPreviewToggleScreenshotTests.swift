import Combine
import SwiftUI
import UIKit
import XCTest
@testable import OutAgain

/// Renders the shipped control with local bindings. No camera, accessory
/// availability, or subject-display routing is simulated by this fixture.
@MainActor
final class CameraPreviewToggleScreenshotTests: XCTestCase {
    func testRenderPreviewToggleOffAndOn() async throws {
        let directory = URL(fileURLWithPath: "/tmp/outagain-build12-preview-toggle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .dark
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        let state = PreviewToggleFixtureState()
        let controller = UIHostingController(rootView: PreviewToggleFixture(state: state))
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))

        let offElements = previewElements(in: controller.view)
        checkAccessibility(offElements, expectedState: "Off", expectedAction: "turn on")
        try capture(window: window, name: "preview-off", directory: directory)

        let usedAccessibilityActivation = offElements.first?.accessibilityActivate() == true
        if usedAccessibilityActivation {
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(state.isOn, "Activating the actual button must update its binding")
        } else {
            // UIKit may not expose SwiftUI's virtual elements without an active
            // accessibility client. Still capture both real visual states.
            state.isOn = true
        }
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        let onElements = previewElements(in: controller.view)
        checkAccessibility(onElements, expectedState: "On", expectedAction: "turn off")
        try capture(window: window, name: "preview-on", directory: directory)

        var verifiedReturnActivation = false
        if usedAccessibilityActivation, let onButton = onElements.first {
            let activated = onButton.accessibilityActivate()
            XCTAssertTrue(activated)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(state.isOn, "Activating On must turn the local binding back off")
            verifiedReturnActivation = activated && !state.isOn
        }

        let activationEvidence = usedAccessibilityActivation
            ? "The actual button was activated through UIKit accessibility and its binding changed Off to On\(verifiedReturnActivation ? " and back" : "")."
            : "Accessibility activation was unavailable in this host; screenshots use explicit local Off and On binding values."
        let accessibilityEvidence = offElements.isEmpty && onElements.isEmpty
            ? "No SwiftUI accessibility elements were exposed by this host."
            : "Exposed controls were checked for the Subject preview label, On/Off value, and next-action hint."
        try "Actual CameraPreviewToggleButton in roomy and compact sizes. \(activationEvidence) \(accessibilityEvidence) No camera session, accessory availability, or physical subject display was involved.\n"
            .write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    private func checkAccessibility(_ elements: [NSObject], expectedState: String, expectedAction: String) {
        for element in elements {
            XCTAssertEqual(element.accessibilityLabel, "Subject preview")
            XCTAssertEqual(element.accessibilityValue, expectedState)
            XCTAssertTrue(element.accessibilityHint?.contains(expectedAction) == true)
            XCTAssertTrue(element.accessibilityTraits.contains(.button))
        }
    }

    private func previewElements(in root: UIView) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        var matches: [NSObject] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 24, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement, object.accessibilityLabel == "Subject preview" {
                matches.append(object)
            }
            if let elements = object.accessibilityElements {
                for case let element as NSObject in elements { visit(element, depth: depth + 1) }
            } else {
                let count = object.accessibilityElementCount()
                if count > 0, count < 200 {
                    for index in 0..<count {
                        if let element = object.accessibilityElement(at: index) as? NSObject {
                            visit(element, depth: depth + 1)
                        }
                    }
                }
            }
            if let view = object as? UIView {
                for child in view.subviews { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return matches
    }

    private func capture(window: UIWindow, name: String, directory: URL) throws {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size, CGSize(width: 390, height: 844))
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class PreviewToggleFixtureState: ObservableObject {
    @Published var isOn = false
}

private struct PreviewToggleFixture: View {
    @ObservedObject var state: PreviewToggleFixtureState

    var body: some View {
        VStack(spacing: 48) {
            VStack(spacing: 18) {
                Text("Roomy camera control").font(.headline)
                CameraPreviewToggleButton(isOn: $state.isOn, isEnabled: true)
                    .frame(width: 184)
            }
            VStack(spacing: 18) {
                Text("Compact camera control").font(.headline)
                CameraPreviewToggleButton(isOn: $state.isOn, isEnabled: true, height: 52, large: false)
                    .frame(width: 112)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.dynamicTypeSize, .large)
        .preferredColorScheme(.dark)
    }
}
