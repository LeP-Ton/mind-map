# 会话-7《躲避空袭》城镇键与防空警报音

## 背景与结果

- 主屏和实体 Touch Bar（触控条）共用模型中的 16 个双字城镇名，次序和键位仍按地图逐行对应。联调用键盘映射继续按位置触发。
- 触控条改为整行自适应容器。按键随系统分配的应用区等宽铺开，四键一组。容器宽度变化时重新布局，两侧按键贴边，预警、已通知等状态颜色和点击行为继续由仿真驱动。
- 每次成功发送疏散通知会立即播放约 2.6 秒、两次起伏的合成警报。短时间内连续成功通知，单个播放器短暂淡出后重响。暂停冻结音效，继续时恢复，重开或退出会停止。
- 使用 macOS 原生音频播放。波形在应用内部生成，包含平滑包络与适中的峰值。此次没有新增外部音频素材。

## 测试方法与结果

- 用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` 运行 7 项自动测试，全部通过。覆盖城镇命名与原有预警、疏散和结算逻辑。
- AppKit 离屏检查验证了 240–1200 pt 范围内的八档容器宽度。16 键等宽，首末键触达左右边缘，预警色、暂停禁用和点击路由符合预期。两档主窗口尺寸均能看到完整中文城镇名。
- 原生解码验证警报为 2.6 秒单声道波形，首尾平滑，两次升降清楚，峰值低于削波上限。本次没有通过扬声器试听。
- 已用 `./run.sh --test-input` 构建并启动新版。本机未能获取实体 Touch Bar，实际占宽待设备验证。运行 `./run.sh` 后，在约第 2 秒轻触亮黄预警的「石桥」，核对触控条颜色、警报音和居民开始疏散。键盘测试模式可在相同时机按 `3` 验证。

## 代码变更

### `Sources/AirRaidAlert/Simulation.swift`

```diff
diff --git a/Sources/AirRaidAlert/Simulation.swift b/Sources/AirRaidAlert/Simulation.swift
--- a/Sources/AirRaidAlert/Simulation.swift
+++ b/Sources/AirRaidAlert/Simulation.swift
@@ -27,6 +27,7 @@
 
 struct CityState {
     let id: Int
+    let name: String
     let map: CityMap
     fileprivate(set) var residents: [Resident]
     fileprivate(set) var warning: WarningPhase?
@@ -98,7 +99,14 @@
         let kind: EventKind
     }
 
-    private static let cityCount = 16
+    // 顺序对应地图的从左到右、从上到下，也是触控条的排列顺序。
+    private static let cityNames = [
+        "松浦", "柳溪", "石桥", "云津",
+        "枫湾", "南陵", "竹塘", "青川",
+        "白沙", "榆关", "杏村", "临汀",
+        "蒲渡", "桂岭", "安泽", "鹤台"
+    ]
+    private static let cityCount = cityNames.count
     private static let residentsPerCity = 125
     private static let maximumMovementStep: TimeInterval = 1.0 / 30
 
@@ -119,13 +127,14 @@
 
     init(seed: UInt64 = 0x4152_4149_4C45_5254) {
         var random = SimulationRandom(state: seed)
-        let cities = (1...Self.cityCount).map { id in
+        let cities = Self.cityNames.enumerated().map { index, name in
             let map = CityMap.make(seed: random.next())
             let residents = (0..<Self.residentsPerCity).map { _ in
                 Self.makeResident(on: map.roads, random: &random)
             }
             return CityState(
-                id: id,
+                id: index + 1,
+                name: name,
                 map: map,
                 residents: residents,
                 shelterRoutes: Self.findShelterRoutes(in: map)
```

### `Sources/AirRaidAlert/GameView.swift`

```diff
diff --git a/Sources/AirRaidAlert/GameView.swift b/Sources/AirRaidAlert/GameView.swift
--- a/Sources/AirRaidAlert/GameView.swift
+++ b/Sources/AirRaidAlert/GameView.swift
@@ -140,11 +140,11 @@
         context.restoreGState()
 
         let labelColor = city.warning.map(warningColor) ?? (city.notified ? shelterInk : paperInk)
-        let labelRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 30, height: 20)
+        let labelRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 38, height: 20)
         paint(labelRect, color: background.withAlphaComponent(0.94), in: context)
         drawText(
-            String(format: "%02d", city.id), at: CGPoint(x: labelRect.minX + 5, y: labelRect.minY + 1),
-            font: Self.digits(14), color: labelColor
+            city.name, at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 1),
+            font: Self.chineseFont(13, semibold: true), color: labelColor
         )
     }
 
