import Foundation
import Photos
import UIKit

enum CameraRollSaveError: LocalizedError {
    case missingImage
    case unreadableImage
    case permissionDenied
    case permissionRestricted
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .missingImage:
            return "This post doesn't have a photo to save yet."
        case .unreadableImage:
            return "We couldn't prepare that photo for saving."
        case .permissionDenied:
            return "Allow photo library access to save this image to your camera roll."
        case .permissionRestricted:
            return "Photo library access is restricted on this device."
        case .downloadFailed:
            return "We couldn't download that photo right now."
        }
    }
}

struct CameraRollSaver {
    func save(media: MomentMedia) async throws {
        switch await authorizationStatus() {
        case .authorized, .limited:
            break
        case .restricted:
            throw CameraRollSaveError.permissionRestricted
        default:
            throw CameraRollSaveError.permissionDenied
        }

        let imageData = try await resolveImageData(for: media)
        guard let image = UIImage(data: imageData) else {
            throw CameraRollSaveError.unreadableImage
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    private func authorizationStatus() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard currentStatus == .notDetermined else { return currentStatus }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    private func resolveImageData(for media: MomentMedia) async throws -> Data {
        if let photoData = media.photoData {
            return photoData
        }

        guard let remotePhotoURL = media.remotePhotoURL else {
            throw CameraRollSaveError.missingImage
        }

        let (data, response) = try await URLSession.shared.data(from: remotePhotoURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            throw CameraRollSaveError.downloadFailed
        }

        return data
    }
}
