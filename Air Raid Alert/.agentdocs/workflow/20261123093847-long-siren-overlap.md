# 会话-9《躲避空袭》完整警报与三秒淡出叠播

## 背景与结果

- 旧版只保留实录开头 4.4 秒，录音播放完即停止。新版用同一 [Sounds Of Changes 实录](https://www.soundsofchanges.eu/sound/konrad-gutkowski-17/) 从第 0.24 秒保留至自然结束。警报包含启动升调、持续鸣响和自然回落。录音者与 CC BY 4.0（知识共享署名 4.0）许可继续随资源打包。
- 每次有效疏散通知启动独立播放器。当上一声还在播放时，它与新声短暂重叠，并在至多 3 秒内淡出。已经开始淡出的声部保持原截止时间。密集通知时限制混音峰值。
- 暂停以播放头冻结音频与淡出进度，继续后恢复剩余淡出时间。重开和退出停止所有声部，持续释放已经播放完或淡出的播放器。

## 二进制音频变更

- [警报 WAV](../../Sources/AirRaidAlert/Resources/air-raid-siren.wav) 从旧版 4.40000 秒，776204 字节，SHA-256 为 `4e073306897fbd458538e7a52183251497371d0fa1c57be8a76433029215b799` 替换为新版 29.99014 秒，5290304 字节，SHA-256 为 `407ecb5f5b6df979c0e68f141f7097074d04c1c2314a4556b10e61774e9fd093`。保持 44.1 kHz、16 位双声道。新版峰值限制在满幅的 32%，保留头尾平滑过渡。

## 测试方法与结果

- 原生音频工具和应用播放器均读取出 29.99 秒，且可解码双声道样本。构建产物中的音频和署名与源文件逐字节一致。
- 在可控的播放时间线上验证新声即时启动、第三次触发保持第一声的淡出截止、密集混音下的峰值保护、暂停与恢复、旧声清理，以及启动新播放器失败时原声继续。
- 执行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`，原有 7 项自动测试全部通过。
- 运行 `./run.sh --test-input`，开局约第 2 秒按 `3` 通知「石桥」，约第 4.5 秒按 `W` 通知「南陵」。在南陵警报起音时，核对石桥的警报仍可听见并在 3 秒内淡出。仅触发石桥一轮，可听到录音的持续段和自然收尾。当前命令行环境无法启动音频设备，扬声器试听待确认。

## 代码变更

### `Sources/AirRaidAlert/AirRaidSiren.swift`

```diff
diff --git a/Sources/AirRaidAlert/AirRaidSiren.swift b/Sources/AirRaidAlert/AirRaidSiren.swift
--- a/Sources/AirRaidAlert/AirRaidSiren.swift
+++ b/Sources/AirRaidAlert/AirRaidSiren.swift
@@ -2,76 +2,140 @@
 import Foundation
 
 final class AirRaidSiren {
-    private enum ResumeMode {
-        case continuePlayback
-        case restart
+    private struct Fade {
+        let start: TimeInterval
+        let end: TimeInterval
+        let startGain: Float
+
+        func gain(at position: TimeInterval) -> Float {
+            guard end > start else { return 0 }
+            let fraction = min(1, max(0, (end - position) / (end - start)))
+            return startGain * Float(fraction)
+        }
     }
 
-    private let player: AVAudioPlayer? = {
+    private struct Voice {
+        let player: AVAudioPlayer
+        var fade: Fade?
+    }
+
+    private static let maximumFadeDuration: TimeInterval = 3
+    private static let primaryGain: Float = 0.9
+    // 内置素材峰值不超过 0.32，混音增益总和限制在 2.8，保留约 10% 峰值余量。
+    private static let maximumMixGain: Float = 2.8
+    private let recordingURL: URL? = {
         guard let url = Bundle.module.url(forResource: "air-raid-siren", withExtension: "wav") else {
             NSLog("未找到内置防空警报音")
             return nil
         }
+        return url
+    }()
+    private var voices: [Voice] = []
+    private var cleanupTimer: Timer?
+    private var isPaused = false
+
+    deinit { stop() }
+
+    func play() {
+        guard !isPaused, let recordingURL else { return }
+        let player: AVAudioPlayer
         do {
-            let player = try AVAudioPlayer(contentsOf: url)
-            player.prepareToPlay()
-            return player
+            player = try AVAudioPlayer(contentsOf: recordingURL)
         } catch {
             NSLog("无法读取内置防空警报音（%@）", error.localizedDescription)
-            return nil
-        }
-    }()
-    private var pendingRestart: DispatchWorkItem?
-    private var resumeMode: ResumeMode?
-
-    func play() {
-        guard let player, pendingRestart == nil, resumeMode == nil else { return }
-        guard player.isPlaying else {
-            startFromBeginning()
             return
         }
-
-        // 前一声仍在播放时先短暂淡出，重响也只使用同一个播放器。
-        let fadeDuration = 0.04
-        player.setVolume(0, fadeDuration: fadeDuration)
-        let restart = DispatchWorkItem { [weak self] in self?.startFromBeginning() }
-        pendingRestart = restart
-        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration, execute: restart)
+        // 确认新声能启动，再让旧声淡出。新声无需等到旧声结束。
+        player.volume = 0
+        guard player.play() else { return }
+        removeFinishedVoices()
+        fadePreviousVoice()
+        voices.append(Voice(player: player))
+        player.volume = Self.primaryGain
+        startCleanupTimer()
     }
 
     func pause() {
-        guard let player else { return }
-        if let pendingRestart {
-            pendingRestart.cancel()
-            self.pendingRestart = nil
-            resumeMode = .restart
-        } else if player.isPlaying {
-            resumeMode = .continuePlayback
+        guard !isPaused else { return }
+        removeFinishedVoices()
+        isPaused = true
+        stopCleanupTimer()
+        for voice in voices {
+            voice.player.pause()
         }
-        player.pause()
     }
 
     func resume() {
-        guard let resumeMode else { return }
-        self.resumeMode = nil
-        switch resumeMode {
-        case .continuePlayback: player?.play()
-        case .restart: startFromBeginning()
+        guard isPaused else { return }
+        isPaused = false
+        for voice in voices {
+            let position = voice.player.currentTime
+            if let fade = voice.fade {
+                // 淡出以录音播放位置为准，恢复时只播放尚未过去的部分。
+                voice.player.volume = fade.gain(at: position)
+                if voice.player.play() {
+                    voice.player.setVolume(0, fadeDuration: max(0, fade.end - position))
+                }
+            } else {
+                voice.player.play()
+            }
+        }
+        removeFinishedVoices()
+        startCleanupTimer()
+    }
+
+    func stop() {
+        stopCleanupTimer()
+        for voice in voices { voice.player.stop() }
+        voices.removeAll()
+        isPaused = false
+    }
+
+    private func fadePreviousVoice() {
+        guard let latest = voices.indices.last, voices[latest].fade == nil else { return }
+        let player = voices[latest].player
+        let position = player.currentTime
+        let end = min(player.duration, position + Self.maximumFadeDuration)
+        voices[latest].fade = Fade(start: position, end: end, startGain: Self.primaryGain)
+
+        let positions = voices.map { $0.player.currentTime }
+        let gains = zip(voices, positions).map { voice, position in voice.fade?.gain(at: position) ?? 0 }
+        let budget = Self.maximumMixGain - Self.primaryGain
+        let totalGain = gains.reduce(0, +)
+        let scale = totalGain > budget ? budget / totalGain : 1
+
+        for index in voices.indices where index == latest || scale < 1 {
+            guard let fade = voices[index].fade else { continue }
+            let position = positions[index]
+            let gain = gains[index] * scale
+            // 多声叠加时只调整混音增益，各条旧声的淡出截止仍保持原值。
+            voices[index].fade = Fade(start: position, end: fade.end, startGain: gain)
+            voices[index].player.volume = gain
+            voices[index].player.setVolume(0, fadeDuration: max(0, fade.end - position))
         }
     }
 
-    func stop() {
-        pendingRestart?.cancel()
-        pendingRestart = nil
-        resumeMode = nil
-        player?.stop()
-        player?.currentTime = 0
+    private func startCleanupTimer() {
+        guard cleanupTimer == nil, !voices.isEmpty else { return }
+        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
+            self?.removeFinishedVoices()
+        }
+        cleanupTimer = timer
+        RunLoop.main.add(timer, forMode: .common)
     }
 
-    private func startFromBeginning() {
-        pendingRestart = nil
-        player?.currentTime = 0
-        player?.volume = 1
-        player?.play()
+    private func stopCleanupTimer() {
+        cleanupTimer?.invalidate()
+        cleanupTimer = nil
+    }
+
+    private func removeFinishedVoices() {
+        voices.removeAll { voice in
+            guard voice.player.isPlaying else { return true }
+            guard let fade = voice.fade, voice.player.currentTime >= fade.end else { return false }
+            voice.player.stop()
+            return true
+        }
+        if voices.isEmpty { stopCleanupTimer() }
     }
 }
```

### `Sources/AirRaidAlert/Resources/siren-attribution.txt`

```diff
diff --git a/Sources/AirRaidAlert/Resources/siren-attribution.txt b/Sources/AirRaidAlert/Resources/siren-attribution.txt
--- a/Sources/AirRaidAlert/Resources/siren-attribution.txt
+++ b/Sources/AirRaidAlert/Resources/siren-attribution.txt
@@ -8,4 +8,4 @@
 许可为知识共享署名 4.0 国际（CC BY 4.0）。
 https://creativecommons.org/licenses/by/4.0/
 
-《躲避空袭》使用原录音 0.24–4.64 秒的片段，降低峰值并在头尾加入淡入、淡出。
+《躲避空袭》从原录音第 0.24 秒播放到自然结束，降低峰值并在头尾加入淡入、淡出。
```