```

### `Sources/AirRaidAlert/TouchBarController.swift`

```diff
diff --git a/Sources/AirRaidAlert/TouchBarController.swift b/Sources/AirRaidAlert/TouchBarController.swift
--- a/Sources/AirRaidAlert/TouchBarController.swift
+++ b/Sources/AirRaidAlert/TouchBarController.swift
@@ -4,12 +4,12 @@
     private let onNotify: (Int) -> Void
     private let buttons = (1...16).map { CityTouchButton(cityID: $0) }
 
-    // 把 16 个键放进同一个原生项目，触控条缩窄时一起压缩，避免只隐藏部分编号。
+    // 把 16 个城镇键放进同一个原生项目，在系统分配的应用区域内一起伸缩。
     private lazy var bar: NSTouchBar = {
         let identifier = NSTouchBarItem.Identifier("com.airraidalert.touchbar.cities")
         let citiesItem = NSCustomTouchBarItem(identifier: identifier)
         citiesItem.visibilityPriority = .high
-        citiesItem.view = makeCityRow()
+        citiesItem.view = CityTouchRow(buttons: buttons)
 
         let touchBar = NSTouchBar()
         touchBar.templateItems = [citiesItem]
@@ -35,31 +35,71 @@
             let index = city.id - 1
             guard buttons.indices.contains(index) else { continue }
             let state = CityTouchButton.VisualState(city: city)
-            buttons[index].update(state: state, enabled: inputEnabled && state.canNotify)
-        }
-    }
-
-    private func makeCityRow() -> NSStackView {
-        let row = NSStackView(views: buttons)
-        row.orientation = .horizontal
-        row.userInterfaceLayoutDirection = .leftToRight
-        row.alignment = .centerY
-        row.distribution = .fillEqually
-        row.spacing = 3
-        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
-        for (index, button) in buttons.enumerated() {
-            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
-            // 每组对应主画面的一行，略宽的间隔帮助定位。
-            if (index + 1).isMultiple(of: 4), index < buttons.count - 1 {
-                row.setCustomSpacing(6, after: button)
-            }
-        }
-        return row
+            buttons[index].update(name: city.name, state: state, enabled: inputEnabled && state.canNotify)
+        }
     }
 
     @objc private func notify(_ sender: CityTouchButton) {
         guard sender.isEnabled else { return }
         onNotify(sender.cityID)
+    }
+}
+
+private final class CityTouchRow: NSView {
+    private let buttons: [CityTouchButton]
+    private let spacing: CGFloat = 1
+    private let groupSpacing: CGFloat = 2
+
+    private var totalSpacing: CGFloat {
+        let gapCount = buttons.count - 1
+        let groupGapCount = gapCount / 4
+        return CGFloat(gapCount - groupGapCount) * spacing + CGFloat(groupGapCount) * groupSpacing
+    }
+
+    init(buttons: [CityTouchButton]) {
+        self.buttons = buttons
+        super.init(frame: .zero)
+        for button in buttons {
+            addSubview(button)
+        }
+
+        // 让 AppKit 可以分配更宽的容器，也允许面板变窄时压缩单键。
+        setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
+        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
+        heightAnchor.constraint(equalToConstant: 30).isActive = true
+        let minimum = widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(buttons.count) * 20 + totalSpacing)
+        minimum.priority = .defaultHigh
+        minimum.isActive = true
+    }
+
+    required init?(coder: NSCoder) { nil }
+
+    // 宽松的理想尺寸供 AppKit 排布，实际可用宽度仍由系统控制区决定。
+    override var intrinsicContentSize: NSSize {
+        NSSize(width: CGFloat(buttons.count) * 68 + totalSpacing, height: 30)
+    }
+
+    override func setFrameSize(_ newSize: NSSize) {
+        let sizeChanged = newSize != frame.size
+        super.setFrameSize(newSize)
+        if sizeChanged {
+            needsLayout = true
+        }
+    }
+
+    override func layout() {
+        super.layout()
+        let minimumWidth = CGFloat(buttons.count) * 20 + totalSpacing
+        let spacingScale = min(1, bounds.width / minimumWidth)
+        let buttonWidth = (bounds.width - totalSpacing * spacingScale) / CGFloat(buttons.count)
+        var x = bounds.minX
+
+        // 除组间细缝外，整个容器均为可触区域。每四键对应主画面的一行。
+        for (index, button) in buttons.enumerated() {
+            button.frame = NSRect(x: x, y: bounds.minY, width: buttonWidth, height: bounds.height)
+            let gap = (index + 1).isMultiple(of: 4) ? groupSpacing : spacing
+            x += buttonWidth + gap * spacingScale
+        }
     }
 }
 
