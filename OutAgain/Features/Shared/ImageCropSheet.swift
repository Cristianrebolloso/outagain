import SwiftUI
import UIKit

/// Thin `Identifiable` wrapper so a `UIImage` can drive `.fullScreenCover(item:)`.
struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Full-screen interactive crop sheet. Starts fully zoomed-out so the whole
/// image fits inside the circle; user pinches to zoom in and drags to reposition.
struct ImageCropSheet: View {
    let image: UIImage
    let onConfirm: (Data) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    @State private var initialised = false
    @State private var safeAreaTop: CGFloat = 59  // sensible default for Dynamic Island devices

    private let cropDiameter: CGFloat = 300
    private let maxScale: CGFloat = 8.0

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
                                    let minScale = fitScale(in: geo.size)
                                    scale = (lastScale * value).clamped(to: minScale...maxScale)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    clampOffset(geoSize: geo.size)
                                    lastOffset = offset
                                },
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width:  lastOffset.width  + value.translation.width,
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
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                            .glassEffect(.regular.interactive(), in: .capsule)
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
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 40)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 24) + 8)
                }
            }
            .onAppear {
                guard !initialised else { return }
                let fit = fitScale(in: geo.size)
                scale = fit
                lastScale = fit
                initialised = true
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Scale that makes the full image fit inside the crop circle

    /// Returns the scale at which the image's smaller dimension exactly equals
    /// the crop diameter — so the whole image is visible inside the circle.
    private func fitScale(in geoSize: CGSize) -> CGFloat {
        let imgW = image.size.width
        let imgH = image.size.height
        let imgAspect = imgW / imgH
        let geoAspect = geoSize.width / geoSize.height

        // Size the image would be rendered at scale=1 with .scaledToFit
        let renderedW: CGFloat
        let renderedH: CGFloat
        if imgAspect > geoAspect {
            renderedW = geoSize.width
            renderedH = geoSize.width / imgAspect
        } else {
            renderedH = geoSize.height
            renderedW = geoSize.height * imgAspect
        }

        // Scale so the image's smaller rendered dimension fits the crop diameter
        let scaleW = cropDiameter / renderedW
        let scaleH = cropDiameter / renderedH
        // Use the larger of the two so the whole image fits inside the circle
        return max(scaleW, scaleH)
    }

    // MARK: - Crop rendering

    private func confirmCrop(geoSize: CGSize) {
        let outputSize = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: outputSize)

        let rendered = renderer.image { _ in
            let imgAspect = image.size.width / image.size.height
            let geoAspect = geoSize.width / geoSize.height

            // Rendered size of the image at scale=1 (.scaledToFit)
            let renderedW: CGFloat
            let renderedH: CGFloat
            if imgAspect > geoAspect {
                renderedW = geoSize.width
                renderedH = geoSize.width / imgAspect
            } else {
                renderedH = geoSize.height
                renderedW = geoSize.height * imgAspect
            }

            // Actual drawn size after user scale
            let drawW = renderedW * scale
            let drawH = renderedH * scale

            // Top-left of the drawn image on screen
            let drawX = (geoSize.width  - drawW) / 2 + offset.width
            let drawY = (geoSize.height - drawH) / 2 + offset.height

            // Crop circle bounds on screen
            let circleX = (geoSize.width  - cropDiameter) / 2
            let circleY = (geoSize.height - cropDiameter) / 2

            // Map crop rect → normalised within drawn image → source pixels
            let normX = (circleX - drawX) / drawW
            let normY = (circleY - drawY) / drawH
            let normW = cropDiameter / drawW
            let normH = cropDiameter / drawH

            let srcX = normX * image.size.width
            let srcY = normY * image.size.height
            let srcW = normW * image.size.width
            let srcH = normH * image.size.height
            let srcRect = CGRect(x: srcX, y: srcY, width: srcW, height: srcH)

            // Clip to circle and draw
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: outputSize)).addClip()

            if let cropped = image.cgImage?.cropping(to: srcRect) {
                UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: outputSize))
            } else {
                image.draw(in: CGRect(origin: .zero, size: outputSize))
            }
        }

        if let data = rendered.jpegData(compressionQuality: 0.88) {
            onConfirm(data)
        }
    }

    // MARK: - Clamp offset so image always covers the crop circle

    private func clampOffset(geoSize: CGSize) {
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

        let scaledW = renderedW * scale
        let scaledH = renderedH * scale

        // Allow dragging until the image edge meets the crop circle edge
        let maxOffX = max(0, (scaledW - cropDiameter) / 2)
        let maxOffY = max(0, (scaledH - cropDiameter) / 2)

        offset = CGSize(
            width:  offset.width.clamped(to:  -maxOffX...maxOffX),
            height: offset.height.clamped(to: -maxOffY...maxOffY)
        )
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
