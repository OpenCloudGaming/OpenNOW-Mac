//
//  SessionAdPlaybackModel.swift
//  OpenNOW
//
//  Plays the sponsored message a free-tier session requires before it continues. The player, its
//  observers and the countdown live here rather than in the overlay, so their lifetime is tied to
//  an object the view owns rather than to a view body that can be rebuilt at any time.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class SessionAdPlaybackModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var remainingSeconds = 0

    /// Watched time in milliseconds.
    var onFinished: ((Int) -> Void)?
    var onFailed: ((String) -> Void)?

    private var ad: CatalogStreamAdPlayback?
    private var item: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    var startedAt = Date()
    private var didFinish = false

    func start(ad: CatalogStreamAdPlayback, volume: Double) {
        guard player == nil else { return }
        self.ad = ad
        guard let url = URL(string: ad.mediaUrl) else {
            fail("Required ad media URL is invalid.")
            return
        }
        startedAt = Date()
        remainingSeconds = max(1, Int(ceil(Double(ad.durationMs) / 1000.0)))
        let nextItem = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: nextItem)
        nextPlayer.volume = Float(volume)
        item = nextItem
        player = nextPlayer
        statusObservation = nextItem.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard observedItem.status == .failed else { return }
                self?.fail(observedItem.error?.localizedDescription ?? "Required ad failed to load.")
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nextItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        nextPlayer.play()
    }

    func stop() {
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        item = nil
    }

    func setVolume(_ volume: Double) {
        player?.volume = Float(volume)
    }

    /// The ad's own duration when the manifest stated one, and the item's otherwise.
    func updateCountdown() {
        guard let player, let ad else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let knownDuration = Double(ad.durationMs) / 1000.0
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let duration = knownDuration > 0 ? knownDuration : (itemDuration.isFinite ? itemDuration : 0)
        remainingSeconds = duration > 0 ? max(0, Int(ceil(duration - elapsed))) : 0
    }

    var countdownText: String {
        let minutes = max(0, remainingSeconds) / 60
        let seconds = max(0, remainingSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        let watchedTimeInMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        stop()
        onFinished?(watchedTimeInMs)
    }

    private func fail(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        stop()
        onFailed?(message)
    }
}
