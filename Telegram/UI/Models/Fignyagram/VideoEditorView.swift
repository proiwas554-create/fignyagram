import SwiftUI
import AVFoundation
import AVKit

/// Basic but practical video editor: trim range and mute audio, exported as MP4.
struct VideoEditorView: View {
    let prepared: MediaPreparer.Prepared
    let onDone: (MediaPreparer.Prepared) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var duration: Double
    @State private var start: Double = 0
    @State private var end: Double
    @State private var muted = false
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var errorText: String?

    private let asset: AVURLAsset

    init(prepared: MediaPreparer.Prepared, onDone: @escaping (MediaPreparer.Prepared) -> Void) {
        self.prepared = prepared
        self.onDone = onDone
        let asset = AVURLAsset(url: prepared.url)
        self.asset = asset
        let seconds = max(asset.duration.seconds.isFinite ? asset.duration.seconds : 0, 0.1)
        _duration = State(initialValue: seconds)
        _end = State(initialValue: seconds)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if let player {
                    VideoPlayer(player: player)
                        .frame(maxHeight: 360)
                        .background(Color.black)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                }

                VStack(spacing: 10) {
                    HStack {
                        Text("Начало")
                        Spacer()
                        Text(time(start))
                            .monospacedDigit()
                    }
                    .font(.appCaption)

                    Slider(value: Binding(
                        get: { start },
                        set: { value in
                            start = min(value, max(0, end - 0.3))
                            seek(start)
                        }
                    ), in: 0...max(duration, 0.3))

                    HStack {
                        Text("Конец")
                        Spacer()
                        Text(time(end))
                            .monospacedDigit()
                    }
                    .font(.appCaption)

                    Slider(value: Binding(
                        get: { end },
                        set: { value in
                            end = max(value, min(duration, start + 0.3))
                            seek(start)
                        }
                    ), in: 0...max(duration, 0.3))

                    HStack {
                        Text("Длительность: \(time(end - start))")
                            .font(.appFootnote)
                        Spacer()
                        Toggle("Без звука", isOn: $muted)
                            .labelsHidden()
                        Text("Без звука")
                            .font(.appFootnote)
                    }
                }
                .padding(.horizontal, 18)

                Button("Сбросить обрезку") {
                    start = 0
                    end = duration
                    seek(0)
                }
                .font(.appFootnote)

                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .navigationTitle("Видеоредактор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isExporting ? "Сохранение…" : "Готово") {
                        export()
                    }
                    .disabled(isExporting || end - start < 0.3)
                }
            }
            .overlay {
                if isExporting {
                    VStack(spacing: 10) {
                        ProgressView(value: progress)
                            .frame(width: 180)
                        Text("Обработка видео…").font(.appFootnote)
                        if let errorText {
                            Text(errorText)
                                .font(.appCaption)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onAppear {
                let player = AVPlayer(url: prepared.url)
                player.isMuted = muted
                self.player = player
            }
            .onDisappear {
                player?.pause()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func seek(_ time: Double) {
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func export() {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        errorText = nil

        let output = TelegramClient.makeOutgoingURL(extension: "mp4")
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1280x720
        ) else {
            errorText = "Не удалось создать экспорт видео"
            isExporting = false
            return
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )

        if muted, let audioTrack = asset.tracks(withMediaType: .audio).first {
            let mix = AVMutableAudioMix()
            let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
            parameters.setVolume(0, at: .zero)
            mix.inputParameters = [parameters]
            session.audioMix = mix
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { timer in
            Task { @MainActor in
                progress = Double(session.progress)
                if session.status == .completed || session.status == .failed || session.status == .cancelled {
                    timer.invalidate()
                }
            }
        }

        session.exportAsynchronously {
            DispatchQueue.main.async {
                timer.invalidate()
                isExporting = false
                switch session.status {
                case .completed:
                    onDone(MediaPreparer.Prepared(
                        url: output,
                        width: prepared.width,
                        height: prepared.height,
                        duration: max(1, Int((end - start).rounded()))
                    ))
                    dismiss()
                case .failed, .cancelled:
                    errorText = session.error?.localizedDescription ?? "Не удалось обработать видео"
                default:
                    errorText = "Видео не было обработано"
                }
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
