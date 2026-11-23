# 会话-11《躲避空袭》48 波连发预警

## 难度调整

- 100 秒的一局从 16 波提高到 48 波，每座城市各经历 3 波。黄、橙、红预警阶段各为 2 秒。约在第 63 秒和第 84 秒，各有一组 6 座城镇在不到 2 秒内陆续预警。固定种子实测前 20 秒最多同时 3 个未处理预警，后段最多 6 个。
- 石桥、南陵仍分别在第 2 秒和第 4.5 秒率先预警。其他城市由带间隔约束的随机排程决定，重开会更换后续顺序，保持地图布局可复用。每座城的相邻预警至少间隔 16 秒。
- 同城每波独立接收通知。飞机与最后的爆点动效结束后，旧波归档，存活居民从当前位置继续移动。原有损毁保留，并且各波的落弹命中累计等于整局存活人数的变化。
- 主屏幕显示「当前避难人数」。已经通知的城市使用青绿城名和调淡的预警线，其他城镇继续使用当前预警颜色。触控条依据当前波的状态切换，下次预警时恢复对应城镇的点按。

## 验证和测试方法

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` 共 8 项测试通过，覆盖前后段的并发预警、同城再通知、出洞位置、累计损失、48 波全部结算和重开。
- 固定种子 42 的最后一版复核中，完全未通知有 397 人存活，见黄警即通知有 1982 人存活，每隔约 1.2 秒处理一城有 1954 人存活。三种情形均完成 48 波、结算 1440 枚模拟落点。
- 960 × 650 与 1280 × 720 的离屏画面验证并发城市警示、已通知状态与旧落点痕迹。AppKit 触控条离屏联调验证两城同时点按、同城下一波再次点按、受击状态过渡。实体设备操作手感待实测。
- 用 `./run.sh --test-input` 启动，两次晚段连发对应剩余时间约 00:37 和 00:16。按地图位置使用四排键 `1 2 3 4 / Q W E R / A S D F / Z X C V`，核对同一城镇能否在新一波预警时再次通知。实体 Touch Bar（触控条）使用同名城镇键。

## 变更差异

### `Sources/AirRaidAlert/Simulation.swift`

```diff
diff --git a/Sources/AirRaidAlert/Simulation.swift b/Sources/AirRaidAlert/Simulation.swift
--- a/Sources/AirRaidAlert/Simulation.swift
+++ b/Sources/AirRaidAlert/Simulation.swift
@@ -33,11 +33,14 @@
     fileprivate(set) var warning: WarningPhase?
     fileprivate(set) var notified = false
     fileprivate(set) var raid: RaidState?
+    fileprivate(set) var completedRaids: [RaidState] = []
     fileprivate(set) var damage = 0
     fileprivate let shelterRoutes: [ShelterRoute]
 }
 
 struct RaidState {
+    static let impactEffectDuration: TimeInterval = 1.45
+
     let startedAt: TimeInterval
     let aircraft: [RaidAircraft]
     let bombs: [RaidBomb]
@@ -91,6 +94,7 @@
         case warning(WarningPhase)
         case raid(RaidState)
         case impact(bombIndex: Int)
+        case allClear
     }
 
     private struct AlertEvent {
@@ -109,6 +113,7 @@
     private static let cityCount = cityNames.count
     private static let residentsPerCity = 125
     private static let maximumMovementStep: TimeInterval = 1.0 / 30
+    private static let minimumCityWarningGap: TimeInterval = 16
 
     let duration: TimeInterval = 100
     private(set) var elapsed: TimeInterval = 0
@@ -116,7 +121,9 @@
     private(set) var cities: [CityState]
 
     private let startingCities: [CityState]
-    private let events: [AlertEvent]
+    private let raidSeed: UInt64
+    private var orderRandom: SimulationRandom
+    private var events: [AlertEvent]
     private var nextEventIndex = 0
 
     var remaining: TimeInterval { duration - elapsed }
@@ -125,7 +132,7 @@
     var alive: Int { population - residentCount(in: .lost) }
     var sheltered: Int { residentCount(in: .sheltered) }
 
-    init(seed: UInt64 = 0x4152_4149_4C45_5254) {
+    init(seed: UInt64 = 0x4152_4149_4C45_5254, scheduleSeed: UInt64? = nil) {
         var random = SimulationRandom(state: seed)
         let cities = Self.cityNames.enumerated().map { index, name in
             let map = CityMap.make(seed: random.next())
@@ -140,8 +147,11 @@
                 shelterRoutes: Self.findShelterRoutes(in: map)
             )
         }
-        var raidRandom = SimulationRandom(state: seed ^ 0x5241_4944_504C_414E)
-        events = Self.makeAlertEvents(orderRandom: &random, raidRandom: &raidRandom)
+        let raidSeed = seed ^ 0x5241_4944_504C_414E
+        var orderRandom = SimulationRandom(state: scheduleSeed ?? seed)
+        events = Self.makeAlertEvents(orderRandom: &orderRandom, raidSeed: raidSeed)
+        self.raidSeed = raidSeed
+        self.orderRandom = orderRandom
         startingCities = cities
         self.cities = cities
     }
@@ -179,6 +189,7 @@
         elapsed = 0
         isPaused = false
         cities = startingCities
+        events = Self.makeAlertEvents(orderRandom: &orderRandom, raidSeed: raidSeed)
         nextEventIndex = 0
     }
 
