// Preserve the existing phone crop geometry independently of Duo resizing.
import SwiftUI
import UIKit

/// Full-screen interactive crop sheet. The image can be pinched and dragged
/// behind the crop circle to choose the framing.
struct PhoneImageCropSheet: View {
    let image: UIImage
    let onConfirm: (Data) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var initialised = false
    @State private var safeAreaTop: CGFloat = 59  // sensible default for Dynamic Island devices

    private let cropDiameter: CGFloat = 300
    private let maxScale: CGFloat = 6.0

    var body: some View {
        GeometryReader { geo in
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
                CropOverlay(diameter: cropDiameter)
                    .ignoresSafeArea()
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
                            .padding(.top, safeAreaTop + 12)

                        Spacer()
                    }
                    .background(
                        GeometryReader { safeGeo in
                            Color.clear.onAppear {
                                let top = safeGeo.safeAreaInsets.top
                                if top > 0 { safeAreaTop = top }
                            }
                        }
                    )

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
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 24) + 8)
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
        }
        .ignoresSafeArea()
    }

    // MARK: - Crop rendering

    private func confirmCrop(geoSize: CGSize) {
        let outputSize = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: outputSize)

        let rendered = renderer.image { _ in
            let imageRect = imageDrawRect(in: geoSize)
            let cropRect = cropCircleRect(in: geoSize)
            let outputScale = outputSize.width / cropDiameter
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

        let maxOffX = max(0, (scaledW - cropDiameter) / 2)
        let maxOffY = max(0, (scaledH - cropDiameter) / 2)

        offset = CGSize(
            width: offset.width.clamped(to: -maxOffX...maxOffX),
            height: offset.height.clamped(to: -maxOffY...maxOffY)
        )
    }

    private func minimumScale(in geoSize: CGSize) -> CGFloat {
        let imageSize = baseImageSize(in: geoSize)
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(cropDiameter / imageSize.width, cropDiameter / imageSize.height)
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
        CGRect(
            x: (geoSize.width - cropDiameter) / 2,
            y: (geoSize.height - cropDiameter) / 2,
            width: cropDiameter,
            height: cropDiameter
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
