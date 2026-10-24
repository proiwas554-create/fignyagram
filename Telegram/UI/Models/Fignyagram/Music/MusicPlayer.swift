import Foundation
import AVFoundation
import MediaPlayer
import Combine

enum MusicRepeatMode: String, CaseIterable {
    case off
    case all
    case one

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

/// Full-featured local player with queue, shuffle, repeat, scrubbing and
/// lock-screen controls. Lives independently from Telegram voice playback.
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    @Published private(set) var current: MusicTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffle = false
    @Published var repeatMode: MusicRepeatMode = .off
    @Published var playbackRate: Double = 1.0 {
        didSet { player?.rate = Float(playbackRate) }
    }

    private var player: AVPlayer?
    private var queue: [MusicTrack] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var metadataDuration: Double?
    private var handlingEnd = false
    private(set) var isScrubbing = false
    private var remoteCommandsConfigured = false
    private var nowPlayingArtwork: MPMediaItemArtwork?

    private init() {
        configureRemoteCommands()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.isPlaying = false
                case .ended:
                    let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                        self.resume()
                    }
                @unknown default:
                    break
                }
                self.updateNowPlaying()
            }
        }
    }

    func play(_ track: MusicTrack, queue: [MusicTrack]? = nil) {
        MusicLibrary.shared.markPlayed(track)
        if let queue {
            self.queue = queue
        } else if !self.queue.contains(where: { $0.id == track.id }) {
            self.queue = MusicLibrary.shared.tracks
        }
        if current?.id == track.id, player != nil {
            if !isPlaying { resume() }
            return
        }
        load(track, autoplay: true)
    }

    func togglePlayPause() {
        guard let player else {
            if let first = MusicLibrary.shared.tracks.first {
                play(first)
            }
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            activateAudioSession()
            player.play()
            player.rate = Float(playbackRate)
            isPlaying = true
        }
        updateNowPlaying()
    }

    func pauseIfPlaying() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    private func resume() {
        activateAudioSession()
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            AudioPlayback.activateAudioSessionOffMain()
        } catch {
            // Playback can still work with the current session.
        }
    }

    func next() {
        guard let current else { return }
        let tracks = queue.isEmpty ? MusicLibrary.shared.tracks : queue
        guard !tracks.isEmpty else { return }
        if shuffle {
            let candidates = tracks.filter { $0.id != current.id }
            if let random = candidates.randomElement() {
                load(random, autoplay: true)
            }
            return
        }
        guard let index = tracks.firstIndex(where: { $0.id == current.id }) else { return }
        let nextIndex = (index + 1) % tracks.count
        load(tracks[nextIndex], autoplay: true)
    }

    func previous() {
        guard let current else { return }
        let tracks = queue.isEmpty ? MusicLibrary.shared.tracks : queue
        guard !tracks.isEmpty else { return }
        if shuffle {
            let candidates = tracks.filter { $0.id != current.id }
            if let random = candidates.randomElement() {
                load(random, autoplay: true)
            }
            return
        }
        guard let index = tracks.firstIndex(where: { $0.id == current.id }) else { return }
        let previousIndex = (index - 1 + tracks.count) % tracks.count
        load(tracks[previousIndex], autoplay: true)
    }

    func beginScrubbing() { isScrubbing = true }
    func endScrubbing() { isScrubbing = false }

    /// Live seek while the user drags the slider. Uses a small tolerance so
    /// the audio and the thumb stay smooth instead of hard-seeking every frame.
    func previewSeek(to fraction: Double) {
        guard let player else { return }
        let actual = player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? 0
        let total = duration > 0 ? duration : actual
        let usable = total.isFinite && total > 0 ? total : duration
        guard usable > 0 else { return }
        let clamped = min(max(fraction, 0), 0.999)
        progress = clamped
        let target = CMTime(seconds: clamped * usable, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let actual = player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? 0
        let total = duration > 0 ? duration : (actual.isFinite && actual > 0 ? actual : duration)
        guard total > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        player.seek(to: CMTime(seconds: min(clamped, 0.999) * total, preferredTimescale: 600))
        progress = clamped
        updateNowPlaying()
    }

    func stop() {
        clearObservers()
        queue = []
        player?.pause()
        player = nil
        current = nil
        isPlaying = false
        progress = 0
        duration = 0
        nowPlayingArtwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func load(_ track: MusicTrack, autoplay: Bool) {
        clearObservers()
        activateAudioSession()

        let url = MusicLibrary.shared.url(for: track)
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            Task { @MainActor in
                guard let self, self.player?.currentItem === item else { return }
                // For files whose container duration includes trailing silence,
                // the metadata duration is the audible length.
                guard self.metadataDuration == nil else { return }
                self.applyDuration(seconds)
            }
        }
        player = newPlayer
        current = track
        metadataDuration = track.duration.flatMap { $0 > 0 ? Double($0) : nil }
        duration = metadataDuration ?? 0
        progress = 0
        handlingEnd = false
        nowPlayingArtwork = Self.artwork(for: track)

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, let item = self.player?.currentItem else { return }
                let seconds = CMTimeGetSeconds(time)
                if self.metadataDuration == nil {
                    self.applyDuration(CMTimeGetSeconds(item.duration))
                }
                let usableDuration = self.duration
                if usableDuration > 0, seconds.isFinite {
                    self.progress = min(max(seconds / usableDuration, 0), 1)
                }
                if let metadataDuration = self.metadataDuration,
                   seconds.isFinite,
                   seconds >= metadataDuration - 0.15 {
                    self.finishPlayback()
                    return
                }
                self.updateNowPlaying()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnded()
            }
        }

        if autoplay {
            newPlayer.play()
            newPlayer.rate = Float(playbackRate)
            isPlaying = true
        }
        updateNowPlaying()
    }

    private func applyDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0, seconds < 86_400 else { return }
        guard abs(seconds - duration) > 0.25 else { return }
        duration = seconds
        if progress > 0, let currentTime = player?.currentTime().seconds,
           currentTime.isFinite, currentTime > 0 {
            progress = min(max(currentTime / seconds, 0), 1)
        }
    }

    private func finishPlayback() {
        guard !handlingEnd else { return }
        handlingEnd = true
        player?.pause()
        isPlaying = false
        progress = 1
        updateNowPlaying()
        handlePlaybackEnded()
    }

    private func handlePlaybackEnded() {
        guard !isScrubbing else { return }
        guard !handlingEnd || progress >= 0.999 else { return }
        handlingEnd = false
        switch repeatMode {
        case .one:
            seek(to: 0)
            resume()
        case .off:
            let tracks = queue.isEmpty ? MusicLibrary.shared.tracks : queue
            if let current,
               let index = tracks.firstIndex(where: { $0.id == current.id }),
               index == tracks.count - 1, !shuffle {
                isPlaying = false
            } else {
                next()
            }
        case .all:
            next()
        }
    }

    private func clearObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        durationObservation?.invalidate()
        durationObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player?.pause()
                self?.isPlaying = false
                self?.updateNowPlaying()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.seek(to: seconds / self.duration)
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress * duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private static func artwork(for track: MusicTrack) -> MPMediaItemArtwork? {
        guard let url = MusicLibrary.shared.artworkURL(for: track),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
