import CoreGraphics
import Foundation

/// A single portrait format for the viewfinder, reviewed capture and new post.
enum PostPhotoFormat {
    nonisolated static let aspectRatio: CGFloat = 4.0 / 5.0
    nonisolated static let cornerRadius: CGFloat = 28

    nonisolated static func fittedSize(in available: CGSize) -> CGSize {
        let width = max(0, min(available.width, available.height * aspectRatio))
        return CGSize(width: width, height: width / aspectRatio)
    }

    nonisolated static func centerCropRect(in source: CGSize) -> CGRect {
        let size = fittedSize(in: source)
        return CGRect(
            x: (source.width - size.width) / 2,
            y: (source.height - size.height) / 2,
            width: size.width, height: size.height)
    }
    /// Convert the centered guide from an aspect-filled preview into photo
    /// coordinates. A wide tabletop preview otherwise produces a different crop.
    nonisolated static func captureCropRect(in source: CGSize, preview: CGSize?) -> CGRect {
        guard let preview, preview.width.isFinite, preview.height.isFinite,
            preview.width > 0, preview.height > 0, source.width > 0, source.height > 0
        else {
            return centerCropRect(in: source)
        }
        let scale = max(preview.width / source.width, preview.height / source.height)
        let guide = fittedSize(in: preview)
        let size = CGSize(width: guide.width / scale, height: guide.height / scale)
        return CGRect(
            x: (source.width - size.width) / 2,
            y: (source.height - size.height) / 2,
            width: size.width, height: size.height)
    }

}
