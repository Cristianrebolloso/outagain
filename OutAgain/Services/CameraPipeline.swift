@preconcurrency import AVFoundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class CameraPipeline: NSObject, AVCapturePhotoCaptureDelegate {
    enum SetupState: Equatable {
        case idle
        case preparing
        case ready
        case denied
        case failed(String)
    }

    var setupState: SetupState = .idle
    var capturedPhotoData: Data?
    var isCapturing = false
    var lensMode: CameraCaptureMode = .single

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "outagain.camera.session")
    @ObservationIgnored private var isConfigured = false

    var dualCaptureSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    func prepare() async {
        guard setupState == .idle else {
            await startSessionIfNeeded()
            return
        }

        setupState = .preparing

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                setupState = .denied
                return
            }
        case .denied, .restricted:
            setupState = .denied
            return
        @unknown default:
            setupState = .denied
            return
        }

        do {
            try await configureSession()
            lensMode = dualCaptureSupported ? .dualReady : .single
            setupState = .ready
            await startSessionIfNeeded()
        } catch {
            setupState = .failed(error.localizedDescription)
        }
    }

    func startSessionIfNeeded() async {
        guard setupState == .ready else { return }
        let session = session
        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stopSession() {
        let session = session
        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    func capturePhoto() {
        guard setupState == .ready else { return }

        isCapturing = true
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func clearCapture() {
        capturedPhotoData = nil
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            defer { isCapturing = false }

            if let error {
                setupState = .failed(error.localizedDescription)
                return
            }

            capturedPhotoData = photo.fileDataRepresentation()
        }
    }

    private func configureSession() async throws {
        guard !isConfigured else { return }
        let session = session
        let photoOutput = photoOutput

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    session.beginConfiguration()
                    session.sessionPreset = .photo

                    if let existingInput = session.inputs.first {
                        session.removeInput(existingInput)
                    }

                    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(for: .video)

                    guard let device else {
                        throw NSError(domain: "OutAgainCamera", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "No camera hardware was found."
                        ])
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw NSError(domain: "OutAgainCamera", code: 405, userInfo: [
                            NSLocalizedDescriptionKey: "The back camera could not be attached."
                        ])
                    }

                    guard session.canAddOutput(photoOutput) else {
                        throw NSError(domain: "OutAgainCamera", code: 406, userInfo: [
                            NSLocalizedDescriptionKey: "Photo capture is unavailable on this device."
                        ])
                    }

                    session.addInput(input)
                    session.addOutput(photoOutput)
                    photoOutput.maxPhotoQualityPrioritization = .quality
                    session.commitConfiguration()
                    continuation.resume()
                } catch {
                    session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }

        isConfigured = true
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
