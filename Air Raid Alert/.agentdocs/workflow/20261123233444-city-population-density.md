# 会话-13《躲避空袭》城镇人口密度与通知取舍

## 游戏变化

- 2000 名居民按 16 个不同的开局人数分配。高密度 4 城各 190–215 人，共 800 人。中密度 8 城各 100–150 人，共 1000 人。低密度 4 城各 35–65 人，共 200 人。
- 人口档位按开局人数固定。主画面在城名旁显示「高 · 200」这类档位和实时存活人数，后者包括当前在地表和已经避难的人。Touch Bar（触控条）在城名下方显示高、中、低，原有预警颜色和点按规则继续沿用。
- 仿真按每城的实际人数绘制和结算居民点。地图、已有居民的开局轨迹、起警时刻、落点与通知时序验证一致。新增居民使用独立的随机流。

## 验证和测试方法

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` 的 9 项自动测试通过。验证 16 个开局人口、三档数量、后段高低密度并发预警、实时人口结算与重开。
- 固定种子 42、同样 12 次黄警通知的整局对比，优先四座高密度城存活 930 人，优先四座低密度城存活 540 人。完全未通知时存活 394 人。该样本的其他游戏规则相同。
- 两种窗口尺寸验证人口标签和实时更新。第 6.1 秒的离屏画面中，石桥从「高 · 200」更新为「高 · 181」，顶部存活数从 2000 同步降至 1981。触控条在 338–1090 pt 六种宽度下核对了 16 个两行按钮、辅助功能密度标签与颜色状态，实体设备仍待验证。
- 运行 `./run.sh --test-input`，先核对石桥「高 · 200」和南陵「低 · 55」。倒计时剩约 00:36 或 00:15 时，观察多个城镇同时亮警，按地图对应键响警，并检查各城存活人数变化。

## 变更差异

### `Sources/AirRaidAlert/Simulation.swift`

```diff
diff --git a/Sources/AirRaidAlert/Simulation.swift b/Sources/AirRaidAlert/Simulation.swift
--- a/Sources/AirRaidAlert/Simulation.swift
+++ b/Sources/AirRaidAlert/Simulation.swift
@@ -10,6 +10,12 @@
     case evacuating
     case sheltered
     case lost
+}
+
+enum PopulationDensity: String {
+    case low = "低"
+    case medium = "中"
+    case high = "高"
 }
 
 struct Resident {
@@ -35,6 +41,16 @@
     fileprivate(set) var completedRaids: [RaidState] = []
     fileprivate(set) var damage = 0
     fileprivate let shelterRoutes: [ShelterRoute]
+
+    var density: PopulationDensity {
+        if residents.count >= 190 { return .high }
+        if residents.count >= 100 { return .medium }
+        return .low
+    }
+
+    var livingPopulation: Int {
+        residents.lazy.filter { $0.status != .lost }.count
+    }
 }
 
 struct RaidState {
@@ -103,14 +119,14 @@
     }
 
     // 顺序对应地图的从左到右、从上到下，也是触控条的排列顺序。
