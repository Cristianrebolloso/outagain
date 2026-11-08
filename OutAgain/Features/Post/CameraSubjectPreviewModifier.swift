import SwiftUI

/// The system owns display routing and accessory availability. Nothing is
/// shown to the subject until the photographer enables the preview.
struct CameraSubjectPreviewModifier: ViewModifier {
    let camera: CameraPipeline
    let isDuoDevice: Bool
    @Binding var isEnabled: Bool
    @Binding var isAvailable: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(SwiftUICore, _version: 8.1)
        if #available(iOS 27.1, *), isDuoDevice {
            content.sceneAccessory {
                CameraCaptureAccessory(isEnabled: $isEnabled) {
                    FullScreenSubjectPreview {
                        CameraSubjectPreviewView(renderer: camera.subjectPreview, device: camera.activeDevice)
                    }
                }
                .onAvailabilityChange { available in
                    isAvailable = available
                    if !available { isEnabled = false }
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Fill the accessory's physical display, including its safe areas. The
/// preview layer uses aspect fill, so there are no borders or letterboxing.
struct FullScreenSubjectPreview<Preview: View>: View {
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        GeometryReader { geometry in
            preview()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .ignoresSafeArea(.container)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .accessibilityLabel("Subject camera preview")
        .accessibilityIdentifier("camera.subject.preview")
    }
}