@@ -194,22 +205,32 @@
 
     private static func makeAlertEvents(
         orderRandom: inout SimulationRandom,
-        raidRandom: inout SimulationRandom
+        raidSeed: UInt64
     ) -> [AlertEvent] {
-        let openingCities = [3, 6, 9, 12, 15]
-        let otherCities = (1...cityCount).filter { !openingCities.contains($0) }
-        let order = openingCities + otherCities.shuffled(using: &orderRandom)
-        let startTimes: [TimeInterval] = [2, 4.5, 8, 10, 14, 20, 25, 31, 35, 43, 49, 54, 63, 67, 77, 89]
+        // 首轮让玩家建立位置感，后两轮缩短部分间隔，最后一轮集中出现连发预警。
+        let startTimes: [[TimeInterval]] = [
+            [2, 4.5, 8, 10, 12.4, 14.4, 16.6, 18.4, 20.4, 22.1, 23.7, 25.6, 27, 28.6, 29.7, 31],
+            [32.4, 33.7, 35, 36.6, 38, 40.2, 43, 44, 45.2, 46.3, 47.5, 50.2, 52.5, 54, 55.3, 57.1],
+            [63.2, 63.48, 63.76, 64.1, 64.44, 64.82, 70.8, 71.55, 72.5, 74.6, 84.45, 84.74, 85.03, 85.39, 85.77, 86.2]
+        ]
+        let openingCities = [2, 5] // 石桥、南陵
+        var raidRandom = SimulationRandom(state: raidSeed)
+        var previousStarts = Array(repeating: -TimeInterval.infinity, count: cityCount)
         var events: [AlertEvent] = []
-        for (id, start) in zip(order, startTimes) {
-            let cityIndex = id - 1
-            events.append(AlertEvent(time: start, cityIndex: cityIndex, kind: .warning(.yellow)))
-            events.append(AlertEvent(time: start + 2, cityIndex: cityIndex, kind: .warning(.orange)))
-            events.append(AlertEvent(time: start + 4, cityIndex: cityIndex, kind: .warning(.red)))
-            let raid = makeRaid(startingAt: start + 6, random: &raidRandom)
-            events.append(AlertEvent(time: raid.startedAt, cityIndex: cityIndex, kind: .raid(raid)))
-            for (bombIndex, bomb) in raid.bombs.enumerated() {
-                events.append(AlertEvent(time: bomb.impactTime, cityIndex: cityIndex, kind: .impact(bombIndex: bombIndex)))
+        for (round, times) in startTimes.enumerated() {
+            var candidates = (0..<cityCount).shuffled(using: &orderRandom)
+            if round == 0 {
+                candidates.removeAll { openingCities.contains($0) }
+                candidates.insert(contentsOf: openingCities, at: 0)
+            }
+            for start in times {
+                // 越晚的槽可选城市越多，按洗牌顺序取最先满足间隔的一座即可。
+                guard let index = candidates.firstIndex(where: { start - previousStarts[$0] >= minimumCityWarningGap }) else {
+                    preconditionFailure("每轮时刻必须为所有城市留出解除后的活动间隔")
+                }
+                let cityIndex = candidates.remove(at: index)
+                previousStarts[cityIndex] = start
+                appendWave(startingAt: start, in: cityIndex, to: &events, random: &raidRandom)
             }
         }
         events.sort { first, second in
@@ -220,6 +241,26 @@
             return firstIndex < secondIndex
         }
         return events
+    }
+
+    private static func appendWave(
+        startingAt start: TimeInterval,
+        in cityIndex: Int,
+        to events: inout [AlertEvent],
+        random: inout SimulationRandom
+    ) {
+        events.append(AlertEvent(time: start, cityIndex: cityIndex, kind: .warning(.yellow)))
+        events.append(AlertEvent(time: start + 2, cityIndex: cityIndex, kind: .warning(.orange)))
+        events.append(AlertEvent(time: start + 4, cityIndex: cityIndex, kind: .warning(.red)))
+        let raid = makeRaid(startingAt: start + 6, random: &random)
+        events.append(AlertEvent(time: raid.startedAt, cityIndex: cityIndex, kind: .raid(raid)))
+        for (bombIndex, bomb) in raid.bombs.enumerated() {
+            events.append(AlertEvent(time: bomb.impactTime, cityIndex: cityIndex, kind: .impact(bombIndex: bombIndex)))
+        }
+        let lastImpact = raid.bombs.last?.impactTime ?? raid.startedAt
+        let lastAircraftExit = raid.aircraft.map { $0.startsAt + $0.duration }.max() ?? raid.startedAt
+        let clearTime = max(lastImpact + RaidState.impactEffectDuration, lastAircraftExit)
+        events.append(AlertEvent(time: clearTime, cityIndex: cityIndex, kind: .allClear))
     }
 
     private static func makeRaid(startingAt startedAt: TimeInterval, random: inout SimulationRandom) -> RaidState {
@@ -284,12 +325,17 @@
             nextEventIndex += 1
             switch event.kind {
             case .warning(let phase):
+                if phase == .yellow {
+                    cities[event.cityIndex].notified = false
+                }
                 cities[event.cityIndex].warning = phase
             case .raid(let raid):
                 cities[event.cityIndex].warning = nil
                 cities[event.cityIndex].raid = raid
             case .impact(let bombIndex):
                 Self.applyImpact(of: bombIndex, to: &cities[event.cityIndex])
+            case .allClear:
+                Self.clearRaid(in: &cities[event.cityIndex])
             }
         }
     }
@@ -315,6 +361,21 @@
         bombs[bombIndex].casualties = casualties
         city.raid = RaidState(startedAt: raid.startedAt, aircraft: raid.aircraft, bombs: bombs)
         city.damage += 1
+    }
+
+    private static func clearRaid(in city: inout CityState) {
+        guard let raid = city.raid else { return }
+        city.completedRaids.append(raid)
+        city.raid = nil
+        city.notified = false
+        for index in city.residents.indices {
+            switch city.residents[index].status {
+            case .sheltered, .evacuating:
+                city.residents[index].status = .roaming
+            case .roaming, .lost:
+                break
+            }
+        }
     }
 
     private func moveResidents(by interval: TimeInterval) {
@@ -397,6 +458,8 @@
             let nextNode: Int?
             if resident.status == .evacuating {
                 if routes[node].distance == 0 {
+                    // 记录抵达的边终点，解除后首步从洞口接入下一条道路。
+                    resident.distanceAlongEdge = resident.edgeLength
                     resident.status = .sheltered
                     return
                 }
```

### `Sources/AirRaidAlert/GameView.swift`

```diff
diff --git a/Sources/AirRaidAlert/GameView.swift b/Sources/AirRaidAlert/GameView.swift
--- a/Sources/AirRaidAlert/GameView.swift
+++ b/Sources/AirRaidAlert/GameView.swift
@@ -85,7 +85,7 @@
             ("剩余时间", String(format: "%02d:%02d", seconds / 60, seconds % 60), paperInk),
             ("城市总人口", String(simulation.population), paperInk),
             ("当前存活人数", String(simulation.alive), paperInk),
-            ("已安全避难人数", String(simulation.sheltered), shelterInk)
+            ("当前避难人数", String(simulation.sheltered), shelterInk)
         ]
         for (index, metric) in metrics.enumerated() {
             let x = guide.metricsStart + CGFloat(index) * guide.metricWidth
@@ -126,20 +126,18 @@
             context.restoreGState()
         }
         context.setShouldAntialias(false)
-        if let raid = city.raid {
-            drawImpactScars(raid.bombs, pixel: pixel, in: context)
-        }
+        drawImpactScars(in: city, pixel: pixel, context: context)
         drawResidents(city.residents, pixel: pixel, in: context)
         drawShelters(city, pixel: pixel, in: context)
         if let raid = city.raid {
             drawRaid(raid, elapsed: simulation.elapsed, pixel: pixel, in: context)
         }
         if let phase = city.warning {
-            drawWarning(phase: phase, rect: rect, in: context)
+            drawWarning(phase: phase, acknowledged: city.notified, rect: rect, in: context)
         }
         context.restoreGState()
 
-        let labelColor = city.warning.map(warningColor) ?? (city.notified ? shelterInk : paperInk)
+        let labelColor = city.notified ? shelterInk : (city.warning.map(warningColor) ?? paperInk)
         let labelRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 38, height: 20)
         paint(labelRect, color: background.withAlphaComponent(0.94), in: context)
         drawText(
@@ -178,8 +176,8 @@
         }
     }
 