-    private static let cityNames = [
-        "松浦", "柳溪", "石桥", "云津",
-        "枫湾", "南陵", "竹塘", "青川",
-        "白沙", "榆关", "杏村", "临汀",
-        "蒲渡", "桂岭", "安泽", "鹤台"
+    private static let cityConfigurations: [(name: String, population: Int)] = [
+        ("松浦", 150), ("柳溪", 45), ("石桥", 200), ("云津", 120),
+        ("枫湾", 190), ("南陵", 55), ("竹塘", 130), ("青川", 100),
+        ("白沙", 135), ("榆关", 195), ("杏村", 65), ("临汀", 115),
+        ("蒲渡", 140), ("桂岭", 110), ("安泽", 215), ("鹤台", 35)
     ]
-    private static let cityCount = cityNames.count
-    private static let residentsPerCity = 125
+    private static let cityCount = cityConfigurations.count
+    private static let originalResidentsPerCity = 125
     private static let maximumMovementStep: TimeInterval = 1.0 / 30
     private static let warningPhaseDuration: TimeInterval = 1
     private static let minimumCityWarningGap: TimeInterval = 16
@@ -128,20 +144,27 @@
 
     var remaining: TimeInterval { duration - elapsed }
     var isFinished: Bool { elapsed >= duration }
-    var population: Int { Self.cityCount * Self.residentsPerCity }
-    var alive: Int { population - residentCount(in: .lost) }
+    var population: Int { cities.reduce(0) { $0 + $1.residents.count } }
+    var alive: Int { cities.reduce(0) { $0 + $1.livingPopulation } }
     var sheltered: Int { residentCount(in: .sheltered) }
 
     init(seed: UInt64 = 0x4152_4149_4C45_5254, scheduleSeed: UInt64? = nil) {
         var random = SimulationRandom(state: seed)
-        let cities = Self.cityNames.enumerated().map { index, name in
-            let map = CityMap.make(seed: random.next())
-            let residents = (0..<Self.residentsPerCity).map { _ in
+        let cities = Self.cityConfigurations.enumerated().map { index, configuration in
+            let mapSeed = random.next()
+            let map = CityMap.make(seed: mapSeed)
+            // 保留原有道路种子和已有居民点，新增人口使用独立的单城随机流。
+            let baseline = (0..<Self.originalResidentsPerCity).map { _ in
                 Self.makeResident(on: map.roads, random: &random)
+            }
+            var residents = Array(baseline.prefix(configuration.population))
+            var additionalRandom = SimulationRandom(state: mapSeed ^ 0x5245_5349_4445_4E54)
+            for _ in residents.count..<configuration.population {
+                residents.append(Self.makeResident(on: map.roads, random: &additionalRandom))
             }
             return CityState(
                 id: index + 1,
-                name: name,
+                name: configuration.name,
                 map: map,
                 residents: residents,
                 shelterRoutes: Self.findShelterRoutes(in: map)
```

### `Sources/AirRaidAlert/GameView.swift`

```diff
diff --git a/Sources/AirRaidAlert/GameView.swift b/Sources/AirRaidAlert/GameView.swift
--- a/Sources/AirRaidAlert/GameView.swift
+++ b/Sources/AirRaidAlert/GameView.swift
@@ -145,11 +145,17 @@
         }
         context.restoreGState()
 
-        let labelRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 38, height: 20)
+        let labelRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 84, height: 20)
         paint(labelRect, color: background.withAlphaComponent(0.94), in: context)
         drawText(
             city.name, at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 1),
             font: Self.chineseFont(13, semibold: true), color: labelColor
+        )
+        // 档位沿用开局分类，人数随单城存活情况实时刷新。
+        drawText(
+            "\(city.density.rawValue) · \(city.livingPopulation)",
+            at: CGPoint(x: labelRect.minX + 38, y: labelRect.minY + 3),
+            font: Self.chineseFont(11, semibold: true), color: secondaryInk
         )
     }
 
```

### `Sources/AirRaidAlert/TouchBarController.swift`

```diff
diff --git a/Sources/AirRaidAlert/TouchBarController.swift b/Sources/AirRaidAlert/TouchBarController.swift
--- a/Sources/AirRaidAlert/TouchBarController.swift
+++ b/Sources/AirRaidAlert/TouchBarController.swift
@@ -35,7 +35,12 @@
             let index = city.id - 1
             guard buttons.indices.contains(index) else { continue }
             let state = CityTouchButton.VisualState(city: city)
-            buttons[index].update(name: city.name, state: state, enabled: inputEnabled && state.canNotify)
+            buttons[index].update(
+                name: city.name,
+                densityMark: city.density.rawValue,
+                state: state,
+                enabled: inputEnabled && state.canNotify
+            )
         }
     }
 
@@ -154,6 +159,7 @@
 
     let cityID: Int
     private var visualState = VisualState.normal
