import AVFoundation
import SwiftUI

/// The regular camera uses the same labeled glass controls as tabletop,
/// scaled to fit a phone's bottom area or the open display's side panel.
struct RegularCameraControls: View {
    @Bindable var camera: CameraPipeline
    @Binding var showsPreview: Bool
    @Binding var captureDelay: Int
    let previewAvailable: Bool
    let isCountingDown: Bool
    let onCapture: () -> Void
    let onClose: () -> Void
    @State private var flipRotation: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let roomy = geometry.size.width >= 360 && geometry.size.height >= 300
            let controlHeight: CGFloat = roomy ? 96 : 52
            let shutterSize: CGFloat = roomy ? 112 : 84

            VStack(spacing: roomy ? 20 : 12) {
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { camera.toggleFlash() }
                    } label: {
                        CameraControlLabel(
                            title: camera.flashMode == .on ? "Flash on" : "Flash off",
                            systemImage: camera.flashMode == .on ? "bolt.fill" : "bolt.slash.fill",
                            height: controlHeight, large: roomy
                        )
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .tint(camera.flashMode == .on ? AppTheme.lightningGold : .white)
                    .disabled(!camera.isFlashAvailable || camera.setupState != .ready || camera.isCapturing || isCountingDown)

                    Button(action: onCapture) {
                        Circle().fill(.white)
                            .overlay(Circle().strokeBorder(AppTheme.smoke, lineWidth: 6).padding(8))
                            .frame(width: shutterSize, height: shutterSize)
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.isCapturing || isCountingDown || camera.setupState != .ready)
                    .opacity(camera.isCapturing || isCountingDown ? 0.65 : 1)
                    .accessibilityLabel("Take photo")
                    .accessibilityIdentifier("camera.shutter")

                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { flipRotation += 180 }
                        Task { await camera.switchLens() }
                    } label: {
                        CameraControlLabel(
                            title: "Flip", systemImage: "arrow.triangle.2.circlepath.camera",
                            height: controlHeight, large: roomy, rotation: flipRotation
                        )
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .disabled(!camera.canSwitchLens || camera.setupState != .ready || camera.isCapturing || isCountingDown)
                }

                HStack(spacing: 12) {
                    Button(action: onClose) {
                        CameraControlLabel(title: "Close", systemImage: "xmark", height: controlHeight, large: roomy)
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)

                    if previewAvailable && camera.lensMode.isRear {
                        Button { showsPreview.toggle() } label: {
                            CameraControlLabel(title: showsPreview ? "Preview on" : "Preview", systemImage: "rectangle.on.rectangle", height: controlHeight, large: roomy)
                        }
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                        .disabled(camera.setupState != .ready)
                        .accessibilityLabel(showsPreview ? "Hide preview" : "Show preview")
                    }

                    Menu {
                        Button("Timer off") { captureDelay = 0 }
                        Button("3 seconds") { captureDelay = 3 }
                        Button("10 seconds") { captureDelay = 10 }
                    } label: {
                        CameraControlLabel(
                            title: captureDelay == 0 ? "Timer off" : "\(captureDelay)s timer",
                            systemImage: "timer", height: controlHeight, large: roomy
                        )
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("camera.timer")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tint(.white)
        }
        .accessibilityIdentifier("camera.controls")
    }
}

struct CameraControlLabel: View {
    let title: String
    let systemImage: String
    var height: CGFloat = 96
    var large = true
    var rotation: Double = 0

    var body: some View {
        VStack(spacing: large ? 10 : 6) {
            Image(systemName: systemImage)
                .font(.system(size: large ? 24 : 21, weight: .medium))
                .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0))
            Text(title)
                .font(large ? AppTypography.button : AppTypography.buttonFootnote)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: height)
    }
}
