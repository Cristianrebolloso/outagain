@preconcurrency import AVFoundation
import Observation
import SwiftUI
import UIKit
import OSLog

@MainActor
@Observable
final class CameraPipeline: NSObject, AVCapturePhotoCaptureDelegate {
    private final class SessionLifecycleState: @unchecked Sendable {
        var activePresentationID: UUID?
        var subjectPreviewEnabled = false
    }

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
    @ObservationIgnored var captureRotationAngle: CGFloat = 0
    @ObservationIgnored var capturePreviewSize: CGSize?
    @ObservationIgnored nonisolated private let captureFramings = CaptureFramings()

    /// The JPEG callback can arrive after a fold or rotation. Keep the framing
    /// that was visible at the shutter, keyed to AVFoundation's capture ID.
    nonisolated private final class CaptureFramings: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated struct Framing: Sendable {
            let previewSize: CGSize?
            let optimizedForDuo: Bool
        }
        private var framings: [Int64: Framing] = [:]

        func record(_ size: CGSize?, optimizedForDuo: Bool, for id: Int64) {
            lock.lock()
            defer { lock.unlock() }
            framings[id] = Framing(previewSize: size, optimizedForDuo: optimizedForDuo)
        }

        func take(_ id: Int64) -> Framing? {
            lock.lock()
            defer { lock.unlock() }
            return framings.removeValue(forKey: id)
        }
    }
    var lensMode: CameraCaptureMode = .back
    var flashMode: AVCaptureDevice.FlashMode = .off

    /// Cycles off → on → off. Auto is intentionally skipped for predictability.
    func toggleFlash() {
        flashMode = flashMode == .off ? .on : .off
    }

    /// True when flash is available — rear camera only, and only when supported
    /// by the current device input.
    var isFlashAvailable: Bool {
        lensMode.isRear && photoOutput.supportedFlashModes.contains(.on)
    }

    @ObservationIgnored private(set) var session = AVCaptureSession()
    private(set) var supportsSubjectPreview = false
    // The main camera owns the only capture preview connection. The outside
    // display consumes video buffers from that same single-camera session.
    @ObservationIgnored let primaryPreviewLayer = AVCaptureVideoPreviewLayer()
    @ObservationIgnored let subjectPreview = CameraSubjectFrameRenderer(displayLayer: AVSampleBufferDisplayLayer())
    private(set) var activeDevice: AVCaptureDevice?
    @ObservationIgnored private let subjectOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "outagain.camera.session")
    @ObservationIgnored private let lifecycleState = SessionLifecycleState()
    @ObservationIgnored private var isConfigured = false

    @discardableResult
    func beginPresentation(id: UUID = UUID()) -> UUID {
        let lifecycleState = lifecycleState
        sessionQueue.async {
            lifecycleState.activePresentationID = id
        }
        return id
    }

    func endPresentation(id: UUID) {
        let session = session
        let subjectPreview = subjectPreview
        let lifecycleState = lifecycleState
        sessionQueue.async {
            guard lifecycleState.activePresentationID == id else { return }
            lifecycleState.activePresentationID = nil
            lifecycleState.subjectPreviewEnabled = false
            if session.isRunning { session.stopRunning() }
            // Clear after capture stops, including any final queued frame.
            subjectPreview.setEnabled(false, clearFrame: true)
        }
    }

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

    func prepare(supportsSubjectPreview: Bool = false) async {
        if setupState == .ready {
            await startSessionIfNeeded()
            return
        }
        guard setupState != .preparing else { return }

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
            try await configureSession(supportsSubjectPreview: supportsSubjectPreview)
            setupState = .ready
            await startSessionIfNeeded()
        } catch {
            Logger(subsystem: "com.cristian.OutAgain", category: "Camera").error("Camera setup failed: \(error.localizedDescription, privacy: .public)")
            setupState = .failed(error.localizedDescription)
        }
    }

    nonisolated static func makeCaptureSession(supportsSubjectPreview: Bool) -> AVCaptureSession {
        // Two displays show one camera. MultiCam is unnecessary and can reject
        // the second connection, preventing even the main camera from opening.
        return AVCaptureSession()
    }

    func startSessionIfNeeded() async {
        guard setupState == .ready else { return }
        let session = session
        let lifecycleState = lifecycleState
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                defer { continuation.resume() }
                // An outstanding prepare can finish after the camera was closed.
                guard lifecycleState.activePresentationID != nil, !session.isRunning else { return }
                session.startRunning()
            }
        }
    }

    func setSubjectPreviewEnabled(_ enabled: Bool, presentationID: UUID) {
        let subjectPreview = subjectPreview
        let lifecycleState = lifecycleState
        sessionQueue.async {
            guard lifecycleState.activePresentationID == presentationID else { return }
            lifecycleState.subjectPreviewEnabled = enabled
            subjectPreview.setEnabled(enabled)
        }
    }

    func stopSession() {
        let session = session
        let subjectPreview = subjectPreview
        let lifecycleState = lifecycleState
        sessionQueue.async {
            lifecycleState.activePresentationID = nil
            lifecycleState.subjectPreviewEnabled = false
            if session.isRunning { session.stopRunning() }
            subjectPreview.setEnabled(false, clearFrame: true)
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
            // Flash is rear-only — reset when switching to front.
            if !lens.isRear { flashMode = .off }
            await startSessionIfNeeded()
        } catch {
            setupState = .failed(error.localizedDescription)
        }
    }

    func capturePhoto(optimizedForDuo: Bool = false) {
        guard setupState == .ready, !isCapturing else { return }

        isCapturing = true
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = false
        if photoOutput.isStillImageStabilizationSupported {
            settings.isAutoStillImageStabilizationEnabled = false
        }

        // Apply the current flash mode when flash is supported.
        if photoOutput.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }

        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = lensMode == .front
        }
        if optimizedForDuo, let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(captureRotationAngle) {
            connection.videoRotationAngle = captureRotationAngle
        }

        captureFramings.record(capturePreviewSize, optimizedForDuo: optimizedForDuo, for: settings.uniqueID)
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func clearCapture() {
        capturedPhotoData = nil
    }

    /// AVFoundation invokes this off the main thread; keep `fileDataRepresentation()`
    /// here so JPEG packaging does not block the UI thread (that was adding noticeable
    /// delay before the confirm-photo screen could appear).
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let framing = captureFramings.take(photo.resolvedSettings.uniqueID)
        if let error {
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isCapturing = false }
                self.setupState = .failed(error.localizedDescription)
            }
            return
        }

        // Ordinary phones retain their original capture bytes and framing.
        // The Duo guide is opt-in and frozen at the instant of the shutter.
        let data = photo.fileDataRepresentation().flatMap { originalData in
            if framing?.optimizedForDuo == true {
                return ImageCompressor.postCapture(from: originalData, previewSize: framing?.previewSize)
            }
            return originalData
        }
        guard let data else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isCapturing = false }
                self.setupState = .failed("Couldn't read photo data.")
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false }
            self.capturedPhotoData = data
        }
    }

    private func configureSession(supportsSubjectPreview: Bool) async throws {
        guard !isConfigured else { return }
        let photoOutput = photoOutput
        let primaryPreviewLayer = primaryPreviewLayer
        let subjectOutput = subjectOutput
        let subjectPreview = subjectPreview
        let initialLens = lensMode

        let configuredSession: AVCaptureSession = try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let session = Self.makeCaptureSession(supportsSubjectPreview: supportsSubjectPreview)
                do {
                    session.beginConfiguration()
                    session.sessionPreset = .photo

                    try Self.replaceVideoInput(on: session, with: initialLens)

                    guard session.canAddOutput(photoOutput) else {
                        throw CameraError.photoOutputUnavailable
                    }

                    session.addOutput(photoOutput)
                    photoOutput.isHighResolutionCaptureEnabled = false
                    primaryPreviewLayer.session = session
                    if supportsSubjectPreview && session.canAddOutput(subjectOutput) {
                        subjectOutput.alwaysDiscardsLateVideoFrames = true
                        subjectOutput.automaticallyConfiguresOutputBufferDimensions = false
                        subjectOutput.deliversPreviewSizedOutputBuffers = true
                        subjectOutput.setSampleBufferDelegate(subjectPreview, queue: subjectPreview.queue)
                        session.addOutput(subjectOutput)
                        Self.configureSubjectConnection(subjectOutput)
                    }
                    session.commitConfiguration()
                    continuation.resume(returning: session)
                } catch {
                    // Failed setup must release the shared outputs before a
                    // retry, rather than leaving them attached to a dead session.
                    primaryPreviewLayer.session = nil
                    session.outputs.forEach(session.removeOutput)
                    session.inputs.forEach(session.removeInput)
                    session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }

        session = configuredSession
        activeDevice = (configuredSession.inputs.first as? AVCaptureDeviceInput)?.device
        self.supportsSubjectPreview = configuredSession.outputs.contains { $0 === subjectOutput }
        isConfigured = true
    }

    private func configureCameraInput(for lens: CameraCaptureMode) async throws {
        let session = session
        let primaryPreviewLayer = primaryPreviewLayer
        let subjectPreview = subjectPreview
        let subjectOutput = subjectOutput
        let lifecycleState = lifecycleState

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    session.beginConfiguration()
                    try Self.replaceVideoInput(on: session, with: lens)
                    if !lens.isRear { lifecycleState.subjectPreviewEnabled = false }
                    if primaryPreviewLayer.session !== session { primaryPreviewLayer.session = session }
                    Self.configureSubjectConnection(subjectOutput)
                    subjectPreview.setEnabled(lifecycleState.subjectPreviewEnabled, clearFrame: true)
                    session.commitConfiguration()
                    continuation.resume()
                } catch {
                    session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }
        activeDevice = (session.inputs.first as? AVCaptureDeviceInput)?.device
    }

    nonisolated private static func configureSubjectConnection(_ output: AVCaptureVideoDataOutput) {
        guard let connection = output.connection(with: .video) else { return }
        // The accessory applies its own rotation and horizontal reflection.
        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
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

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            previousInputs.forEach { if session.canAddInput($0) { session.addInput($0) } }
            throw error
        }
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
    let previewLayer: AVCaptureVideoPreviewLayer
    let isMirrored: Bool
    var adaptsToDuoOrientation = false
    var onCaptureRotationChanged: (CGFloat) -> Void = { _ in }

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView(previewLayer: previewLayer)
        view.configure(isMirrored: isMirrored, adaptsToDuoOrientation: adaptsToDuoOrientation, onCaptureRotationChanged: onCaptureRotationChanged)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.configure(isMirrored: isMirrored, adaptsToDuoOrientation: adaptsToDuoOrientation, onCaptureRotationChanged: onCaptureRotationChanged)
    }

    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: ()) {
        uiView.detachPreview()
    }
}

