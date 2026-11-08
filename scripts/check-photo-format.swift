import Foundation
import CoreGraphics

@main
struct CheckPostPhotoFormat {
    static func main() {
        let viewports: [CGSize] = [
            .init(width: 353, height: 440), // ordinary phone
            .init(width: 330, height: 330), // outer display
            .init(width: 571, height: 603), // open landscape
            .init(width: 629, height: 660), // open portrait
            .init(width: 620, height: 260), // tabletop top region
            .init(width: 300, height: 150), // reduced space
            .zero
        ]
        for viewport in viewports {
            let fitted = PostPhotoFormat.fittedSize(in: viewport)
            precondition(fitted.width <= viewport.width && fitted.height <= viewport.height)
            if fitted.height > 0 {
                precondition(abs(fitted.width / fitted.height - 0.8) < 0.000_001)
            }
        }
        for width in stride(from: 80.0, through: 4_032.0, by: 197.0) {
            for height in stride(from: 80.0, through: 4_032.0, by: 173.0) {
                let source = CGSize(width: width, height: height)
                let crop = PostPhotoFormat.centerCropRect(in: source)
                precondition(abs(crop.width / crop.height - 0.8) < 0.000_001)
                precondition(abs(crop.midX - width / 2) < 0.000_001)
                precondition(abs(crop.midY - height / 2) < 0.000_001)
                precondition(crop.minX >= -0.000_001 && crop.minY >= -0.000_001)
                precondition(crop.maxX <= width + 0.000_001 && crop.maxY <= height + 0.000_001)
            }
        }
        for source in [CGSize(width: 4_032, height: 3_024), CGSize(width: 3_024, height: 4_032)] {
            for preview in viewports where preview.width > 0 && preview.height > 0 {
                let crop = PostPhotoFormat.captureCropRect(in: source, preview: preview)
                let fillScale = max(preview.width / source.width, preview.height / source.height)
                let guide = PostPhotoFormat.fittedSize(in: preview)
                // Project the saved crop back into the live aspect-filled view.
                precondition(abs(crop.width * fillScale - guide.width) < 0.000_001)
                precondition(abs(crop.height * fillScale - guide.height) < 0.000_001)
                precondition(abs(crop.width / crop.height - 0.8) < 0.000_001)
                precondition(crop.minX >= 0 && crop.minY >= 0 && crop.maxX <= source.width && crop.maxY <= source.height)
            }
        }
        let wideCrop = PostPhotoFormat.captureCropRect(in: CGSize(width: 4_032, height: 3_024),
                                                     preview: CGSize(width: 669, height: 450))
        precondition(wideCrop.height < 3_024, "A wide preview crops the sensor vertically; capture must match that guide")
        print("PASS: 4:5 framing in every posture; saved crops match the guide in aspect-filled portrait and tabletop previews")
    }
}