-    private func drawWarning(phase: WarningPhase, rect: CGRect, in context: CGContext) {
-        let ink = warningColor(phase)
+    private func drawWarning(phase: WarningPhase, acknowledged: Bool, rect: CGRect, in context: CGContext) {
+        let ink = warningColor(phase).withAlphaComponent(acknowledged ? 0.42 : 1)
         let thickness: CGFloat = 2
         let dash: CGFloat = 11
         let margin: CGFloat = 2
@@ -198,14 +196,27 @@
         context.fill(marks)
     }
 
-    private func drawImpactScars(_ bombs: [RaidBomb], pixel: MapProjection, in context: CGContext) {
-        // 每个地面痕迹对应已结算的落点，绘制在居民与防空洞标记下方。
+    private func drawImpactScars(in city: CityState, pixel: MapProjection, context: CGContext) {
+        guard !city.completedRaids.isEmpty || city.raid != nil else { return }
+        // 按城批量绘制各波已经结算的落点，痕迹始终在居民与防空洞标记下方。
         var rims: [CGRect] = []
         var cores: [CGRect] = []
-        for bomb in bombs where bomb.casualties != nil {
-            let size = bomb.radius * 0.56
-            rims.append(pixel.mapSquare(at: bomb.impactPosition, size: size))
-            cores.append(pixel.mapSquare(at: bomb.impactPosition, size: size * 0.50))
+        let capacity = city.completedRaids.reduce(0) { $0 + $1.bombs.count } + (city.raid?.bombs.count ?? 0)
+        rims.reserveCapacity(capacity)
+        cores.reserveCapacity(capacity)
+
+        func addScars(from raid: RaidState) {
+            for bomb in raid.bombs where bomb.casualties != nil {
+                let size = bomb.radius * 0.56
+                rims.append(pixel.mapSquare(at: bomb.impactPosition, size: size))
+                cores.append(pixel.mapSquare(at: bomb.impactPosition, size: size * 0.50))
+            }
+        }
+        for raid in city.completedRaids {
+            addScars(from: raid)
+        }
+        if let raid = city.raid {
+            addScars(from: raid)
         }
         context.setFillColor(rubbleInk.cgColor)
         context.fill(rims)
@@ -220,7 +231,7 @@
                 drawFallingBomb(bomb, at: point, elapsed: elapsed, pixel: pixel, in: context)
             } else if let casualties = bomb.casualties {
                 let age = CGFloat(elapsed - bomb.impactTime)
-                if (0..<1.45).contains(age) {
+                if (0..<CGFloat(RaidState.impactEffectDuration)).contains(age) {
                     drawBurst(bomb, age: age, casualties: casualties, pixel: pixel, in: context)
                 }
                 if casualties > 0, (0..<0.56).contains(age) {
@@ -282,8 +293,9 @@
                 )
             }
         }
-        guard age >= 0.12 else { return }
-        let smokeProgress = (age - 0.12) / 1.33
+        let smokeDelay: CGFloat = 0.12
+        guard age >= smokeDelay else { return }
+        let smokeProgress = (age - smokeDelay) / (CGFloat(RaidState.impactEffectDuration) - smokeDelay)
         for index in 0..<3 {
             let offset = CGFloat(index)
             let drift = CGPoint(
```

### `Sources/AirRaidAlert/TouchBarController.swift`

```diff
diff --git a/Sources/AirRaidAlert/TouchBarController.swift b/Sources/AirRaidAlert/TouchBarController.swift
--- a/Sources/AirRaidAlert/TouchBarController.swift
+++ b/Sources/AirRaidAlert/TouchBarController.swift
@@ -109,10 +109,11 @@
 
         init(city: CityState) {
             guard let warning = city.warning else {
-                if let raid = city.raid {
-                    self = city.damage < raid.bombs.count ? .raiding : .struck
+                // 损毁会跨波累计，当前空袭（含落弹后的收尾）以 raid 是否存在为准。
+                if city.raid != nil {
+                    self = .raiding
                 } else {
-                    self = .normal
+                    self = city.damage > 0 ? .struck : .normal
                 }
                 return
             }
```

### `Sources/AirRaidAlert/main.swift`

```diff
diff --git a/Sources/AirRaidAlert/main.swift b/Sources/AirRaidAlert/main.swift
--- a/Sources/AirRaidAlert/main.swift
+++ b/Sources/AirRaidAlert/main.swift
@@ -38,7 +38,7 @@
 }
 
 private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
-    private let simulation = Simulation()
+    private let simulation = Simulation(scheduleSeed: UInt64.random(in: .min ... .max))
     private let siren = AirRaidSiren()
     private var gameView: GameView?
     private var window: GameWindow?
```

### `Tests/AirRaidAlertTests/SimulationTests.swift`

```diff
diff --git a/Tests/AirRaidAlertTests/SimulationTests.swift b/Tests/AirRaidAlertTests/SimulationTests.swift
--- a/Tests/AirRaidAlertTests/SimulationTests.swift
+++ b/Tests/AirRaidAlertTests/SimulationTests.swift
@@ -141,10 +141,7 @@
             let actualLosses = residents.indices.filter { previous[$0] != .lost && residents[$0].status == .lost }
             XCTAssertEqual(Set(actualLosses), expectedLosses)
 
-            let recordedLosses = game.cities.reduce(0) { total, city in
-                total + (city.raid?.bombs.compactMap(\.casualties).reduce(0, +) ?? 0)
-            }
-            XCTAssertEqual(game.population - game.alive, recordedLosses)
+            XCTAssertEqual(game.population - game.alive, recordedLosses(in: game))
         }
         XCTAssertEqual(game.cities[2].damage, 30)
         let casualties = try XCTUnwrap(game.cities[2].raid).bombs.compactMap(\.casualties)
@@ -153,7 +150,7 @@
         XCTAssertGreaterThan(game.sheltered, 0)
     }
 
-    func testPauseFreezesClockAndRoundCanRestart() {
+    func testPauseAndRestartWithAllFortyEightRaidsSettled() {
         let game = Simulation(seed: 42)
         game.advance(by: 2.05)
         let pausedTime = game.elapsed
@@ -164,18 +161,79 @@
         XCTAssertEqual(game.cities[2].residents.map(\.position), positions)
         XCTAssertFalse(game.notify(cityID: 3))
         game.togglePause()
-        game.advance(by: 100)
+        var openingAlertPeak = 0
+        var lateAlertPeak = 0
+        while !game.isFinished {
+            game.advance(by: 0.25)
+            let alerts = game.cities.filter { $0.warning != nil && !$0.notified }.count
+            if game.elapsed <= 20 {
+                openingAlertPeak = max(openingAlertPeak, alerts)
+            } else if game.elapsed >= 60 {
+                lateAlertPeak = max(lateAlertPeak, alerts)
+            }
+        }
         XCTAssertTrue(game.isFinished)
         XCTAssertEqual(game.remaining, 0)
+        XCTAssertGreaterThanOrEqual(lateAlertPeak, 6)
+        XCTAssertGreaterThan(lateAlertPeak, openingAlertPeak)
         XCTAssertTrue(game.cities.allSatisfy { city in
-            city.damage == 30 && city.raid?.bombs.allSatisfy { $0.casualties != nil } == true
+            let starts = city.completedRaids.map(\.startedAt)
+            let wavesAreSeparated = zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= 16 - 0.000_001 }
+            return city.damage == 90 && city.raid == nil && starts.count == 3 && wavesAreSeparated &&
+                city.completedRaids.allSatisfy { raid in
+                    raid.bombs.count == 30 && raid.bombs.allSatisfy { $0.casualties != nil }
+                }
         })
+        XCTAssertEqual(game.population - game.alive, recordedLosses(in: game))
         game.reset()
         XCTAssertFalse(game.isFinished)
         XCTAssertFalse(game.isPaused)
         XCTAssertEqual(game.remaining, game.duration)
         XCTAssertEqual(game.alive, 2000)
-        XCTAssertTrue(game.cities.allSatisfy { $0.damage == 0 && $0.warning == nil && $0.raid == nil })
+        XCTAssertTrue(game.cities.allSatisfy { city in
+            city.damage == 0 && city.warning == nil && city.raid == nil && city.completedRaids.isEmpty
+        })
+    }
+
+    func testResidentsReturnToRoadAndTownCanBeNotifiedAgain() throws {
+        let game = Simulation(seed: 42)
+        game.advance(by: 2.05)
+        XCTAssertTrue(game.notify(cityID: 3))
+        XCTAssertFalse(game.notify(cityID: 3))
+        try finishFirstRaid(game)
+        let first = game.cities[2]
+        let residentID = try XCTUnwrap(first.residents.firstIndex { $0.status == .sheltered })
+        let shelter = first.residents[residentID].position
+        let aliveBeforeRelease = first.residents.filter { $0.status != .lost }.count
+        while game.cities[2].completedRaids.isEmpty && !game.isFinished {
+            game.advance(by: 0.1)
+        }
+        let cleared = game.cities[2]
+        XCTAssertEqual(cleared.completedRaids.count, 1)
+        XCTAssertNil(cleared.raid)
+        XCTAssertFalse(cleared.notified)
+        XCTAssertEqual(cleared.residents.filter { $0.status == .roaming }.count, aliveBeforeRelease)
+        let position = cleared.residents[residentID].position
+        XCTAssertLessThanOrEqual(hypot(position.x - shelter.x, position.y - shelter.y), 0.26)
+        XCTAssertFalse(game.notify(cityID: 3))
+
+        while game.cities[2].warning == nil && !game.isFinished {
+            game.advance(by: 0.25)
+        }
+        XCTAssertEqual(game.cities[2].warning, .yellow)
+        XCTAssertTrue(game.notify(cityID: 3))
+        XCTAssertTrue(game.cities[2].residents.contains { $0.status == .evacuating })
+        XCTAssertFalse(game.notify(cityID: 3))
+    }
+
+    private func recordedLosses(in game: Simulation) -> Int {
+        game.cities.reduce(0) { total, city in
+            var cityLosses = city.raid?.bombs.compactMap(\.casualties).reduce(0, +) ?? 0
+            for raid in city.completedRaids {
+                cityLosses += raid.bombs.compactMap(\.casualties).reduce(0, +)
+            }
+            return total + cityLosses
+        }
     }
 
     private func finishFirstRaid(_ game: Simulation) throws {
```

### `AGENTS.md`

```diff
diff --git a/AGENTS.md b/AGENTS.md
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -5,6 +5,7 @@
 - 《躲避空袭》是一款面向带实体 Touch Bar（触控条）的 MacBook 的休闲反应游戏，以抗日战争时期的虚构中国城市为背景。玩家依据预警向对应城市发送防空通知，帮助居民前往防空洞，提高存活率。
 - 主屏幕以 90° 垂直俯视呈现 4×4 排列的 16 座独立城市。建筑群是像素色面，居民是沿道路移动的点，地图呈抽象的卫星图像观感。HUD（游戏状态栏）显示时间与人口统计。主屏幕按从左至右、从上至下的顺序显示城镇名，预警时在城市边缘显示黄、橙、红标记。
 - 游戏仿真维护城市、道路、居民、预警与人口状态。飞机、投弹、落点、命中范围和居民点位置使用同一套仿真数据，原生 AppKit（macOS 界面框架）按这套数据绘制地图并接入实体 Touch Bar。16 个触控键使用与地图一致的地名和顺序，成功发送通知时播放防空警报。主屏幕承担观察和暂停操作。
+- 每局包含多座城市交叠的多波预警，后段会集中出现。每次通知服务于该城的当前一波。空袭解除后，仍存活的居民返回道路，旧波的落点痕迹继续保留。重开会重新编排后续预警，地图布局沿用同一份城市数据。
 
 ## 技术与运行方式
 
```