@@ -120,24 +160,21 @@
     init(cityID: Int) {
         self.cityID = cityID
         super.init(frame: .zero)
-        title = String(format: "%02d", cityID)
-        font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
+        title = ""
+        font = .systemFont(ofSize: 12, weight: .semibold)
         setButtonType(.momentaryPushIn)
         isBordered = false
         isEnabled = false
-        setAccessibilityLabel("城市 \(title)，\(visualState.accessibilityStatus)")
-        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
     }
 
     required init?(coder: NSCoder) { nil }
 
-    override var intrinsicContentSize: NSSize { NSSize(width: 35, height: 30) }
-
-    func update(state: VisualState, enabled: Bool) {
-        guard visualState != state || isEnabled != enabled else { return }
+    func update(name: String, state: VisualState, enabled: Bool) {
+        guard title != name || visualState != state || isEnabled != enabled else { return }
+        title = name
         visualState = state
         isEnabled = enabled
-        setAccessibilityLabel("城市 \(title)，\(state.accessibilityStatus)")
+        setAccessibilityLabel("\(name)，\(state.accessibilityStatus)")
         needsDisplay = true
     }
 
@@ -150,12 +187,21 @@
         NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
 
         let quiet = visualState == .normal || visualState == .struck
-        let attributes: [NSAttributedString.Key: Any] = [
-            .font: font ?? NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
+        let availableWidth = bounds.width - 3
+        guard availableWidth > 0, !title.isEmpty else { return }
+        let labelFont = font ?? NSFont.systemFont(ofSize: 12, weight: .semibold)
+        var attributes: [NSAttributedString.Key: Any] = [
+            .font: labelFont,
             .foregroundColor: quiet ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.08, alpha: 1)
         ]
         let label = title as NSString
-        let size = label.size(withAttributes: attributes)
+        var size = label.size(withAttributes: attributes)
+        if size.width > availableWidth {
+            // 极窄的系统布局下保留完整双字镇名。
+            let pointSize = max(1, labelFont.pointSize * availableWidth / size.width)
+            attributes[.font] = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
+            size = label.size(withAttributes: attributes)
+        }
         let center = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
         label.draw(at: center, withAttributes: attributes)
     }
```

### `Sources/AirRaidAlert/AirRaidSiren.swift`

```diff
diff --git a/Sources/AirRaidAlert/AirRaidSiren.swift b/Sources/AirRaidAlert/AirRaidSiren.swift
new file mode 100644
--- /dev/null
+++ b/Sources/AirRaidAlert/AirRaidSiren.swift
@@ -0,0 +1,119 @@
+import AVFoundation
+import Foundation
+
+final class AirRaidSiren {
+    private enum ResumeMode {
+        case continuePlayback
+        case restart
+    }
+
+    private let player = try? AVAudioPlayer(data: AirRaidSiren.makeSirenWAV())
+    private var pendingRestart: DispatchWorkItem?
+    private var resumeMode: ResumeMode?
+
+    func play() {
+        guard let player, pendingRestart == nil, resumeMode == nil else { return }
+        guard player.isPlaying else {
+            startFromBeginning()
+            return
+        }
+
+        // 前一声仍在播放时先短暂淡出，重响也只使用同一个播放器。
+        let fadeDuration = 0.04
+        player.setVolume(0, fadeDuration: fadeDuration)
+        let restart = DispatchWorkItem { [weak self] in self?.startFromBeginning() }
+        pendingRestart = restart
+        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration, execute: restart)
+    }
+
+    func pause() {
+        guard let player else { return }
+        if let pendingRestart {
+            pendingRestart.cancel()
+            self.pendingRestart = nil
+            resumeMode = .restart
+        } else if player.isPlaying {
+            resumeMode = .continuePlayback
+        }
+        player.pause()
+    }
+
+    func resume() {
+        guard let resumeMode else { return }
+        self.resumeMode = nil
+        switch resumeMode {
+        case .continuePlayback: player?.play()
+        case .restart: startFromBeginning()
+        }
+    }
+
+    func stop() {
+        pendingRestart?.cancel()
+        pendingRestart = nil
+        resumeMode = nil
+        player?.stop()
+        player?.currentTime = 0
+    }
+
+    private func startFromBeginning() {
+        pendingRestart = nil
+        player?.currentTime = 0
+        player?.volume = 1
+        player?.play()
+    }
+
+    private static func makeSirenWAV() -> Data {
+        let sampleRate: UInt32 = 24_000
+        let duration = 2.6
+        let sampleCount = Int(duration * Double(sampleRate))
+        let revolution = 2 * Double.pi
+        var motorPhase = 0.0
+        var upperPhase = 0.0
+        var samples: [Int16] = []
+        samples.reserveCapacity(sampleCount)
+
+        for frame in 0..<sampleCount {
+            let time = Double(frame) / Double(sampleRate)
+            // 模拟机械警报器的两次升转速和回落，连续累加相位，避免突变。
+            let swell = 0.5 - 0.5 * cos(revolution * time / 1.28)
+            let frequency = 320 + 355 * pow(swell, 0.78)
+            let phaseStep = revolution * frequency / Double(sampleRate)
+            motorPhase += phaseStep
+            upperPhase += phaseStep * 1.21
+            let fundamental = 0.58 * sin(motorPhase)
+            let upperRotor = 0.23 * sin(upperPhase)
+            let harmonics = 0.13 * sin(2 * motorPhase) + 0.06 * sin(3 * motorPhase)
+            let attack = smoothstep(min(1, time / 0.13))
+            let release = smoothstep(min(1, (duration - time) / 0.26))
+            let envelope = attack * release * (0.38 + 0.62 * swell)
+            let sample = Int16((fundamental + upperRotor + harmonics) * envelope * 0.44 * Double(Int16.max))
+            samples.append(sample.littleEndian)
+        }
+
+        // 写入单声道 16 位 PCM（脉冲编码调制）的 WAV 头，避免绑定外部音频素材。
+        let byteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
+        var data = Data("RIFF".utf8)
+        appendLittleEndian(byteCount + 36, to: &data)
+        data.append(contentsOf: "WAVEfmt ".utf8)
+        appendLittleEndian(UInt32(16), to: &data)
+        appendLittleEndian(UInt16(1), to: &data)
+        appendLittleEndian(UInt16(1), to: &data)
+        appendLittleEndian(sampleRate, to: &data)
+        appendLittleEndian(sampleRate * 2, to: &data)
+        appendLittleEndian(UInt16(2), to: &data)
+        appendLittleEndian(UInt16(16), to: &data)
+        data.append(contentsOf: "data".utf8)
+        appendLittleEndian(byteCount, to: &data)
+        samples.withUnsafeBytes { data.append(contentsOf: $0) }
+        return data
+    }
+
+    private static func smoothstep(_ progress: Double) -> Double {
+        progress * progress * (3 - 2 * progress)
+    }
+
+    private static func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer, to data: inout Data) {
+        var bytes = value.littleEndian
+        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
+    }
+}
```

### `Sources/AirRaidAlert/main.swift`

```diff
diff --git a/Sources/AirRaidAlert/main.swift b/Sources/AirRaidAlert/main.swift
--- a/Sources/AirRaidAlert/main.swift
+++ b/Sources/AirRaidAlert/main.swift
@@ -39,6 +39,7 @@
 
 private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
     private let simulation = Simulation()
