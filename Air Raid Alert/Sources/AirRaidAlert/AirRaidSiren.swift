import AVFoundation
import Foundation

final class AirRaidSiren {
    private struct Fade {
        let start: TimeInterval
        let end: TimeInterval
        let startGain: Float

        func gain(at position: TimeInterval) -> Float {
            guard end > start else { return 0 }
            let fraction = min(1, max(0, (end - position) / (end - start)))
            return startGain * Float(fraction)
        }
    }

    private struct Voice {
        let player: AVAudioPlayer
        var fade: Fade?
    }

    private static let maximumFadeDuration: TimeInterval = 3
    private static let primaryGain: Float = 0.9
    // 内置素材峰值不超过 0.32，混音增益总和限制在 2.8，保留约 10% 峰值余量。
    private static let maximumMixGain: Float = 2.8
    private let recordingURL: URL? = {
        guard let url = Bundle.module.url(forResource: "air-raid-siren", withExtension: "wav") else {
            NSLog("未找到内置防空警报音")
            return nil
        }
        return url
    }()
    private var voices: [Voice] = []
    private var cleanupTimer: Timer?
    private var isPaused = false

    deinit { stop() }

    func play() {
        guard !isPaused, let recordingURL else { return }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: recordingURL)
        } catch {
            NSLog("无法读取内置防空警报音（%@）", error.localizedDescription)
            return
        }
        // 确认新声能启动，再让旧声淡出。新声无需等到旧声结束。
        player.volume = 0
        guard player.play() else { return }
        removeFinishedVoices()
        fadePreviousVoice()
        voices.append(Voice(player: player))
        player.volume = Self.primaryGain
        startCleanupTimer()
    }

    func pause() {
        guard !isPaused else { return }
        removeFinishedVoices()
        isPaused = true
        stopCleanupTimer()
        for voice in voices {
            voice.player.pause()
        }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        for voice in voices {
            let position = voice.player.currentTime
            if let fade = voice.fade {
                // 淡出以录音播放位置为准，恢复时只播放尚未过去的部分。
                voice.player.volume = fade.gain(at: position)
                if voice.player.play() {
                    voice.player.setVolume(0, fadeDuration: max(0, fade.end - position))
                }
            } else {
                voice.player.play()
            }
        }
        removeFinishedVoices()
        startCleanupTimer()
    }

    func stop() {
        stopCleanupTimer()
        for voice in voices { voice.player.stop() }
        voices.removeAll()
        isPaused = false
    }

    private func fadePreviousVoice() {
        guard let latest = voices.indices.last, voices[latest].fade == nil else { return }
        let player = voices[latest].player
        let position = player.currentTime
        let end = min(player.duration, position + Self.maximumFadeDuration)
        voices[latest].fade = Fade(start: position, end: end, startGain: Self.primaryGain)

        let positions = voices.map { $0.player.currentTime }
        let gains = zip(voices, positions).map { voice, position in voice.fade?.gain(at: position) ?? 0 }
        let budget = Self.maximumMixGain - Self.primaryGain
        let totalGain = gains.reduce(0, +)
        let scale = totalGain > budget ? budget / totalGain : 1

        for index in voices.indices where index == latest || scale < 1 {
            guard let fade = voices[index].fade else { continue }
            let position = positions[index]
            let gain = gains[index] * scale
            // 多声叠加时只调整混音增益，各条旧声的淡出截止仍保持原值。
            voices[index].fade = Fade(start: position, end: fade.end, startGain: gain)
            voices[index].player.volume = gain
            voices[index].player.setVolume(0, fadeDuration: max(0, fade.end - position))
        }
    }

    private func startCleanupTimer() {
        guard cleanupTimer == nil, !voices.isEmpty else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.removeFinishedVoices()
        }
        cleanupTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }

    private func removeFinishedVoices() {
        voices.removeAll { voice in
            guard voice.player.isPlaying else { return true }
            guard let fade = voice.fade, voice.player.currentTime >= fade.end else { return false }
            voice.player.stop()
            return true
        }
        if voices.isEmpty { stopCleanupTimer() }
    }
}
