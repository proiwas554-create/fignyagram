import Foundation
import UIKit
import SwiftUI
import Photos
import TDLibKit

extension TDLibKit.MessageContent {
    /// File that can be saved to Photos/Files from the long-press menu.
    var saveableFile: TDLibKit.File? {
        switch self {
        case .messagePhoto(let photo):
            return photo.photo.sizes.last?.photo
        case .messageVideo(let video):
            return video.video.video
        case .messageAnimation(let animation):
            return animation.animation.animation
        case .messageDocument(let document):
            return document.document.document
        case .messageAudio(let audio):
            return audio.audio.audio
        case .messageVoiceNote(let voice):
            return voice.voiceNote.voice
        case .messageVideoNote(let note):
            return note.videoNote.video
        case .messageSticker(let sticker):
            return sticker.sticker.sticker
        default:
            return nil
        }
    }

    var isPhotoMedia: Bool {
        if case .messagePhoto = self { return true }
        return false
    }

    var isVideoMedia: Bool {
        switch self {
        case .messageVideo, .messageAnimation, .messageVideoNote: return true
        default: return false
        }
    }
}

private enum MediaSaveError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

enum MediaSaver {
    /// Saves a local photo/video into the system Photos library.
    static func saveToPhotos(_ url: URL, isVideo: Bool) async -> String? {
        let status = await requestAddAccess()
        guard status == .authorized || status == .limited else {
            return NSLocalizedString("Generated.81be0b7f5dd2", comment: "")
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                PHPhotoLibrary.shared().performChanges {
                    if isVideo {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                } completionHandler: { success, error in
                    if success {
                        continuation.resume()
                    } else if let error {
                        continuation.resume(throwing: MediaSaveError.failed(error.localizedDescription))
                    } else {
                        continuation.resume(throwing: MediaSaveError.failed(NSLocalizedString("Generated.98a56efede32", comment: "")))
                    }
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Saves several already-converted images in one Photos transaction.
    static func saveImagesToPhotos(_ urls: [URL]) async -> String? {
        guard !urls.isEmpty else { return NSLocalizedString("Generated.dc808823c984", comment: "") }
        let status = await requestAddAccess()
        guard status == .authorized || status == .limited else {
            return NSLocalizedString("Generated.81be0b7f5dd2", comment: "")
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                PHPhotoLibrary.shared().performChanges {
                    for url in urls {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                } completionHandler: { success, error in
                    if success {
                        continuation.resume()
                    } else if let error {
                        continuation.resume(throwing: MediaSaveError.failed(error.localizedDescription))
                    } else {
                        continuation.resume(throwing: MediaSaveError.failed(NSLocalizedString("Generated.7bbd1483e22b", comment: "")))
                    }
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func requestAddAccess() async -> PHAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