+    private let siren = AirRaidSiren()
     private var gameView: GameView?
     private var window: GameWindow?
     private var touchBar: TouchBarController?
@@ -81,6 +82,7 @@
 
     func applicationWillTerminate(_ notification: Notification) {
         refreshTimer?.invalidate()
+        siren.stop()
     }
 
     private func setUpMenu() {
@@ -108,18 +110,25 @@
     }
 
     private func notify(cityID: Int) {
-        if simulation.notify(cityID: cityID) {
-            refresh()
-        }
+        guard simulation.notify(cityID: cityID) else { return }
+        refresh()
+        siren.play()
     }
 
     private func togglePause() {
+        guard !simulation.isFinished else { return }
         simulation.togglePause()
+        if simulation.isPaused {
+            siren.pause()
+        } else {
+            siren.resume()
+        }
         lastFrame = ProcessInfo.processInfo.systemUptime
         refresh()
     }
 
     private func restartRound() {
+        siren.stop()
         simulation.reset()
         lastFrame = ProcessInfo.processInfo.systemUptime
         refresh()
```

### `Tests/AirRaidAlertTests/SimulationTests.swift`

```diff
diff --git a/Tests/AirRaidAlertTests/SimulationTests.swift b/Tests/AirRaidAlertTests/SimulationTests.swift
--- a/Tests/AirRaidAlertTests/SimulationTests.swift
+++ b/Tests/AirRaidAlertTests/SimulationTests.swift
@@ -6,6 +6,9 @@
     func testSixteenDistinctConnectedCitiesAndPopulation() {
         let game = Simulation(seed: 42)
         XCTAssertEqual(game.cities.map(\.id), Array(1...16))
+        XCTAssertEqual(Set(game.cities.map(\.name)).count, 16)
+        XCTAssertTrue(game.cities.allSatisfy { $0.name.count == 2 && !$0.name.contains(where: \.isNumber) })
+        XCTAssertEqual(game.cities[2].name, "石桥")
         XCTAssertEqual(Set(game.cities.map { $0.map.tiles.map(\.rawValue) }).count, 16)
         XCTAssertEqual(game.population, 2000)
         XCTAssertEqual(game.alive, 2000)
```
