# 会话-8《躲避空袭》防空警报实录

## 来源与处理

- 使用 [Sounds Of Changes 的《Siren》现场录音](https://www.soundsofchanges.eu/sound/konrad-gutkowski-17/)。录音者为 Konrad Gutkowski 与 Jonathan Nicolai，机构为 Work With Sounds，2015 年录于德国多特蒙德 LWL 工业博物馆。馆藏 Elektror S0 KB 机械警报器曾用于民防。
- 录音使用 [知识共享署名 4.0 国际许可](https://creativecommons.org/licenses/by/4.0/)。来源、录音者、许可和处理说明随资源包中的 `siren-attribution.txt` 一同分发。
- 使用原始 WAV 的 0.24–4.64 秒，保留机械起音的升调及立体声。仅降低峰值，并加入 60 毫秒淡入和 400 毫秒淡出。
- [游戏使用的录音片段](../../Sources/AirRaidAlert/Resources/air-raid-siren.wav) 为 4.4 秒、44.1 kHz、16 位双声道 WAV。文件大小为 776204 字节，SHA-256 为 `4e073306897fbd458538e7a52183251497371d0fa1c57be8a76433029215b799`。二进制素材使用格式和校验值记录。

## 游戏接入与验证

- Swift Package Manager（Swift 包管理器）在构建时复制音频与署名。应用使用 `Bundle.module` 获取录音，并通过 macOS 原生播放器预备播放。有效通知触发警报，播放继续遵循暂停、恢复和再次通知时淡出重响的规则。
- 构建产物中的 WAV 和署名文件均与源码资源逐字节一致。原生播放器可读取 4.4 秒时长，原生解码可读双声道样本。7 项已有自动测试全部通过。
- 启动 `./run.sh --test-input`，开局约第 2 秒等「石桥」亮黄警后按 `3`，试听机械警报器升调并检查居民疏散。也可直接打开游戏使用的录音片段试听。

## 代码变更

### `Package.swift`

```diff
diff --git a/Package.swift b/Package.swift
--- a/Package.swift
+++ b/Package.swift
@@ -5,7 +5,13 @@
     name: "AirRaidAlert",
     platforms: [.macOS(.v12)],
     targets: [
-        .executableTarget(name: "AirRaidAlert"),
+        .executableTarget(
+            name: "AirRaidAlert",
+            resources: [
+                .copy("Resources/air-raid-siren.wav"),
+                .copy("Resources/siren-attribution.txt")
+            ]
+        ),
         .testTarget(name: "AirRaidAlertTests", dependencies: ["AirRaidAlert"])
     ]
 )
```

### `Sources/AirRaidAlert/AirRaidSiren.swift`

```diff
diff --git a/Sources/AirRaidAlert/AirRaidSiren.swift b/Sources/AirRaidAlert/AirRaidSiren.swift
--- a/Sources/AirRaidAlert/AirRaidSiren.swift
+++ b/Sources/AirRaidAlert/AirRaidSiren.swift
@@ -7,7 +7,20 @@
         case restart
     }
 
-    private let player = try? AVAudioPlayer(data: AirRaidSiren.makeSirenWAV())
+    private let player: AVAudioPlayer? = {
+        guard let url = Bundle.module.url(forResource: "air-raid-siren", withExtension: "wav") else {
+            NSLog("未找到内置防空警报音")
+            return nil
+        }
+        do {
+            let player = try AVAudioPlayer(contentsOf: url)
+            player.prepareToPlay()
+            return player
+        } catch {
+            NSLog("无法读取内置防空警报音（%@）", error.localizedDescription)
+            return nil
+        }
+    }()
     private var pendingRestart: DispatchWorkItem?
     private var resumeMode: ResumeMode?
 
@@ -61,59 +74,4 @@
         player?.volume = 1
         player?.play()
     }
-
-    private static func makeSirenWAV() -> Data {
-        let sampleRate: UInt32 = 24_000
-        let duration = 2.6
-        let sampleCount = Int(duration * Double(sampleRate))
-        let revolution = 2 * Double.pi
-        var motorPhase = 0.0
-        var upperPhase = 0.0
-        var samples: [Int16] = []
-        samples.reserveCapacity(sampleCount)
-
-        for frame in 0..<sampleCount {
-            let time = Double(frame) / Double(sampleRate)
-            // 模拟机械警报器的两次升转速和回落，连续累加相位，避免突变。
-            let swell = 0.5 - 0.5 * cos(revolution * time / 1.28)
-            let frequency = 320 + 355 * pow(swell, 0.78)
-            let phaseStep = revolution * frequency / Double(sampleRate)
-            motorPhase += phaseStep
-            upperPhase += phaseStep * 1.21
-            let fundamental = 0.58 * sin(motorPhase)
-            let upperRotor = 0.23 * sin(upperPhase)
-            let harmonics = 0.13 * sin(2 * motorPhase) + 0.06 * sin(3 * motorPhase)
-            let attack = smoothstep(min(1, time / 0.13))
-            let release = smoothstep(min(1, (duration - time) / 0.26))
-            let envelope = attack * release * (0.38 + 0.62 * swell)
-            let sample = Int16((fundamental + upperRotor + harmonics) * envelope * 0.44 * Double(Int16.max))
-            samples.append(sample.littleEndian)
-        }
-
-        // 写入单声道 16 位 PCM（脉冲编码调制）的 WAV 头，避免绑定外部音频素材。
-        let byteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
-        var data = Data("RIFF".utf8)
-        appendLittleEndian(byteCount + 36, to: &data)
-        data.append(contentsOf: "WAVEfmt ".utf8)
-        appendLittleEndian(UInt32(16), to: &data)
-        appendLittleEndian(UInt16(1), to: &data)
-        appendLittleEndian(UInt16(1), to: &data)
-        appendLittleEndian(sampleRate, to: &data)
-        appendLittleEndian(sampleRate * 2, to: &data)
-        appendLittleEndian(UInt16(2), to: &data)
-        appendLittleEndian(UInt16(16), to: &data)
-        data.append(contentsOf: "data".utf8)
-        appendLittleEndian(byteCount, to: &data)
-        samples.withUnsafeBytes { data.append(contentsOf: $0) }
-        return data
-    }
-
-    private static func smoothstep(_ progress: Double) -> Double {
-        progress * progress * (3 - 2 * progress)
-    }
-
-    private static func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer, to data: inout Data) {
-        var bytes = value.littleEndian
-        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
-    }
 }
```

### `Sources/AirRaidAlert/Resources/siren-attribution.txt`

```diff
diff --git a/Sources/AirRaidAlert/Resources/siren-attribution.txt b/Sources/AirRaidAlert/Resources/siren-attribution.txt
new file mode 100644
--- /dev/null
+++ b/Sources/AirRaidAlert/Resources/siren-attribution.txt
@@ -0,0 +1,11 @@
+《Siren》，Elektror S0 KB 民防警报器实录
+录音者为 Konrad Gutkowski 与 Jonathan Nicolai，机构为 Work With Sounds。
+2015 年 3 月 13 日录于德国多特蒙德 LWL 工业博物馆 Zeche Zollern。
+
+原始录音与档案
+https://www.soundsofchanges.eu/sound/konrad-gutkowski-17/
+
+许可为知识共享署名 4.0 国际（CC BY 4.0）。
+https://creativecommons.org/licenses/by/4.0/
+
+《躲避空袭》使用原录音 0.24–4.64 秒的片段，降低峰值并在头尾加入淡入、淡出。
```
