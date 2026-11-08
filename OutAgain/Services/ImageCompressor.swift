import UIKit
import ImageIO

/// On-device image compression applied before every upload to Supabase Storage.
///
/// Strategy:
///   • Strip EXIF/GPS metadata entirely — privacy and size win.
///   • Resize the image so the longest edge is at most `maxDimension` pixels.
///   • Re-encode as JPEG at the given quality factor.
///   • Feed images: maxDimension = 960, quality = 0.74; Duo can opt into 1600px.
///   • For thumbnails:  maxDimension = 400,  quality = 0.75  → ~20–60 KB
///   • For avatars:     maxDimension = 400,  quality = 0.82
///
/// Before this, the app was uploading raw iPhone 12-MP shots at up to
/// 8–12 MB each. At 0.80 JPEG and 1080px max, a typical nightlife photo
/// compresses to under 300 KB — a 25-40× reduction per upload, and an
/// equivalent reduction in Storage egress when the feed loads those images.
enum ImageCompressor {

    /// Match the aspect-filled viewfinder after baking EXIF rotation/mirroring
    /// into the pixels. Keeping the crop here makes review and upload agree.
    nonisolated static func postCapture(from data: Data, previewSize: CGSize? = nil) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: exifOrientation(from: source))
        let crop = PostPhotoFormat.captureCropRect(in: image.size, preview: previewSize)
        guard crop.width > 0, crop.height > 0 else { return nil }
        let scale = min(1, 2_000 / crop.height)
        // Multiples of 4 and 5 keep the encoded dimensions exactly 4:5.
        let units = max(1, floor(crop.height * scale / 5))
        let target = CGSize(width: units * 4, height: units * 5)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).jpegData(withCompressionQuality: 0.92) { _ in
            let factor = target.width / crop.width
            image.draw(in: CGRect(x: -crop.minX * factor, y: -crop.minY * factor,
                                  width: image.size.width * factor, height: image.size.height * factor))
        }
    }

    // MARK: - Public presets

    /// Compressed display-quality image for the feed. Returned as JPEG data.
    nonisolated static func feedDisplay(from data: Data, optimizedForDuo: Bool = false) -> Data {
        compress(data, maxDimension: optimizedForDuo ? 1600 : 960, quality: optimizedForDuo ? 0.76 : 0.74)
    }

    /// Like `feedDisplay`, but also returns the aspect ratio (width ÷ height)
    /// of the compressed bytes. Use this on the upload path so the client-side
    /// `photoAspectRatio` value the renderer trusts is derived from the exact
    /// bytes that landed in Storage — not from the pre-compressed source —
    /// closing the door on any drift between the two paths.
    nonisolated static func feedDisplayWithRatio(from data: Data, optimizedForDuo: Bool = false) -> (data: Data, aspectRatio: CGFloat?) {
        let compressed = feedDisplay(from: data, optimizedForDuo: optimizedForDuo)
        return (compressed, aspectRatio(of: compressed))
    }

    /// Aspect ratio (width ÷ height) of the JPEG/HEIC bytes, with EXIF
    /// orientation respected. Returns nil if the bytes can't be decoded or
    /// the height is zero.
    nonisolated static func aspectRatio(of data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let oriented = UIImage(cgImage: cgImage, scale: 1.0, orientation: exifOrientation(from: source))
        guard oriented.size.height > 0 else { return nil }
        return oriented.size.width / oriented.size.height
    }

    /// Small square-ish thumbnail for grid/strip previews. Returned as JPEG data.
    nonisolated static func feedThumbnail(from data: Data) -> Data {
        compress(data, maxDimension: 400, quality: 0.75)
    }

    /// Avatar image — small, very fast to load.
    nonisolated static func avatar(from data: Data) -> Data {
        compress(data, maxDimension: 400, quality: 0.82)
    }

    /// Comment photo reply — medium quality, modest size.
    nonisolated static func commentPhoto(from data: Data) -> Data {
        compress(data, maxDimension: 720, quality: 0.72)
    }

    // MARK: - Core

    /// Resize `data` so neither dimension exceeds `maxDimension`, then
    /// JPEG-encode at `quality`. EXIF metadata is discarded. Returns the
    /// original data unchanged if decoding fails (defensive fallback).
    nonisolated static func compress(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return data
        }

        // Bake EXIF orientation into the UIImage *first*, then derive the
        // target dimensions from the oriented image. Crucial detail: a CGImage
        // off the iPhone camera is always stored landscape-native (e.g.
        // 4032 × 3024) regardless of how the phone was held — orientation is
        // metadata. If we sized the canvas from `cgImage.width/height` we'd
        // draw a portrait UIImage into a landscape box and squash it, which
        // is exactly the bug that caused new posts to appear letterboxed.
        let orientedInput = UIImage(cgImage: cgImage, scale: 1.0, orientation: exifOrientation(from: source))
        let orientedWidth  = orientedInput.size.width
        let orientedHeight = orientedInput.size.height
        let longestEdge    = max(orientedWidth, orientedHeight)

        // Only downscale — never upscale a small image.
        let scale = longestEdge > maxDimension ? maxDimension / longestEdge : 1.0
        let targetWidth  = (orientedWidth  * scale).rounded()
        let targetHeight = (orientedHeight * scale).rounded()

        let resized = resize(orientedInput, to: CGSize(width: targetWidth, height: targetHeight))

        // Re-encode as JPEG. Metadata (GPS, camera model, etc.) is
        // intentionally NOT included — UIImage.jpegData drops all EXIF.
        return resized.jpegData(compressionQuality: quality) ?? data
    }

    // MARK: - Private helpers

    nonisolated private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        // UIGraphicsImageRenderer respects display scale = 1 so the output
        // pixel dimensions match `size` exactly, independent of device DPI.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true   // JPEG has no alpha channel; saves ~25% memory

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Reads the EXIF orientation from the image source so `UIImage` can
    /// bake it into its coordinate system before we re-encode.
    nonisolated private static func exifOrientation(from source: CGImageSource) -> UIImage.Orientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let cgOrientation = CGImagePropertyOrientation(rawValue: raw) else {
            return .up
        }

        switch cgOrientation {
        case .up:            return .up
        case .upMirrored:    return .upMirrored
        case .down:          return .down
        case .downMirrored:  return .downMirrored
        case .left:          return .left
        case .leftMirrored:  return .leftMirrored
        case .right:         return .right
        case .rightMirrored: return .rightMirrored
        }
    }
}

