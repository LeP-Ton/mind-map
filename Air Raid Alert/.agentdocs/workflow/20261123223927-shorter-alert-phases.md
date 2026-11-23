# 会话-12《躲避空袭》两秒预警与轰炸红色

## 设计与变化

- 预警统一为黄色 1 秒、橙色 1 秒，总共 2 秒可发送通知。橙色结束后立即进入轰炸，触控条关闭点按。这条规则贯穿整局。
- 红色专用于正在轰炸的城市。主屏幕的红色城名与虚线，以及触控条的红色按键，均沿用各自原红警的色值。已通知的黄、橙预警仍以青绿色确认，开始轰炸后转红。
- 保留 100 秒一局、16 城各 3 波、总计 48 波的排程，以及两次六城连发。缩短可通知时长后，后段峰值仍可同时出现 6 个预警。

## 验证和测试方法

- 执行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`，9 项自动测试全部通过。覆盖前中后的一秒切换、超时关闭点按、48 波全部结算和原有逐枚命中。
- 以固定种子进行整局验证。种子 42 下，石桥在第 2.05、3.05、3.95 秒通知时分别命中 3、10、28 人。到第 4 秒已无法发送通知，这波命中 47 人。
- AppKit 触控条离屏核对了黄、橙、亮红色值和可点性。主屏幕两档窗口的画面也核对了同时出现的黄警、橙警与红色轰炸状态。实体设备显示仍待真机确认。
- 用 `./run.sh --test-input` 启动，观察「石桥」从开局第 2 秒亮黄，第 3 秒变橙，第 4 秒开始轰炸并变红。重新启动后可在两秒预警内按 `3`，核对青绿确认和疏散。

## 变更差异

### `Sources/AirRaidAlert/Simulation.swift`

```diff
diff --git a/Sources/AirRaidAlert/Simulation.swift b/Sources/AirRaidAlert/Simulation.swift
--- a/Sources/AirRaidAlert/Simulation.swift
+++ b/Sources/AirRaidAlert/Simulation.swift
@@ -3,7 +3,6 @@
 enum WarningPhase: Equatable {
     case yellow
     case orange
-    case red
 }
 
 enum ResidentStatus: Equatable {
@@ -113,6 +112,7 @@
     private static let cityCount = cityNames.count
     private static let residentsPerCity = 125
     private static let maximumMovementStep: TimeInterval = 1.0 / 30
+    private static let warningPhaseDuration: TimeInterval = 1
     private static let minimumCityWarningGap: TimeInterval = 16
 
     let duration: TimeInterval = 100
@@ -250,9 +250,8 @@
         random: inout SimulationRandom
     ) {
         events.append(AlertEvent(time: start, cityIndex: cityIndex, kind: .warning(.yellow)))
-        events.append(AlertEvent(time: start + 2, cityIndex: cityIndex, kind: .warning(.orange)))
-        events.append(AlertEvent(time: start + 4, cityIndex: cityIndex, kind: .warning(.red)))
-        let raid = makeRaid(startingAt: start + 6, random: &random)
+        events.append(AlertEvent(time: start + warningPhaseDuration, cityIndex: cityIndex, kind: .warning(.orange)))
+        let raid = makeRaid(startingAt: start + warningPhaseDuration * 2, random: &random)
         events.append(AlertEvent(time: raid.startedAt, cityIndex: cityIndex, kind: .raid(raid)))
         for (bombIndex, bomb) in raid.bombs.enumerated() {
             events.append(AlertEvent(time: bomb.impactTime, cityIndex: cityIndex, kind: .impact(bombIndex: bombIndex)))
@@ -398,7 +397,7 @@
         let end = roads[start].neighbors.randomElement(using: &random) ?? start
         let length = edgeDistance(from: start, to: end, on: roads)
         let fraction = random.fraction()
-        // 部分较远的住民需要完整预警窗口，橙色或红色阶段才通知会缩短可达距离。
+        // 部分较远的住民需要完整预警窗口，橙色阶段才通知会缩短可达距离。
         return Resident(
             position: position(from: start, to: end, fraction: fraction, on: roads),
             walkingSpeed: 1.2 + 1.3 * random.fraction(),
```

### `Sources/AirRaidAlert/GameView.swift`

```diff
diff --git a/Sources/AirRaidAlert/GameView.swift b/Sources/AirRaidAlert/GameView.swift
--- a/Sources/AirRaidAlert/GameView.swift
+++ b/Sources/AirRaidAlert/GameView.swift
@@ -14,6 +14,7 @@
     private let secondaryInk = NSColor(srgbRed: 0.58, green: 0.67, blue: 0.66, alpha: 1)
     private let paperInk = NSColor(srgbRed: 0.91, green: 0.93, blue: 0.87, alpha: 1)
     private let shelterInk = NSColor(srgbRed: 0.43, green: 0.88, blue: 0.74, alpha: 1)
+    private let raidInk = NSColor(srgbRed: 0.94, green: 0.42, blue: 0.41, alpha: 1)
     private let aircraftInk = NSColor(srgbRed: 0.68, green: 0.79, blue: 0.85, alpha: 1)
     private let bombInk = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.43, alpha: 1)
     private let flashInk = NSColor(srgbRed: 1, green: 0.87, blue: 0.63, alpha: 1)
@@ -129,15 +130,21 @@
         drawImpactScars(in: city, pixel: pixel, context: context)
         drawResidents(city.residents, pixel: pixel, in: context)
         drawShelters(city, pixel: pixel, in: context)
+        let labelColor: NSColor
         if let raid = city.raid {
             drawRaid(raid, elapsed: simulation.elapsed, pixel: pixel, in: context)
-        }
-        if let phase = city.warning {
-            drawWarning(phase: phase, acknowledged: city.notified, rect: rect, in: context)
+            drawCityOutline(color: raidInk, rect: rect, in: context)
+            labelColor = raidInk
+        } else if let phase = city.warning {
+            let ink = warningColor(phase)
+            let outline = city.notified ? ink.withAlphaComponent(0.42) : ink
+            drawCityOutline(color: outline, rect: rect, in: context)
+            labelColor = city.notified ? shelterInk : ink
+        } else {
+            labelColor = paperInk
         }
         context.restoreGState()
 
-        let labelColor = city.notified ? shelterInk : (city.warning.map(warningColor) ?? paperInk)
         let labelRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 38, height: 20)
         paint(labelRect, color: background.withAlphaComponent(0.94), in: context)
         drawText(
@@ -176,8 +183,7 @@
         }
     }
 
