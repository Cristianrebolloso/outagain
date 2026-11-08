import SwiftUI
import UIKit

/// Thin `Identifiable` wrapper so a `UIImage` can drive `.fullScreenCover(item:)`.
struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Full-screen interactive crop sheet. The image can be pinched and dragged
/// behind the crop circle to choose the framing.
struct ImageCropSheet: View {
    @Environment(AppStore.self) private var store
    let image: UIImage
    let onConfirm: (Data) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var initialised = false

    private let maxScale: CGFloat = 6.0

    @ViewBuilder
    var body: some View {
        if store.isDuoDevice {
            duoCrop
        } else {
            PhoneImageCropSheet(image: image, onConfirm: onConfirm, onCancel: onCancel)
        }
    }

    private var duoCrop: some View {
        GeometryReader { geo in
            let diameter = cropDiameter(in: geo.size)
            ZStack {
                Color.black.ignoresSafeArea()

                // Live image
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let minScale = minimumScale(in: geo.size)
                                    let upperScale = max(maxScale, minScale)
                                    scale = (lastScale * value).clamped(to: minScale...upperScale)
                                    clampOffset(geoSize: geo.size)
                                }
                                .onEnded { _ in
                                    clampOffset(geoSize: geo.size)
                                    lastScale = scale
                                    lastOffset = offset
                                },
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    clampOffset(geoSize: geo.size)
                                    lastOffset = offset
                                }
                        )
                    )

                // Darkened surround with circular cutout
                CropOverlay(diameter: diameter)
                    .allowsHitTesting(false)

                // Chrome
                VStack(spacing: 0) {
                    // Cancel — below the safe area notch
                    HStack {
                        Button("Cancel") { onCancel() }
                            .font(AppTypography.bodyMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .contentShape(Capsule())
                            .padding(.leading, 20)
                            .padding(.top, 12)

                        Spacer()
                    }


                    Spacer()

                    // Use Photo
                    Button {
                        confirmCrop(geoSize: geo.size)
                    } label: {
                        Text("Use Photo")
                            .font(AppTypography.button)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.white, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .padding(.horizontal, 40)
                    .padding(.bottom, 16)
                }
            }
            .onAppear {
                guard !initialised else { return }
                let minScale = minimumScale(in: geo.size)
                scale = max(1, minScale).clamped(to: minScale...max(maxScale, minScale))
                lastScale = scale
                clampOffset(geoSize: geo.size)
                lastOffset = offset
                initialised = true
            }
            .onChange(of: geo.size) { oldSize, newSize in
                guard initialised, oldSize.width > 0, oldSize.height > 0 else { return }
                let oldBase = baseImageSize(in: oldSize)
                let newBase = baseImageSize(in: newSize)
                let ratio = cropDiameter(in: newSize) / cropDiameter(in: oldSize)
                if newBase.width > 0 { scale *= oldBase.width / newBase.width * ratio }
                offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
                clampOffset(geoSize: newSize)
                lastScale = scale
                lastOffset = offset
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func cropDiameter(in size: CGSize) -> CGFloat {
        min(300, max(44, min(size.width - 40, size.height - 160)))
    }

    // MARK: - Crop rendering

    private func confirmCrop(geoSize: CGSize) {
        let outputSize = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: outputSize)

        let rendered = renderer.image { _ in
            let imageRect = imageDrawRect(in: geoSize)
            let cropRect = cropCircleRect(in: geoSize)
            let outputScale = outputSize.width / cropDiameter(in: geoSize)
            let outputImageRect = CGRect(
                x: (imageRect.minX - cropRect.minX) * outputScale,
                y: (imageRect.minY - cropRect.minY) * outputScale,
                width: imageRect.width * outputScale,
                height: imageRect.height * outputScale
            )

            UIBezierPath(ovalIn: CGRect(origin: .zero, size: outputSize)).addClip()
            image.draw(in: outputImageRect)
        }

        if let data = rendered.jpegData(compressionQuality: 0.88) {
            onConfirm(data)
        }
    }

    // MARK: - Clamp offset so image always covers the crop circle

    private func clampOffset(geoSize: CGSize) {
        let minScale = minimumScale(in: geoSize)
        scale = scale.clamped(to: minScale...max(maxScale, minScale))
        let imageSize = baseImageSize(in: geoSize)
        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale

        let maxOffX = max(0, (scaledW - cropDiameter(in: geoSize)) / 2)
        let maxOffY = max(0, (scaledH - cropDiameter(in: geoSize)) / 2)

        offset = CGSize(
            width: offset.width.clamped(to: -maxOffX...maxOffX),
            height: offset.height.clamped(to: -maxOffY...maxOffY)
        )
    }

    private func minimumScale(in geoSize: CGSize) -> CGFloat {
        let imageSize = baseImageSize(in: geoSize)
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(cropDiameter(in: geoSize) / imageSize.width, cropDiameter(in: geoSize) / imageSize.height)
    }

    private func imageDrawRect(in geoSize: CGSize) -> CGRect {
        let imageSize = baseImageSize(in: geoSize)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (geoSize.width - scaledSize.width) / 2 + offset.width,
            y: (geoSize.height - scaledSize.height) / 2 + offset.height,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    private func cropCircleRect(in geoSize: CGSize) -> CGRect {
        let diameter = cropDiameter(in: geoSize)
        return CGRect(
            x: (geoSize.width - diameter) / 2,
            y: (geoSize.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
    }

    private func baseImageSize(in geoSize: CGSize) -> CGSize {
        let imgAspect = image.size.width / image.size.height
        let geoAspect = geoSize.width / geoSize.height

        let renderedW: CGFloat
        let renderedH: CGFloat
        if imgAspect > geoAspect {
            renderedW = geoSize.width
            renderedH = geoSize.width / imgAspect
        } else {
            renderedH = geoSize.height
            renderedW = geoSize.height * imgAspect
        }

        return CGSize(width: renderedW, height: renderedH)
    }
}

// MARK: - Crop overlay

private struct CropOverlay: View {
    let diameter: CGFloat

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.6)))
                let circleRect = CGRect(
                    x: (size.width  - diameter) / 2,
                    y: (size.height - diameter) / 2,
                    width:  diameter,
                    height: diameter
                )
                context.blendMode = .destinationOut
                context.fill(Path(ellipseIn: circleRect), with: .color(.black))
            }
            .compositingGroup()

            Circle()
                .strokeBorder(.white.opacity(0.4), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
