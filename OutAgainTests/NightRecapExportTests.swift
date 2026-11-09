import XCTest
import ImageIO
import UIKit
@testable import OutAgain

@MainActor
final class NightRecapExportTests: XCTestCase {
    func testSelectionIncludesOnlyChosenPhotosAndKeepsNightOrder() throws {
        let posts = DuoLayoutFixtures.makeStore().posts
        XCTAssertGreaterThanOrEqual(posts.count, 3)
        let chosenIDs = Set([posts[0].id, posts[2].id])
        let selection = NightRecapExport.selectedPosts(from: posts.reversed() + [posts[0]], ids: chosenIDs)
        XCTAssertEqual(Set(selection.map(\.id)), chosenIDs)
        XCTAssertEqual(selection.count, 2)
        XCTAssertLessThanOrEqual(selection[0].createdAt, selection[1].createdAt)
        XCTAssertTrue(NightRecapExport.selectedPosts(from: posts, ids: []).isEmpty)
    }

    func testEveryCollageFitsWithoutOverlappingPhotos() {
        let available = CGRect(x: 54, y: 352, width: 972, height: 1230)
        for count in 1...6 {
            let frames = NightRecapExport.photoFrames(count: count, in: available)
            XCTAssertEqual(frames.count, count)
            for (index, frame) in frames.enumerated() {
                XCTAssertTrue(available.contains(frame))
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                for other in frames.dropFirst(index + 1) {
                    XCTAssertFalse(frame.intersects(other))
                }
            }
        }
    }

    func testExportIsStorySizedAndDoesNotCarrySourceMetadata() throws {
        let posts = Array(DuoLayoutFixtures.makeStore().posts.prefix(6))
        let images = posts.enumerated().map { index, _ in
            UIGraphicsImageRenderer(size: CGSize(width: 480, height: 600)).image { context in
                UIColor(hue: CGFloat(index) / 7, saturation: 0.55, brightness: 0.55, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 480, height: 600))
                ("Photo \(index + 1)" as NSString).draw(at: CGPoint(x: 60, y: 260), withAttributes: [.font: UIFont.systemFont(ofSize: 60, weight: .bold), .foregroundColor: UIColor.white])
            }
        }
        let image = NightRecapExport.render(posts: posts, images: images, date: Date(timeIntervalSince1970: 1_794_090_000))
        XCTAssertEqual(image.size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(image.scale, 1)
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.94))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary as String])
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/outagain-recap-test-render.png"))
    }
}