+    private var densityMark = ""
 
     init(cityID: Int) {
         self.cityID = cityID
@@ -167,12 +173,13 @@
 
     required init?(coder: NSCoder) { nil }
 
-    func update(name: String, state: VisualState, enabled: Bool) {
-        guard title != name || visualState != state || isEnabled != enabled else { return }
+    func update(name: String, densityMark: String, state: VisualState, enabled: Bool) {
+        guard title != name || self.densityMark != densityMark || visualState != state || isEnabled != enabled else { return }
         title = name
+        self.densityMark = densityMark
         visualState = state
         isEnabled = enabled
-        setAccessibilityLabel("\(name)，\(state.accessibilityStatus)")
+        setAccessibilityLabel("\(name)，\(densityMark)密度，\(state.accessibilityStatus)")
         needsDisplay = true
     }
 
@@ -200,7 +207,25 @@
             attributes[.font] = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
             size = label.size(withAttributes: attributes)
         }
-        let center = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
-        label.draw(at: center, withAttributes: attributes)
+
+        // 名称和单字密度标记分行居中，让两字城名在窄键上也能完整显示。
+        let densityLabel = densityMark as NSString
+        let densityAttributes: [NSAttributedString.Key: Any] = [
+            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
+            .foregroundColor: NSColor(white: quiet ? 0.62 : 0.17, alpha: 1)
+        ]
+        let densitySize = densityLabel.size(withAttributes: densityAttributes)
+        let lineSpacing: CGFloat = 1
+        let minY = bounds.midY - (size.height + lineSpacing + densitySize.height) / 2
+        let nameY = isFlipped ? minY : minY + densitySize.height + lineSpacing
+        let densityY = isFlipped ? minY + size.height + lineSpacing : minY
+        label.draw(
+            at: NSPoint(x: bounds.midX - size.width / 2, y: nameY),
+            withAttributes: attributes
+        )
+        densityLabel.draw(
+            at: NSPoint(x: bounds.midX - densitySize.width / 2, y: densityY),
+            withAttributes: densityAttributes
+        )
     }
 }
```

### `Tests/AirRaidAlertTests/SimulationTests.swift`

```diff
diff --git a/Tests/AirRaidAlertTests/SimulationTests.swift b/Tests/AirRaidAlertTests/SimulationTests.swift
--- a/Tests/AirRaidAlertTests/SimulationTests.swift
+++ b/Tests/AirRaidAlertTests/SimulationTests.swift
@@ -10,13 +10,20 @@
         XCTAssertTrue(game.cities.allSatisfy { $0.name.count == 2 && !$0.name.contains(where: \.isNumber) })
         XCTAssertEqual(game.cities[2].name, "石桥")
         XCTAssertEqual(Set(game.cities.map { $0.map.tiles.map(\.rawValue) }).count, 16)
+        let openingPopulations = [150, 45, 200, 120, 190, 55, 130, 100, 135, 195, 65, 115, 140, 110, 215, 35]
+        XCTAssertEqual(game.cities.map { $0.residents.count }, openingPopulations)
+        XCTAssertEqual(game.cities.map(\.livingPopulation), openingPopulations)
+        XCTAssertEqual(game.cities.filter { $0.density == .high }.count, 4)
+        XCTAssertEqual(game.cities.filter { $0.density == .medium }.count, 8)
+        XCTAssertEqual(game.cities.filter { $0.density == .low }.count, 4)
+        XCTAssertEqual(game.cities[2].density, .high)
+        XCTAssertEqual(game.cities[15].density, .low)
         XCTAssertEqual(game.population, 2000)
         XCTAssertEqual(game.alive, 2000)
         XCTAssertEqual(game.sheltered, 0)
 
         for city in game.cities {
             let map = city.map
-            XCTAssertEqual(city.residents.count, 125)
             XCTAssertEqual(map.tiles.count, CityMap.width * CityMap.height)
             XCTAssertFalse(map.shelters.isEmpty)
             var reached: Set<Int> = [0]
@@ -163,6 +170,8 @@
             let actualLosses = residents.indices.filter { previous[$0] != .lost && residents[$0].status == .lost }
             XCTAssertEqual(Set(actualLosses), expectedLosses)
 
+            XCTAssertEqual(city.livingPopulation, residents.filter { $0.status != .lost }.count)
+            XCTAssertEqual(game.alive, game.cities.reduce(0) { $0 + $1.livingPopulation })
             XCTAssertEqual(game.population - game.alive, recordedLosses(in: game))
         }
         XCTAssertEqual(game.cities[2].damage, 30)
