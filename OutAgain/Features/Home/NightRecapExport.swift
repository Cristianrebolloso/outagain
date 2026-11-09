import Foundation
import ImageIO
import UIKit

enum NightRecapExport {
    static let maximumPhotos = 6
    static let size = CGSize(width: 1080, height: 1920)

    /// Keep chronological order regardless of the order photos were tapped.
    static func selectedPosts(from posts: [MomentPost], ids: Set<UUID>) -> [MomentPost] {
        var seen = Set<UUID>()
        return Array(posts.filter { ids.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
            .prefix(maximumPhotos))
    }

    static func makeImage(posts: [MomentPost], date: Date) async throws -> UIImage {
        let chosen = Array(posts.prefix(maximumPhotos))
        guard !chosen.isEmpty else { throw CameraRollSaveError.missingImage }
        var images: [UIImage] = []
        for post in chosen {
            try Task.checkCancellation()
            images.append(try await loadImage(post.media))
        }
        try Task.checkCancellation()
        return render(posts: chosen, images: images, date: date)
    }

    /// Output is a new raster with no source-image metadata or location fields.
    static func render(posts: [MomentPost], images: [UIImage], date: Date) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor(red: 0.018, green: 0.018, blue: 0.03, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            glow(in: cg, center: CGPoint(x: 50, y: 150), color: UIColor(red: 0.06, green: 0.25, blue: 0.65, alpha: 0.46), radius: 670)
            glow(in: cg, center: CGPoint(x: 1080, y: 1200), color: UIColor(red: 0.52, green: 0.07, blue: 0.32, alpha: 0.32), radius: 720)
            glow(in: cg, center: CGPoint(x: 100, y: 1880), color: UIColor(red: 0.04, green: 0.36, blue: 0.30, alpha: 0.30), radius: 520)

            let brandFont = UIFont.systemFont(ofSize: 30, weight: .bold)
            drawText("OUT AGAIN", in: CGRect(x: 66, y: 86, width: 948, height: 44), font: brandFont, color: .white.withAlphaComponent(0.78), tracking: 5)
            drawText("\(date.formatted(.dateTime.weekday(.wide))) night", in: CGRect(x: 62, y: 151, width: 956, height: 100), font: .systemFont(ofSize: 76, weight: .bold), color: .white)
            drawText(date.formatted(.dateTime.month(.wide).day().year()), in: CGRect(x: 66, y: 257, width: 948, height: 52), font: .systemFont(ofSize: 32, weight: .medium), color: .white.withAlphaComponent(0.65))

            let photoArea = CGRect(x: 54, y: 352, width: 972, height: 1230)
            let frames = photoFrames(count: min(posts.count, images.count), in: photoArea)
            for (image, frame) in zip(images, frames) {
                drawPhoto(image, in: frame, context: cg)
            }

            let counts = "\(frames.count) \(frames.count == 1 ? "photo" : "photos") · \(Set(posts.prefix(frames.count).map(\.author.id)).count) \(Set(posts.prefix(frames.count).map(\.author.id)).count == 1 ? "person" : "people")"
            drawText(counts, in: CGRect(x: 66, y: 1620, width: 948, height: 50), font: .systemFont(ofSize: 34, weight: .semibold), color: .white)
            let drinks = drinkSummary(posts: Array(posts.prefix(frames.count)))
            if !drinks.isEmpty {
                drawText(drinks, in: CGRect(x: 66, y: 1681, width: 948, height: 88), font: .systemFont(ofSize: 29, weight: .regular), color: .white.withAlphaComponent(0.72), numberOfLines: 2)
            }
            if let icon = UIImage(named: "AppIconPreview") {
                let rect = CGRect(x: 66, y: 1810, width: 62, height: 62)
                cg.saveGState()
                UIBezierPath(roundedRect: rect, cornerRadius: 16).addClip()
                icon.draw(in: rect)
                cg.restoreGState()
            }
            drawText("Out Again", in: CGRect(x: 148, y: 1822, width: 790, height: 42), font: .systemFont(ofSize: 31, weight: .semibold), color: .white.withAlphaComponent(0.86))
        }
    }

    static func drinkSummary(posts: [MomentPost]) -> String {
        var names: [String] = []
        var seen = Set<String>()
        for post in posts {
            guard let drink = post.drink else { continue }
            let key = drink.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, seen.insert(key.lowercased()).inserted { names.append(key) }
        }
        // Labels describe the selected posts, never imply a measured amount consumed.
        return names.prefix(3).joined(separator: " · ") + (names.count > 3 ? " + more" : "")
    }

    static func photoFrames(count: Int, in rect: CGRect) -> [CGRect] {
        let count = min(max(count, 0), maximumPhotos)
        guard count > 0 else { return [] }
        if count == 1 { return [rect] }
        let gap: CGFloat = 18
        if count == 2 {
            let height = (rect.height - gap) / 2
            return (0..<2).map { CGRect(x: rect.minX, y: rect.minY + CGFloat($0) * (height + gap), width: rect.width, height: height) }
        }
        if count == 3 || count == 5 {
            let firstHeight = count == 3 ? rect.height * 0.54 : rect.height * 0.36
            let remaining = CGRect(x: rect.minX, y: rect.minY + firstHeight + gap, width: rect.width, height: rect.height - firstHeight - gap)
            return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)] + gridFrames(count: count - 1, in: remaining, gap: gap)
        }
        return gridFrames(count: count, in: rect, gap: gap)
    }

    private static func gridFrames(count: Int, in rect: CGRect, gap: CGFloat) -> [CGRect] {
        let rows = (count + 1) / 2
        let width = (rect.width - gap) / 2
        let height = (rect.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        return (0..<count).map { index in
            CGRect(x: rect.minX + CGFloat(index % 2) * (width + gap), y: rect.minY + CGFloat(index / 2) * (height + gap), width: width, height: height)
        }
    }

    @concurrent
    private static func loadImage(_ media: MomentMedia) async throws -> UIImage {
        let data: Data
        if let local = media.photoData {
            data = local
        } else if let url = media.remotePhotoURL {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (download, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw CameraRollSaveError.downloadFailed
            }
            data = download
        } else { throw CameraRollSaveError.missingImage }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CameraRollSaveError.unreadableImage }
        return UIImage(cgImage: image)
    }

    private static func drawPhoto(_ image: UIImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: 30).addClip()
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let imageSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - imageSize.width / 2, y: rect.midY - imageSize.height / 2, width: imageSize.width, height: imageSize.height))
        context.restoreGState()
        context.saveGState()
        UIColor.white.withAlphaComponent(0.16).setStroke()
        let outline = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 30)
        outline.lineWidth = 1
        outline.stroke()
        context.restoreGState()
    }

    private static func glow(in context: CGContext, center: CGPoint, color: UIColor, radius: CGFloat) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    private static func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, tracking: CGFloat = 0, numberOfLines: Int = 1) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = numberOfLines == 1 ? .byTruncatingTail : .byWordWrapping
        paragraph.lineSpacing = 4
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: font, .foregroundColor: color, .kern: tracking, .paragraphStyle: paragraph], context: nil)
    }
}
