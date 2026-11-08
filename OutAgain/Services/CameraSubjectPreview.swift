@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// A second viewfinder for one camera, without a second capture connection.
/// The serial queue retains at most one frame while hidden, so enabling the
/// accessory can display the latest image immediately without restarting capture.
nonisolated final class CameraSubjectFrameRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    @MainActor let displayLayer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    let queue = DispatchQueue(label: "outagain.camera.subject", qos: .userInteractive)
    private var isEnabled = false
    private var latestFrame: CMSampleBuffer?

    @MainActor
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        renderer = displayLayer.sampleBufferRenderer
        super.init()
    }

    func setEnabled(_ enabled: Bool, clearFrame: Bool = false) {
        queue.async {
            self.isEnabled = enabled
            if clearFrame {
                self.latestFrame = nil
                self.renderer.flush(removingDisplayedImage: true)
            }
            if enabled, let frame = self.latestFrame { self.display(frame) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        consume(sampleBuffer)
    }

    /// Called on the same serial queue as the capture delegate and toggles.
    func consume(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        latestFrame = sampleBuffer
        if isEnabled { display(sampleBuffer) }
    }

    private func display(_ frame: CMSampleBuffer) {
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: true) {
            let properties = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(properties,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(frame)
    }
}

struct CameraSubjectPreviewView: UIViewRepresentable {
    let renderer: CameraSubjectFrameRenderer
    let device: AVCaptureDevice?

    func makeUIView(context: Context) -> CameraSubjectPreviewContainer {
        let view = CameraSubjectPreviewContainer(displayLayer: renderer.displayLayer)
        view.configure(device: device)
        return view
    }

    func updateUIView(_ uiView: CameraSubjectPreviewContainer, context: Context) {
        uiView.configure(device: device)
    }

    static func dismantleUIView(_ uiView: CameraSubjectPreviewContainer, coordinator: ()) {
        uiView.detachPreview()
    }
}

/// The accessory's own layer drives rotation, because the two displays may
/// have different orientations. Transform preview pixels, never captured photos.
final class CameraSubjectPreviewContainer: UIView {
    let displayLayer: AVSampleBufferDisplayLayer
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var rotationAngle: CGFloat = 0

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        displayLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(device: AVCaptureDevice?) {
        guard self.device !== device || rotationCoordinator == nil else { return }
        self.device = device
        updateRotationCoordinator()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRotationCoordinator()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard displayLayer.superlayer === layer else { return }
        let radians = rotationAngle * .pi / 180
        let swapsAxes = abs(sin(radians)) > 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.bounds = CGRect(origin: .zero, size: swapsAxes
            ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1).rotated(by: radians))
        CATransaction.commit()
    }

    func detachPreview() {
        rotationObservation = nil
        rotationCoordinator = nil
        if displayLayer.superlayer === layer { displayLayer.removeFromSuperlayer() }
    }

    private func updateRotationCoordinator() {
        rotationObservation = nil
        rotationCoordinator = nil
        guard window != nil, let device, displayLayer.superlayer === layer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: displayLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor [weak self] in
                guard let self, self.rotationCoordinator === coordinator else { return }
                self.rotationAngle = angle
                self.setNeedsLayout()
            }
        }
    }
}