@@ -185,19 +194,24 @@
         game.togglePause()
         var openingAlertPeak = 0
         var lateAlertPeak = 0
+        var sawMixedDensityAlerts = false
         while !game.isFinished {
             game.advance(by: 0.25)
-            let alerts = game.cities.filter { $0.warning != nil && !$0.notified }.count
+            let pending = game.cities.filter { $0.warning != nil && !$0.notified }
             if game.elapsed <= 20 {
-                openingAlertPeak = max(openingAlertPeak, alerts)
+                openingAlertPeak = max(openingAlertPeak, pending.count)
             } else if game.elapsed >= 60 {
-                lateAlertPeak = max(lateAlertPeak, alerts)
+                lateAlertPeak = max(lateAlertPeak, pending.count)
+                let high = pending.filter { $0.density == .high }.map(\.livingPopulation).max() ?? 0
+                let low = pending.filter { $0.density == .low }.map(\.livingPopulation).max() ?? 0
+                sawMixedDensityAlerts = sawMixedDensityAlerts || (low > 0 && high > low)
             }
         }
         XCTAssertTrue(game.isFinished)
         XCTAssertEqual(game.remaining, 0)
         XCTAssertGreaterThanOrEqual(lateAlertPeak, 6)
         XCTAssertGreaterThan(lateAlertPeak, openingAlertPeak)
+        XCTAssertTrue(sawMixedDensityAlerts)
         XCTAssertTrue(game.cities.allSatisfy { city in
             let starts = city.completedRaids.map(\.startedAt)
             let wavesAreSeparated = zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= 16 - 0.000_001 }
@@ -212,6 +226,7 @@
         XCTAssertFalse(game.isPaused)
         XCTAssertEqual(game.remaining, game.duration)
         XCTAssertEqual(game.alive, 2000)
+        XCTAssertEqual(game.cities.map(\.livingPopulation), game.cities.map { $0.residents.count })
         XCTAssertTrue(game.cities.allSatisfy { city in
             city.damage == 0 && city.warning == nil && city.raid == nil && city.completedRaids.isEmpty
         })
```

### `AGENTS.md`

```diff
diff --git a/AGENTS.md b/AGENTS.md
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -6,6 +6,7 @@
 - 主屏幕以 90° 垂直俯视呈现 4×4 排列的 16 座独立城市。建筑群是像素色面，居民是沿道路移动的点，地图呈抽象的卫星图像观感。HUD（游戏状态栏）显示时间与人口统计。主屏幕按从左至右、从上至下的顺序显示城镇名。黄、橙色表示可发送通知的预警，红色表示正在遭受空袭。
 - 游戏仿真维护城市、道路、居民、预警与人口状态。飞机、投弹、落点、命中范围和居民点位置使用同一套仿真数据，原生 AppKit（macOS 界面框架）按这套数据绘制地图并接入实体 Touch Bar。16 个触控键使用与地图一致的地名和顺序，成功发送通知时播放防空警报。主屏幕承担观察和暂停操作。
 - 每局包含多座城市交叠的多波预警，后段会集中出现。每次通知服务于该城的当前一波。空袭解除后，仍存活的居民返回道路，旧波的落点痕迹继续保留。重开会重新编排后续预警，地图布局沿用同一份城市数据。
+- 各城的初始人口按高、中、低三档分布，密度档由开局人数决定，主屏同时显示每城当前存活人数。触控条在城名下标出密度档，供玩家在并发预警时决定通知顺序。
 
 ## 技术与运行方式
 
```
