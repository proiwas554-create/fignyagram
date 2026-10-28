import AVFoundation
import SwiftUI
import UIKit

/// Picks a video from the gallery for a round video message.
struct RoundVideoPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.mediaTypes = ["public.movie"]
        controller.sourceType = .photoLibrary
        controller.videoQuality = .typeHigh
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                onPick(url)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

/// Converts any gallery video into the square 640x640 H.264 clip Telegram shows
/// as a round video message (video note).
nonisolated enum RoundVideoConverter {
    static let side: CGFloat = 640

    static func convert(_ source: URL) async throws -> (url: URL, duration: Int) {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let seconds = max(1, min(60, Int(CMTimeGetSeconds(duration).rounded())))

        let composition = AVMutableComposition()
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let compositionTrack = composition.addMutableTrack(withMediaType: .video,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "RoundVideo", code: 1)
        }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: Double(seconds), preferredTimescale: 600))
        try compositionTrack.insertTimeRange(range, of: track, at: .zero)
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioTrack.insertTimeRange(range, of: audio, at: .zero)
        }

        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = natural.applying(transform)
        let crop = min(oriented.width, oriented.height)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        // Center-crop to a square, then scale it to 640x640.
        let cropRect = CGRect(x: (oriented.width - crop) / 2,
                              y: (oriented.height - crop) / 2,
                              width: crop, height: crop)
        var matrix = transform
        matrix = matrix.concatenating(CGAffineTransform(translationX: -cropRect.origin.x,
                                                        y: -cropRect.origin.y))
        matrix = matrix.concatenating(CGAffineTransform(scaleX: side / crop, y: side / crop))
        layerInstruction.setTransform(matrix, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = CGSize(width: side, height: side)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("round-\(UUID().uuidString).mp4")
        // Older devices get a cheaper encode: the 640x640 target is the same,
        // only the encoder effort differs.
        let lowMemory = ProcessInfo.processInfo.physicalMemory <= 3 * 1024 * 1024 * 1024
        let preset = lowMemory ? AVAssetExportPresetMediumQuality : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NSError(domain: "RoundVideo", code: 2)
        }
        export.outputURL = output
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? NSError(domain: "RoundVideo", code: 3)
        }
        return (output, seconds)
    }
}
