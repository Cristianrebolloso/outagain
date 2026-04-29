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
    var lensMode: CameraCaptureMode = .back

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "outagain.camera.session")
    @ObservationIgnored private var isConfigured = false

    var dualCaptureSupported: Bool {
        canSwitchLens
    }

    var canSwitchLens: Bool {
        Self.exactDevice(for: .back) != nil && Self.exactDevice(for: .front) != nil
    }

    /// True when the device has a built-in ultrawide rear camera.
    var hasUltraWide: Bool {
        Self.ultraWideDevice() != nil
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

    func switchLens() async {
        guard setupState == .ready, canSwitchLens else { return }

        let targetLens = lensMode.toggled
        do {
            try await configureCameraInput(for: targetLens)
            lensMode = targetLens
            await startSessionIfNeeded()
        } catch {
            setupState = .failed(error.localizedDescription)
        }
    }

    func switchTo(_ lens: CameraCaptureMode) async {
        guard setupState == .ready else { return }
        guard lensMode != lens else { return }
        do {
            try await configureCameraInput(for: lens)
            lensMode = lens
            await startSessionIfNeeded()
        } catch {
            setupState = .failed(error.localizedDescription)
        }
    }

    func capturePhoto() {
        guard setupState == .ready else { return }

        isCapturing = true
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality

        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = lensMode == .front
        }

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
        let initialLens = lensMode

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    session.beginConfiguration()
                    session.sessionPreset = .photo

                    try Self.replaceVideoInput(on: session, with: initialLens)

                    guard session.canAddOutput(photoOutput) else {
                        throw CameraError.photoOutputUnavailable
                    }

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

    private func configureCameraInput(for lens: CameraCaptureMode) async throws {
        let session = session

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    session.beginConfiguration()
                    try Self.replaceVideoInput(on: session, with: lens)
                    session.commitConfiguration()
                    continuation.resume()
                } catch {
                    session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func replaceVideoInput(on session: AVCaptureSession, with lens: CameraCaptureMode) throws {
        let previousInputs = session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }

        previousInputs.forEach(session.removeInput)

        guard let device = device(for: lens) ?? device(for: .back) ?? device(for: .front) else {
            previousInputs.forEach { input in
                if session.canAddInput(input) { session.addInput(input) }
            }
            throw CameraError.noCameraHardware
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            previousInputs.forEach { previousInput in
                if session.canAddInput(previousInput) { session.addInput(previousInput) }
            }
            throw CameraError.inputUnavailable(lens.rawValue)
        }

        session.addInput(input)
    }

    nonisolated private static func exactDevice(for lens: CameraCaptureMode) -> AVCaptureDevice? {
        switch lens {
        case .ultraWide:
            return ultraWideDevice()
        default:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition(for: lens))
                ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: avPosition(for: lens))
        }
    }

    nonisolated static func ultraWideDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
    }

    nonisolated private static func device(for lens: CameraCaptureMode) -> AVCaptureDevice? {
        exactDevice(for: lens)
            ?? exactDevice(for: .back)
            ?? exactDevice(for: .front)
            ?? AVCaptureDevice.default(for: .video)
    }

    nonisolated private static func avPosition(for lens: CameraCaptureMode) -> AVCaptureDevice.Position {
        switch lens {
        case .back, .ultraWide: .back
        case .front: .front
        }
    }

    private enum CameraError: LocalizedError {
        case noCameraHardware
        case inputUnavailable(String)
        case photoOutputUnavailable

        var errorDescription: String? {
            switch self {
            case .noCameraHardware:
                "No camera hardware was found."
            case .inputUnavailable(let lens):
                "The \(lens.lowercased()) could not be attached."
            case .photoOutputUnavailable:
                "Photo capture is unavailable on this device."
            }
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        configureMirroring(on: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
        configureMirroring(on: uiView.previewLayer)
    }

    private func configureMirroring(on layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = isMirrored
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