-    private func drawWarning(phase: WarningPhase, acknowledged: Bool, rect: CGRect, in context: CGContext) {
-        let ink = warningColor(phase).withAlphaComponent(acknowledged ? 0.42 : 1)
+    private func drawCityOutline(color: NSColor, rect: CGRect, in context: CGContext) {
         let thickness: CGFloat = 2
         let dash: CGFloat = 11
         let margin: CGFloat = 2
@@ -192,7 +198,7 @@
             marks.append(CGRect(x: inner.minX, y: y, width: thickness, height: dash))
             marks.append(CGRect(x: inner.maxX - thickness, y: y, width: thickness, height: dash))
         }
-        context.setFillColor(ink.cgColor)
+        context.setFillColor(color.cgColor)
         context.fill(marks)
     }
 
@@ -371,7 +377,6 @@
         switch phase {
         case .yellow: return NSColor(srgbRed: 0.95, green: 0.80, blue: 0.43, alpha: 1)
         case .orange: return NSColor(srgbRed: 0.96, green: 0.58, blue: 0.33, alpha: 1)
-        case .red: return NSColor(srgbRed: 0.94, green: 0.42, blue: 0.41, alpha: 1)
         }
     }
 
```

### `Sources/AirRaidAlert/TouchBarController.swift`

```diff
diff --git a/Sources/AirRaidAlert/TouchBarController.swift b/Sources/AirRaidAlert/TouchBarController.swift
--- a/Sources/AirRaidAlert/TouchBarController.swift
+++ b/Sources/AirRaidAlert/TouchBarController.swift
@@ -105,7 +105,7 @@
 
 private final class CityTouchButton: NSButton {
     enum VisualState: Equatable {
-        case normal, yellow, orange, red, notified, raiding, struck
+        case normal, yellow, orange, notified, raiding, struck
 
         init(city: CityState) {
             guard let warning = city.warning else {
@@ -124,18 +124,16 @@
             switch warning {
             case .yellow: self = .yellow
             case .orange: self = .orange
-            case .red: self = .red
-            }
-        }
-
-        var canNotify: Bool { self == .yellow || self == .orange || self == .red }
+            }
+        }
+
+        var canNotify: Bool { self == .yellow || self == .orange }
 
         var accessibilityStatus: String {
             switch self {
             case .normal: return "暂无预警"
             case .yellow: return "黄色预警"
             case .orange: return "橙色预警"
-            case .red: return "红色预警"
             case .notified: return "已发送疏散通知"
             case .raiding: return "空袭中"
             case .struck: return "已受击"
@@ -147,9 +145,8 @@
             case .normal: return NSColor(white: 0.17, alpha: 1)
             case .yellow: return NSColor(red: 0.96, green: 0.78, blue: 0.33, alpha: 1)
             case .orange: return NSColor(red: 0.96, green: 0.56, blue: 0.32, alpha: 1)
-            case .red: return NSColor(red: 0.97, green: 0.44, blue: 0.42, alpha: 1)
             case .notified: return NSColor(red: 0.38, green: 0.78, blue: 0.64, alpha: 1)
-            case .raiding: return NSColor(red: 0.68, green: 0.41, blue: 0.39, alpha: 1)
+            case .raiding: return NSColor(red: 0.97, green: 0.44, blue: 0.42, alpha: 1)
             case .struck: return NSColor(white: 0.11, alpha: 1)
             }
         }
```

### `Tests/AirRaidAlertTests/SimulationTests.swift`

```diff
diff --git a/Tests/AirRaidAlertTests/SimulationTests.swift b/Tests/AirRaidAlertTests/SimulationTests.swift
--- a/Tests/AirRaidAlertTests/SimulationTests.swift
+++ b/Tests/AirRaidAlertTests/SimulationTests.swift
@@ -34,7 +34,7 @@
         }
     }
 