final class PreviewContainerView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var deviceID: String?
    private var adaptsToDuoOrientation = false
    private var onCaptureRotationChanged: (CGFloat) -> Void = { _ in }

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(isMirrored: Bool, adaptsToDuoOrientation: Bool, onCaptureRotationChanged: @escaping (CGFloat) -> Void) {
        self.onCaptureRotationChanged = onCaptureRotationChanged
        self.adaptsToDuoOrientation = adaptsToDuoOrientation
        if !adaptsToDuoOrientation { clearRotationCoordinator() }
        // The session owns the connection. A SwiftUI layout update only updates
        // display properties, and never attaches another layer to the session.
        previewLayer.videoGravity = .resizeAspectFill
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring {
                connection.automaticallyAdjustsVideoMirroring = false
            }
            if connection.isVideoMirrored != isMirrored {
                connection.isVideoMirrored = isMirrored
            }
        }
        updateRotationCoordinator()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard previewLayer.superlayer === layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearRotationCoordinator() }
        else { updateRotationCoordinator(force: true) }
    }

    func detachPreview() {
        clearRotationCoordinator()
        // During rotation the replacement view may already own this layer.
        // The departing view must not remove it from its new host.
        if previewLayer.superlayer === layer { previewLayer.removeFromSuperlayer() }
    }

    private func clearRotationCoordinator() {
        previewRotationObservation = nil
        captureRotationObservation = nil
        rotationCoordinator = nil
        deviceID = nil
    }

    private func updateRotationCoordinator(force: Bool = false) {
        guard adaptsToDuoOrientation, window != nil, previewLayer.superlayer === layer else { return }
        guard let device = (previewLayer.session?.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        guard force || deviceID != device.uniqueID else { return }
        deviceID = device.uniqueID
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        onCaptureRotationChanged(coordinator.videoRotationAngleForHorizonLevelCapture)
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor [weak self] in
                guard let self, self.rotationCoordinator === coordinator,
                      self.previewLayer.superlayer === self.layer,
                      let connection = self.previewLayer.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                if connection.videoRotationAngle != angle { connection.videoRotationAngle = angle }
            }
        }
        captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            Task { @MainActor [weak self] in
                guard let self, self.rotationCoordinator === coordinator,
                      self.previewLayer.superlayer === self.layer else { return }
                self.onCaptureRotationChanged(angle)
            }
        }
    }
}
