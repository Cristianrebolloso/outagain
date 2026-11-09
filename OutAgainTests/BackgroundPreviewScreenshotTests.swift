import XCTest
import SwiftUI
import UIKit
@testable import OutAgain

@MainActor
final class BackgroundPreviewScreenshotTests: XCTestCase {
    func testRenderAuthoredFeedAndEmptyBackgroundPreviews() async throws {
        let directory = URL(fileURLWithPath: "/tmp/outagain-build12-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        for (layout, size) in [("phone", CGSize(width: 390, height: 844)), ("wide", CGSize(width: 900, height: 600))] {
            for scenario in ["authored", "feed", "empty"] {
                let store = DuoLayoutFixtures.makeStore()
                let viewer = try XCTUnwrap(store.viewer)
                let friend = try XCTUnwrap(store.friends.first)
                var post = try XCTUnwrap(store.posts.first)
                post.author = scenario == "authored" ? viewer : friend
                post.createdAt = Date().addingTimeInterval(-300)
                post.caption = "We found the spot."
                post.comments = []
                post.commentCount = 0
                post.media.photoData = try localPhoto().pngData()
                post.media.remotePhotoURL = nil
                post.media.photoAspectRatio = 0.8
                store.posts = scenario == "empty" ? [] : [post]
                store.feedScope = .friends
                let themeBefore = store.backgroundTheme
                let chosen = BackgroundPreviewPostSelection.post(in: store)
                if scenario == "empty" { XCTAssertNil(chosen) }
                else { XCTAssertEqual(chosen?.author.id, scenario == "authored" ? viewer.id : friend.id) }

                window.frame = CGRect(origin: .zero, size: size)
                let view = BackgroundPreviewView(theme: .blue, post: chosen)
                    .environment(store)
                    .environment(PermissionCenter())
                    .environment(\.appAccent, store.accentColorChoice.color)
                    .environment(\.dynamicTypeSize, .large)
                    .preferredColorScheme(.dark)
                let controller = UIHostingController(rootView: view)
                controller.view.backgroundColor = .black
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.frame = window.bounds
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(600))
                window.layoutIfNeeded()

                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                format.opaque = true
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertEqual(image.size, size)
                XCTAssertEqual(store.backgroundTheme, themeBefore)
                XCTAssertEqual(store.posts.count, scenario == "empty" ? 0 : 1)
                XCTAssertEqual(store.posts.first?.viewerReactionKinds, scenario == "empty" ? nil : post.viewerReactionKinds)
                let name = "\(scenario)-\(layout)"
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        try "Actual BackgroundPreviewView with actual MomentPostCard and isolated local fixture image. Authored, visible-feed fallback, and no-post Tonight fallback at 390x844 and 900x600 points. The wide render is a hosting-window layout check, not a physical Duo screenshot. No production session or purchases.\n".write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    private func localPhoto() throws -> UIImage {
        let size = CGSize(width: 800, height: 1_000)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.06, green: 0.08, blue: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, color) in [UIColor.systemBlue, .systemPurple, .systemTeal].enumerated() {
                color.withAlphaComponent(0.65).setFill()
                UIBezierPath(ovalIn: CGRect(x: 80 + index * 210, y: 220 + index * 120, width: 280, height: 280)).fill()
            }
            ("Tonight" as NSString).draw(at: CGPoint(x: 90, y: 670), withAttributes: [
                .font: UIFont.systemFont(ofSize: 88, weight: .bold), .foregroundColor: UIColor.white
            ])
            ("Local preview photo" as NSString).draw(at: CGPoint(x: 94, y: 785), withAttributes: [
                .font: UIFont.systemFont(ofSize: 32, weight: .medium), .foregroundColor: UIColor.white.withAlphaComponent(0.75)
            ])
        }
    }
}
