import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum CameraRollSaveError: LocalizedError, Equatable {
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
        try await save(media: [media])
    }

    func save(media: [MomentMedia]) async throws {
        guard !media.isEmpty else { return }
        switch await authorizationStatus() {
        case .authorized, .limited:
            break
        case .restricted:
            throw CameraRollSaveError.permissionRestricted
        default:
            throw CameraRollSaveError.permissionDenied
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("outagain-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Prepare the originals on disk before one Photos transaction. A failed
        // download leaves the library untouched, so retrying won't add duplicates.
        var files: [URL] = []
        for photo in media {
            try Task.checkCancellation()
            let file = try await prepareImageFile(photoData: photo.photoData,
                                                  remotePhotoURL: photo.remotePhotoURL,
                                                  in: directory)
            files.append(file)
        }

        try Task.checkCancellation()
        let preparedFiles = files
        try await PHPhotoLibrary.shared().performChanges {
            for file in preparedFiles {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
        }
    }

    private func authorizationStatus() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard currentStatus == .notDetermined else { return currentStatus }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    @concurrent
    private func prepareImageFile(photoData: Data?, remotePhotoURL: URL?, in directory: URL) async throws -> URL {
        let temporaryFile = directory.appendingPathComponent(UUID().uuidString)
        if let photoData {
            try photoData.write(to: temporaryFile, options: .atomic)
        } else if let remotePhotoURL {
            let (download, response) = try await URLSession.shared.download(from: remotePhotoURL)
            defer { try? FileManager.default.removeItem(at: download) }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode) else {
                throw CameraRollSaveError.downloadFailed
            }
            try FileManager.default.moveItem(at: download, to: temporaryFile)
        } else {
            throw CameraRollSaveError.missingImage
        }

        guard let source = CGImageSourceCreateWithURL(temporaryFile as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source),
              let fileExtension = UTType(type as String)?.preferredFilenameExtension else {
            throw CameraRollSaveError.unreadableImage
        }
        let file = temporaryFile.appendingPathExtension(fileExtension)
        try FileManager.default.moveItem(at: temporaryFile, to: file)
        return file
    }
}