// MARK: - Compression size reporter (debug only)

#if DEBUG
extension ImageCompressor {
    /// Log compression ratio to the Xcode console.
    /// Usage: `ImageCompressor.logRatio(original: rawData, compressed: feedData, label: "feed")`
    nonisolated static func logRatio(original: Data, compressed: Data, label: String) {
        let ratio = Double(original.count) / Double(max(compressed.count, 1))
        let originalKB  = original.count / 1024
        let compressedKB = compressed.count / 1024
        print(String(format: "[IMG] %-12@ %5d KB → %5d KB  (%.1fx smaller)",
                     label, originalKB, compressedKB, ratio))
    }

    /// Trips a debug assertion if the compressed bytes have a different
    /// aspect ratio than the source. This is the canary for the orientation
    /// bug that previously squashed portrait posts into landscape canvases:
    /// any future regression in the resize math would change the output ratio
    /// and fire this assertion immediately on the next upload in DEBUG builds.
    /// No-op in Release.
    nonisolated static func assertAspectRatioPreserved(original: Data, compressed: Data, label: String) {
        guard let originalRatio = aspectRatio(of: original),
              let compressedRatio = aspectRatio(of: compressed) else {
            return  // Decoding failure — unrelated to the invariant we care about.
        }
        let drift = abs(originalRatio - compressedRatio)
        // 0.5% tolerance covers integer-rounding error from the resize step.
        if drift / originalRatio > 0.005 {
            assertionFailure(
                "[IMG] \(label) aspect-ratio drift: " +
                "input=\(originalRatio), output=\(compressedRatio), drift=\(drift). " +
                "Compressor is reshaping the image — check ImageCompressor.compress."
            )
        }
    }
}
#endif