-    func testSlowerDotsAndTwoSecondAlertPhases() {
+    func testSlowerDotsAndOpeningAlertPhases() {
         let game = Simulation(seed: 42)
         let initial = game.cities[2].residents.map(\.position)
         game.advance(by: 1)
@@ -46,15 +46,37 @@
         XCTAssertNil(game.cities[2].warning)
         game.advance(by: 1.05)
         XCTAssertEqual(game.cities[2].warning, .yellow)
-        game.advance(by: 2)
+        game.advance(by: 1)
         XCTAssertEqual(game.cities[2].warning, .orange)
-        game.advance(by: 2)
-        XCTAssertEqual(game.cities[2].warning, .red)
-        game.advance(by: 2)
+        game.advance(by: 1)
         XCTAssertNil(game.cities[2].warning)
         XCTAssertNotNil(game.cities[2].raid)
+        XCTAssertFalse(game.notify(cityID: 3))
         XCTAssertEqual(game.cities[2].damage, 0)
         XCTAssertEqual(game.alive, game.population)
+    }
+
+    func testOneSecondWarningPhasesInMiddleAndLateWaves() throws {
+        let game = Simulation(seed: 42)
+        let starts: [TimeInterval] = [32.4, 63.2]
+        for start in starts {
+            game.advance(by: start - 0.01 - game.elapsed)
+            let previousWarnings = game.cities.map(\.warning)
+            game.advance(by: 0.02)
+            let index = try XCTUnwrap(game.cities.indices.first {
+                previousWarnings[$0] == nil && game.cities[$0].warning == .yellow
+            })
+            let phases: [WarningPhase?] = [.yellow, .orange, nil]
+            for phase in 0..<2 {
+                let boundary = start + Double(phase + 1)
+                game.advance(by: boundary - 0.01 - game.elapsed)
+                XCTAssertEqual(game.cities[index].warning, phases[phase])
+                game.advance(by: 0.02)
+                XCTAssertEqual(game.cities[index].warning, phases[phase + 1])
+            }
+            XCTAssertNotNil(game.cities[index].raid)
+            XCTAssertFalse(game.notify(cityID: game.cities[index].id))
+        }
     }
 
     func testEarlyNotificationSavesMoreResidentsThanNoNotification() throws {
@@ -76,7 +98,7 @@
         let early = Simulation(seed: 42)
         let late = Simulation(seed: 42)
         early.advance(by: 2.05)
-        late.advance(by: 6.05)
+        late.advance(by: 3.95)
         XCTAssertTrue(early.notify(cityID: 3))
         XCTAssertTrue(late.notify(cityID: 3))
         try finishFirstRaid(early)
@@ -88,7 +110,7 @@
 
     func testRaidShowsAircraftAndBombsBeforeAnyPopulationChange() throws {
         let game = Simulation(seed: 42)
-        game.advance(by: 8.05)
+        game.advance(by: 4.05)
         let raid = try XCTUnwrap(game.cities[2].raid)
         XCTAssertTrue((5...8).contains(raid.aircraft.count))
         XCTAssertEqual(raid.bombs.count, 30)
@@ -113,9 +135,9 @@
 
     func testEachBombOnlyCountsOutdoorResidentsInsideItsVisibleFootprint() throws {
         let game = Simulation(seed: 42)
-        game.advance(by: 6.05)
+        game.advance(by: 3.05)
         XCTAssertTrue(game.notify(cityID: 3))
-        game.advance(by: 2)
+        game.advance(by: 1)
         let raid = try XCTUnwrap(game.cities[2].raid)
         let impactTimes = Set(raid.bombs.map(\.impactTime)).sorted()
         for time in impactTimes {
@@ -179,7 +201,7 @@
         XCTAssertTrue(game.cities.allSatisfy { city in
             let starts = city.completedRaids.map(\.startedAt)
             let wavesAreSeparated = zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= 16 - 0.000_001 }
-            return city.damage == 90 && city.raid == nil && starts.count == 3 && wavesAreSeparated &&
+            return city.damage == 90 && city.raid == nil && city.completedRaids.count == 3 && wavesAreSeparated &&
                 city.completedRaids.allSatisfy { raid in
                     raid.bombs.count == 30 && raid.bombs.allSatisfy { $0.casualties != nil }
                 }
@@ -237,7 +259,7 @@
     }
 
     private func finishFirstRaid(_ game: Simulation) throws {
-        game.advance(by: 8.05 - game.elapsed)
+        game.advance(by: 4.05 - game.elapsed)
         let lastImpact = try XCTUnwrap(game.cities[2].raid?.bombs.map(\.impactTime).max())
         game.advance(by: lastImpact - game.elapsed + 0.01)
     }
```

### `AGENTS.md`

```diff
diff --git a/AGENTS.md b/AGENTS.md
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -3,7 +3,7 @@
 ## 项目与核心设计
 
 - 《躲避空袭》是一款面向带实体 Touch Bar（触控条）的 MacBook 的休闲反应游戏，以抗日战争时期的虚构中国城市为背景。玩家依据预警向对应城市发送防空通知，帮助居民前往防空洞，提高存活率。
-- 主屏幕以 90° 垂直俯视呈现 4×4 排列的 16 座独立城市。建筑群是像素色面，居民是沿道路移动的点，地图呈抽象的卫星图像观感。HUD（游戏状态栏）显示时间与人口统计。主屏幕按从左至右、从上至下的顺序显示城镇名，预警时在城市边缘显示黄、橙、红标记。
+- 主屏幕以 90° 垂直俯视呈现 4×4 排列的 16 座独立城市。建筑群是像素色面，居民是沿道路移动的点，地图呈抽象的卫星图像观感。HUD（游戏状态栏）显示时间与人口统计。主屏幕按从左至右、从上至下的顺序显示城镇名。黄、橙色表示可发送通知的预警，红色表示正在遭受空袭。
 - 游戏仿真维护城市、道路、居民、预警与人口状态。飞机、投弹、落点、命中范围和居民点位置使用同一套仿真数据，原生 AppKit（macOS 界面框架）按这套数据绘制地图并接入实体 Touch Bar。16 个触控键使用与地图一致的地名和顺序，成功发送通知时播放防空警报。主屏幕承担观察和暂停操作。
 - 每局包含多座城市交叠的多波预警，后段会集中出现。每次通知服务于该城的当前一波。空袭解除后，仍存活的居民返回道路，旧波的落点痕迹继续保留。重开会重新编排后续预警，地图布局沿用同一份城市数据。
 
```
