# 会话-6《躲避空袭》居民降速与逐弹结算

## 背景与结果

- 旧版已有道路寻路和人口仿真，但空袭按整城暴露居民的概率减员，主屏幕仅另播一次爆炸特效。
- 日常速度由 2.4–5.0 降到 1.2–2.5 地图像素/秒，疏散速度由 6.8–9.7 降到 5.1–7.55 地图像素/秒。通知后仍沿原道路和避难路线移动。
- 红警结束后，每城有 5–8 架抽象像素飞机进入画面，总共 30 枚弹分批落地。飞机、空中的弹、爆点与命中范围都来自同一套仿真。到达落地时刻才结算，爆点内尚在地表的居民各计一次，范围外或已入洞的居民不受影响。
- 每枚弹的结算人数直接用于短暂的 `−N` 提示。顶部存活数取自同一批居民状态。爆炸、烟雾和地面痕迹出现在对应落点。Touch Bar（触控条）根据逐弹进度显示空袭中和已受击，空袭开始后不再接受本轮通知。
- 机群与落点在开局以独立随机种子生成，通知只改变居民行动和命中结果。仿真与界面共用游戏时钟，暂停冻结居民、空中图元与待结算事件。

## 测试方法与结果

- 用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` 执行 7 项自动测试，全部通过。覆盖移速、预警时序、每城 30 枚炸弹、投放位置与机身一致、空中阶段人口不减、逐枚核对命中点、提前通知改善结果，以及整局结算与重开。
- 在 1280 × 720 和 960 × 650 检查真实仿真的离屏画面。03 城机群和空中落弹可辨；一帧中已有 6 枚落地，累计命中 9 人，顶部存活数同时从 2000 降到 1991。后续帧检查了全部落地后的地面痕迹。
- 已用 `./run.sh --test-input` 构建并启动新版。先让 03 城的首轮预警自然经过，开局约第 8 秒观察机群，再核对随后各爆点的 `−N` 和顶部存活数。另开一轮，在约第 2 秒的黄警按 `3`，观察疏散与减员差异。空格可以冻结当前帧。触控条外观变化仍待实体设备验证。

## 代码变更

### `Sources/AirRaidAlert/Simulation.swift`

```diff
diff --git a/Sources/AirRaidAlert/Simulation.swift b/Sources/AirRaidAlert/Simulation.swift
--- a/Sources/AirRaidAlert/Simulation.swift
+++ b/Sources/AirRaidAlert/Simulation.swift
@@ -18,7 +18,7 @@
     fileprivate(set) var status = ResidentStatus.roaming
     fileprivate let walkingSpeed: Double
     fileprivate let evacuationSpeed: Double
-    fileprivate let exposureRisk: Double
+    fileprivate var random: SimulationRandom
     fileprivate var fromNode: Int
     fileprivate var toNode: Int
     fileprivate var edgeLength: Double
@@ -31,9 +31,52 @@
     fileprivate(set) var residents: [Resident]
     fileprivate(set) var warning: WarningPhase?
     fileprivate(set) var notified = false
-    fileprivate(set) var impactAge: Double?
+    fileprivate(set) var raid: RaidState?
     fileprivate(set) var damage = 0
     fileprivate let shelterRoutes: [ShelterRoute]
+}
+
+struct RaidState {
+    let startedAt: TimeInterval
+    let aircraft: [RaidAircraft]
+    let bombs: [RaidBomb]
+}
+
+struct RaidAircraft {
+    let heading: CGFloat
+    fileprivate let startsAt: TimeInterval
+    fileprivate let duration: TimeInterval
+    fileprivate let origin: CGPoint
+    fileprivate let destination: CGPoint
+
+    func position(at elapsed: TimeInterval) -> CGPoint? {
+        let progress = (elapsed - startsAt) / duration
+        guard (0...1).contains(progress) else { return nil }
+        return position(along: progress)
+    }
+
+    fileprivate func position(along progress: Double) -> CGPoint {
+        interpolate(from: origin, to: destination, progress: progress)
+    }
+}
+
+struct RaidBomb {
+    let dropTime: TimeInterval
+    let impactTime: TimeInterval
+    let impactPosition: CGPoint
+    let radius: CGFloat
+    fileprivate(set) var casualties: Int?
+    fileprivate let dropPosition: CGPoint
+
+    func position(at elapsed: TimeInterval) -> CGPoint? {
+        guard elapsed >= dropTime, elapsed < impactTime else { return nil }
+        let progress = (elapsed - dropTime) / (impactTime - dropTime)
+        return interpolate(from: dropPosition, to: impactPosition, progress: progress)
+    }
+}
+
+private func interpolate(from start: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
+    CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
 }
 
 // 从所有防空洞反向搜索，市民只需查表即可在道路上选择最近的避难路径。
@@ -45,7 +88,8 @@
 final class Simulation {
     private enum EventKind {
         case warning(WarningPhase)
-        case impact
+        case raid(RaidState)
+        case impact(bombIndex: Int)
     }
 
     private struct AlertEvent {
@@ -56,8 +100,6 @@
 
     private static let cityCount = 16
     private static let residentsPerCity = 125
-    private static let impactEffectDuration: TimeInterval = 2.4
-    private static let exposedLossChance = 0.42
     private static let maximumMovementStep: TimeInterval = 1.0 / 30
 
     let duration: TimeInterval = 100
@@ -66,10 +108,8 @@
     private(set) var cities: [CityState]
 
     private let startingCities: [CityState]
-    private let startingRandom: SimulationRandom
     private let events: [AlertEvent]
     private var nextEventIndex = 0
-    private var random: SimulationRandom
 
     var remaining: TimeInterval { duration - elapsed }
     var isFinished: Bool { elapsed >= duration }
@@ -91,18 +131,17 @@
                 shelterRoutes: Self.findShelterRoutes(in: map)
             )
         }
-        events = Self.makeAlertEvents(random: &random)
+        var raidRandom = SimulationRandom(state: seed ^ 0x5241_4944_504C_414E)
+        events = Self.makeAlertEvents(orderRandom: &random, raidRandom: &raidRandom)
         startingCities = cities
-        startingRandom = random
         self.cities = cities
-        self.random = random
     }
 
     func advance(by interval: TimeInterval) {
         guard !isPaused, !isFinished, interval.isFinite, interval > 0 else { return }
         let endTime = min(duration, elapsed + interval)
 
-        // 即使后台一次补算数秒，也精确停在每个预警和受击时刻。
+        // 每枚落弹前先把居民推进到命中时刻，同一份数据也驱动飞行和落地画面。
         while elapsed < endTime {
             let eventTime = nextEventIndex < events.count ? events[nextEventIndex].time : duration
             let nextTime = min(endTime, elapsed + Self.maximumMovementStep, eventTime)
@@ -131,7 +170,6 @@
         elapsed = 0
         isPaused = false
         cities = startingCities
-        random = startingRandom
         nextEventIndex = 0
     }
 
@@ -145,10 +183,13 @@
         return count
     }
 
-    private static func makeAlertEvents(random: inout SimulationRandom) -> [AlertEvent] {
+    private static func makeAlertEvents(
+        orderRandom: inout SimulationRandom,
+        raidRandom: inout SimulationRandom
+    ) -> [AlertEvent] {
         let openingCities = [3, 6, 9, 12, 15]
         let otherCities = (1...cityCount).filter { !openingCities.contains($0) }
-        let order = openingCities + otherCities.shuffled(using: &random)
+        let order = openingCities + otherCities.shuffled(using: &orderRandom)
         let startTimes: [TimeInterval] = [2, 4.5, 8, 10, 14, 20, 25, 31, 35, 43, 49, 54, 63, 67, 77, 89]
         var events: [AlertEvent] = []
         for (id, start) in zip(order, startTimes) {
@@ -156,15 +197,76 @@
             events.append(AlertEvent(time: start, cityIndex: cityIndex, kind: .warning(.yellow)))
             events.append(AlertEvent(time: start + 2, cityIndex: cityIndex, kind: .warning(.orange)))
             events.append(AlertEvent(time: start + 4, cityIndex: cityIndex, kind: .warning(.red)))
-            events.append(AlertEvent(time: start + 6, cityIndex: cityIndex, kind: .impact))
+            let raid = makeRaid(startingAt: start + 6, random: &raidRandom)
+            events.append(AlertEvent(time: raid.startedAt, cityIndex: cityIndex, kind: .raid(raid)))
+            for (bombIndex, bomb) in raid.bombs.enumerated() {
+                events.append(AlertEvent(time: bomb.impactTime, cityIndex: cityIndex, kind: .impact(bombIndex: bombIndex)))
+            }
         }
         events.sort { first, second in
-            if first.time == second.time {
-                return first.cityIndex < second.cityIndex
-            }
-            return first.time < second.time
+            if first.time != second.time { return first.time < second.time }
+            if first.cityIndex != second.cityIndex { return first.cityIndex < second.cityIndex }
+            guard case .impact(let firstIndex) = first.kind,
+                  case .impact(let secondIndex) = second.kind else { return false }
+            return firstIndex < secondIndex
         }
         return events
+    }
+
+    private static func makeRaid(startingAt startedAt: TimeInterval, random: inout SimulationRandom) -> RaidState {
+        let count = Int.random(in: 5...8, using: &random)
+        let bombCount = 30
+        let leftToRight = Bool.random(using: &random)
+        let mapWidth = CGFloat(CityMap.width)
+        let mapHeight = CGFloat(CityMap.height)
+        let initialX: CGFloat = leftToRight ? -6 : mapWidth + 6
+        let endX: CGFloat = leftToRight ? mapWidth + 6 : -6
+        var aircraft: [RaidAircraft] = []
+        for index in 0..<count {
+            let offset = CGFloat(index) / CGFloat(count - 1)
+            let centerY = 9 + (mapHeight - 18) * offset
+            let initialY = centerY + CGFloat(random.fraction() - 0.5) * 3
+            let endY = centerY + CGFloat(random.fraction() - 0.5) * 6
+            aircraft.append(RaidAircraft(
+                heading: atan2(endY - initialY, endX - initialX),
+                startsAt: startedAt + Double(index) * 0.10,
+                duration: 3.95 + random.fraction() * 0.17,
+                origin: CGPoint(x: initialX, y: initialY),
+                destination: CGPoint(x: endX, y: endY)
+            ))
+        }
+
+        // 落点在开局由独立种子预排，间隔按飞机航迹分布，与居民的位置和疏散无关。
+        var bombs: [RaidBomb] = []
+        for index in 0..<bombCount {
+            let aircraftIndex = index % count
+            let plane = aircraft[aircraftIndex]
+            let pass = index / count
+            let passes = (bombCount - 1 - aircraftIndex) / count + 1
+            let phase = (Double(pass) + 0.25 + random.fraction() * 0.5) / Double(passes)
+            let routeProgress = 0.17 + 0.65 * phase
+            let dropTime = plane.startsAt + plane.duration * routeProgress
+            let dropPosition = plane.position(along: (dropTime - plane.startsAt) / plane.duration)
+            let drift = CGFloat(2 + random.fraction() * 4) * (leftToRight ? 1 : -1)
+            let impactPosition = CGPoint(
+                x: dropPosition.x + drift,
+                y: dropPosition.y + CGFloat(random.fraction() - 0.5) * 6
+            )
+            bombs.append(RaidBomb(
+                dropTime: dropTime,
+                impactTime: dropTime + 0.46 + random.fraction() * 0.27,
+                impactPosition: impactPosition,
+                radius: CGFloat(3.2 + random.fraction() * 1.7),
+                dropPosition: dropPosition
+            ))
+        }
+        bombs.sort { first, second in
+            if first.impactTime == second.impactTime {
+                return first.dropTime < second.dropTime
+            }
+            return first.impactTime < second.impactTime
+        }
+        return RaidState(startedAt: startedAt, aircraft: aircraft, bombs: bombs)
     }
 
     private func applyDueEvents() {
@@ -174,46 +276,50 @@
             switch event.kind {
             case .warning(let phase):
                 cities[event.cityIndex].warning = phase
-            case .impact:
-                Self.applyImpact(to: &cities[event.cityIndex])
-            }
-        }
-    }
-
-    private static func applyImpact(to city: inout CityState) {
-        city.warning = nil
-        city.damage = 1 + city.id % 4
-        city.impactAge = 0
-        // 受击时只统计尚暴露在外的居民，已避难者始终安全。
+            case .raid(let raid):
+                cities[event.cityIndex].warning = nil
+                cities[event.cityIndex].raid = raid
+            case .impact(let bombIndex):
+                Self.applyImpact(of: bombIndex, to: &cities[event.cityIndex])
+            }
+        }
+    }
+
+    private static func applyImpact(of bombIndex: Int, to city: inout CityState) {
+        guard let raid = city.raid, raid.bombs[bombIndex].casualties == nil else { return }
+        let bomb = raid.bombs[bombIndex]
+        let radiusSquared = bomb.radius * bomb.radius
+        var casualties = 0
+
+        // 重叠的爆点只会命中仍在地表移动的点，已失去或已入洞的居民不再参与。
         for index in city.residents.indices {
-            let status = city.residents[index].status
-            guard status == .roaming || status == .evacuating else { continue }
-            if city.residents[index].exposureRisk < exposedLossChance {
+            let resident = city.residents[index]
+            guard resident.status == .roaming || resident.status == .evacuating else { continue }
+            let dx = resident.position.x - bomb.impactPosition.x
+            let dy = resident.position.y - bomb.impactPosition.y
+            if dx * dx + dy * dy <= radiusSquared {
                 city.residents[index].status = .lost
-            }
-        }
+                casualties += 1
+            }
+        }
+        var bombs = raid.bombs
+        bombs[bombIndex].casualties = casualties
+        city.raid = RaidState(startedAt: raid.startedAt, aircraft: raid.aircraft, bombs: bombs)
+        city.damage += 1
     }
 
     private func moveResidents(by interval: TimeInterval) {
         guard interval > 0 else { return }
         for index in cities.indices {
-            Self.moveResidents(in: &cities[index], by: interval, random: &random)
-        }
-    }
-
-    private static func moveResidents(
-        in city: inout CityState,
-        by interval: TimeInterval,
-        random: inout SimulationRandom
-    ) {
-        if let age = city.impactAge {
-            let nextAge = age + interval
-            city.impactAge = nextAge < impactEffectDuration ? nextAge : nil
-        }
+            Self.moveResidents(in: &cities[index], by: interval)
+        }
+    }
+
+    private static func moveResidents(in city: inout CityState, by interval: TimeInterval) {
         let roads = city.map.roads
         let routes = city.shelterRoutes
         for index in city.residents.indices {
-            move(&city.residents[index], along: roads, routes: routes, by: interval, random: &random)
+            move(&city.residents[index], along: roads, routes: routes, by: interval)
         }
     }
 
@@ -225,9 +331,9 @@
         // 部分较远的住民需要完整预警窗口，橙色或红色阶段才通知会缩短可达距离。
         return Resident(
             position: position(from: start, to: end, fraction: fraction, on: roads),
-            walkingSpeed: 2.4 + 2.6 * random.fraction(),
-            evacuationSpeed: 6.8 + 2.9 * random.fraction(),
-            exposureRisk: random.fraction(),
+            walkingSpeed: 1.2 + 1.3 * random.fraction(),
+            evacuationSpeed: 5.1 + 2.45 * random.fraction(),
+            random: SimulationRandom(state: random.next()),
             fromNode: start,
             toNode: end,
             edgeLength: length,
@@ -255,8 +361,7 @@
         _ resident: inout Resident,
         along roads: [RoadNode],
         routes: [ShelterRoute],
-        by interval: TimeInterval,
-        random: inout SimulationRandom
+        by interval: TimeInterval
     ) {
         let speed: Double
         switch resident.status {
@@ -288,7 +393,9 @@
                 }
                 nextNode = routes[node].next
             } else {
-                nextNode = roamingDestination(from: node, previous: resident.fromNode, roads: roads, random: &random)
+                nextNode = roamingDestination(
+                    from: node, previous: resident.fromNode, roads: roads, random: &resident.random
+                )
             }
             guard let nextNode else { return }
             let edgeLength = edgeDistance(from: node, to: nextNode, on: roads)
@@ -345,16 +452,11 @@
     }
 
     private static func position(from start: Int, to end: Int, fraction: Double, on roads: [RoadNode]) -> CGPoint {
-        let origin = roads[start].position
-        let destination = roads[end].position
-        return CGPoint(
-            x: origin.x + (destination.x - origin.x) * fraction,
-            y: origin.y + (destination.y - origin.y) * fraction
-        )
-    }
-}
-
-private struct SimulationRandom: RandomNumberGenerator {
+        interpolate(from: roads[start].position, to: roads[end].position, progress: fraction)
+    }
+}
+
+fileprivate struct SimulationRandom: RandomNumberGenerator {
     var state: UInt64
 
     mutating func next() -> UInt64 {
```

### `Sources/AirRaidAlert/GameView.swift`

```diff
diff --git a/Sources/AirRaidAlert/GameView.swift b/Sources/AirRaidAlert/GameView.swift
--- a/Sources/AirRaidAlert/GameView.swift
+++ b/Sources/AirRaidAlert/GameView.swift
@@ -14,6 +14,11 @@
     private let secondaryInk = NSColor(srgbRed: 0.58, green: 0.67, blue: 0.66, alpha: 1)
     private let paperInk = NSColor(srgbRed: 0.91, green: 0.93, blue: 0.87, alpha: 1)
     private let shelterInk = NSColor(srgbRed: 0.43, green: 0.88, blue: 0.74, alpha: 1)
+    private let aircraftInk = NSColor(srgbRed: 0.68, green: 0.79, blue: 0.85, alpha: 1)
+    private let bombInk = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.43, alpha: 1)
+    private let flashInk = NSColor(srgbRed: 1, green: 0.87, blue: 0.63, alpha: 1)
+    private let smokeInk = NSColor(srgbRed: 0.67, green: 0.64, blue: 0.59, alpha: 1)
+    private let rubbleInk = NSColor(srgbRed: 0.29, green: 0.24, blue: 0.20, alpha: 0.84)
 
     override var isFlipped: Bool { true }
     override var isOpaque: Bool { true }
@@ -121,9 +126,14 @@
             context.restoreGState()
         }
         context.setShouldAntialias(false)
-        drawDamage(city: city, artwork: artwork, pixel: pixel, in: context)
+        if let raid = city.raid {
+            drawImpactScars(raid.bombs, pixel: pixel, in: context)
+        }
         drawResidents(city.residents, pixel: pixel, in: context)
         drawShelters(city, pixel: pixel, in: context)
+        if let raid = city.raid {
+            drawRaid(raid, elapsed: simulation.elapsed, pixel: pixel, in: context)
+        }
         if let phase = city.warning {
             drawWarning(phase: phase, rect: rect, in: context)
         }
@@ -188,35 +198,142 @@
         context.fill(marks)
     }
 
-    private func drawDamage(
-        city: CityState, artwork: CityArtwork, pixel: MapProjection, in context: CGContext
+    private func drawImpactScars(_ bombs: [RaidBomb], pixel: MapProjection, in context: CGContext) {
+        // 每个地面痕迹对应已结算的落点，绘制在居民与防空洞标记下方。
+        var rims: [CGRect] = []
+        var cores: [CGRect] = []
+        for bomb in bombs where bomb.casualties != nil {
+            let size = bomb.radius * 0.56
+            rims.append(pixel.mapSquare(at: bomb.impactPosition, size: size))
+            cores.append(pixel.mapSquare(at: bomb.impactPosition, size: size * 0.50))
+        }
+        context.setFillColor(rubbleInk.cgColor)
+        context.fill(rims)
+        context.setFillColor(background.withAlphaComponent(0.83).cgColor)
+        context.fill(cores)
+    }
+
+    private func drawRaid(_ raid: RaidState, elapsed: TimeInterval, pixel: MapProjection, in context: CGContext) {
+        var lossLabels: [CGRect] = []
+        for bomb in raid.bombs {
+            if let point = bomb.position(at: elapsed) {
+                drawFallingBomb(bomb, at: point, elapsed: elapsed, pixel: pixel, in: context)
+            } else if let casualties = bomb.casualties {
+                let age = CGFloat(elapsed - bomb.impactTime)
+                if (0..<1.45).contains(age) {
+                    drawBurst(bomb, age: age, casualties: casualties, pixel: pixel, in: context)
+                }
+                if casualties > 0, (0..<0.56).contains(age) {
+                    drawLossLabel(casualties, at: bomb.impactPosition, age: age, pixel: pixel, placed: &lossLabels)
+                }
+            }
+        }
+        for aircraft in raid.aircraft {
+            guard let point = aircraft.position(at: elapsed) else { continue }
+            let position = pixel.screenPoint(at: point)
+            let unit = max(1.15, min(2, pixel.rect.width / 148))
+            context.saveGState()
+            context.translateBy(x: position.x, y: position.y)
+            context.rotate(by: aircraft.heading)
+            context.scaleBy(x: unit, y: unit)
+            context.setLineWidth(0.58)
+            context.setLineJoin(.round)
+            context.setStrokeColor(background.cgColor)
+            context.setFillColor(aircraftInk.cgColor)
+            context.addPath(Self.aircraftOutline)
+            context.drawPath(using: .fillStroke)
+            paint(CGRect(x: -2.2, y: -0.24, width: 4.5, height: 0.48), color: paperInk, in: context)
+            context.restoreGState()
+        }
+    }
+
+    private func drawFallingBomb(
+        _ bomb: RaidBomb, at point: CGPoint, elapsed: TimeInterval, pixel: MapProjection, in context: CGContext
     ) {
-        guard city.damage > 0, !artwork.impactSites.isEmpty else { return }
-        let ruin = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.14, alpha: 0.92)
-        let fragments = NSColor(srgbRed: 0.40, green: 0.34, blue: 0.30, alpha: 1)
-        for site in artwork.impactSites.prefix(min(artwork.impactSites.count, city.damage * 3)) {
-            paint(pixel.tileRect(at: site, width: 3, height: 2), color: ruin, in: context)
-            paint(pixel.tileRect(at: site, width: 1, height: 1), color: fragments, in: context)
-        }
-        guard let age = city.impactAge, age < 1.55 else { return }
-        let siteIndex = min(artwork.impactSites.count - 1, max(0, (city.damage - 1) * 3))
-        let origin = artwork.impactSites[siteIndex]
-        let bright = NSColor(srgbRed: 0.99, green: 0.71, blue: 0.41, alpha: 1)
-        let mist = NSColor(srgbRed: 0.53, green: 0.54, blue: 0.50, alpha: 1)
-        let range = CGFloat(age) * 9
-        if age < 0.23 {
-            let flash = pixel.tileRect(at: origin, width: 3, height: 3)
-            paint(flash, color: bright.withAlphaComponent(CGFloat(1 - age * 2)), in: context)
-        }
-        for shard in 0..<13 {
-            let angle = CGFloat(shard) * 2.4
-            let length = range * (0.38 + CGFloat(shard % 5) * 0.115)
-            let point = CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
-            let color = age < 0.38 ? bright : mist
-            let fade = CGFloat(max(0, 1 - age / 1.55))
-            paint(pixel.tileRect(at: point, width: 1, height: 1), color: color.withAlphaComponent(fade), in: context)
-        }
-    }
+        // 短残迹来自同一枚落弹的先前位置，随当前弹体一起消失。
+        for index in [2, 1] {
+            let time = elapsed - Double(index) * 0.07
+            guard let previous = bomb.position(at: time) else { continue }
+            let opacity: CGFloat = index == 2 ? 0.34 : 0.64
+            paint(pixel.dot(at: previous, size: 1.5), color: bombInk.withAlphaComponent(opacity), in: context)
+        }
+        paint(pixel.dot(at: point, size: 4.1), color: background.withAlphaComponent(0.84), in: context)
+        paint(pixel.dot(at: point, size: 2.8), color: bombInk, in: context)
+    }
+
+    private func drawBurst(
+        _ bomb: RaidBomb, age: CGFloat, casualties: Int, pixel: MapProjection, in context: CGContext
+    ) {
+        let origin = bomb.impactPosition
+        if age < 0.32 {
+            let flashProgress = age / 0.32
+            let range = bomb.radius * (0.28 + flashProgress * 0.72)
+            let ink = casualties > 0 ? flashInk : bombInk
+            paint(
+                pixel.dot(at: origin, size: 4.4 - flashProgress * 2),
+                color: ink.withAlphaComponent(1 - flashProgress * 0.68), in: context
+            )
+            for index in 0..<8 {
+                let angle = CGFloat(index) * .pi / 4
+                let point = CGPoint(x: origin.x + cos(angle) * range, y: origin.y + sin(angle) * range)
+                paint(
+                    pixel.dot(at: point, size: 2.1),
+                    color: bombInk.withAlphaComponent(1 - flashProgress * 0.84), in: context
+                )
+            }
+        }
+        guard age >= 0.12 else { return }
+        let smokeProgress = (age - 0.12) / 1.33
+        for index in 0..<3 {
+            let offset = CGFloat(index)
+            let drift = CGPoint(
+                x: origin.x + bomb.radius * smokeProgress * (0.10 + offset * 0.20),
+                y: origin.y - bomb.radius * (smokeProgress * 0.58 + offset * 0.15)
+            )
+            paint(
+                pixel.dot(at: drift, size: 2.5 + smokeProgress * 1.3),
+                color: smokeInk.withAlphaComponent((1 - smokeProgress) * (0.58 - offset * 0.11)), in: context
+            )
+        }
+    }
+
+    private func drawLossLabel(
+        _ casualties: Int, at point: CGPoint, age: CGFloat, pixel: MapProjection, placed: inout [CGRect]
+    ) {
+        let text = "−\(casualties)"
+        let width = CGFloat(text.count) * 6
+        let center = pixel.screenPoint(at: point)
+        // 爆点接近时尝试另一侧，给每个扣减数字留出独立的阅读位置。
+        let offsets: [(CGFloat, CGFloat)] = [(5, -12), (-width - 4, -12), (5, 4), (-width - 4, 4)]
+        for (x, y) in offsets {
+            let rect = CGRect(
+                x: min(max(center.x + x, pixel.rect.minX + 2), pixel.rect.maxX - width - 2),
+                y: min(max(center.y + y - age * 6, pixel.rect.minY + 2), pixel.rect.maxY - 12),
+                width: width, height: 11
+            )
+            guard !placed.contains(where: { $0.intersects(rect) }) else { continue }
+            placed.append(rect)
+            let opacity = min(1, (0.56 - age) / 0.24)
+            drawText(text, at: rect.origin, font: Self.digits(9), color: flashInk.withAlphaComponent(opacity))
+            return
+        }
+    }
+
+    // 机形以向右为原点，图元根据模型朝向旋转。
+    private static let aircraftOutline: CGPath = {
+        let vertices = [
+            CGPoint(x: 4.7, y: 0), CGPoint(x: 3.1, y: -0.8), CGPoint(x: 1.1, y: -0.8),
+            CGPoint(x: -0.15, y: -3.55), CGPoint(x: -1.45, y: -3.55), CGPoint(x: -1.12, y: -0.8),
+            CGPoint(x: -2.72, y: -0.8), CGPoint(x: -3.46, y: -1.7), CGPoint(x: -4.18, y: -1.7),
+            CGPoint(x: -3.95, y: 0), CGPoint(x: -4.18, y: 1.7), CGPoint(x: -3.46, y: 1.7),
+            CGPoint(x: -2.72, y: 0.8), CGPoint(x: -1.12, y: 0.8), CGPoint(x: -1.45, y: 3.55),
+            CGPoint(x: -0.15, y: 3.55), CGPoint(x: 1.1, y: 0.8), CGPoint(x: 3.1, y: 0.8)
+        ]
+        let path = CGMutablePath()
+        path.addLines(between: vertices)
+        path.closeSubpath()
+        return path
+    }()
 
     private func drawResultCard(in context: CGContext) {
         let width: CGFloat = 246
@@ -314,19 +431,20 @@
     private var stepX: CGFloat { rect.width / CGFloat(CityMap.width) }
     private var stepY: CGFloat { rect.height / CGFloat(CityMap.height) }
 
+    func screenPoint(at point: CGPoint) -> CGPoint {
+        CGPoint(x: rect.minX + point.x * stepX, y: rect.minY + point.y * stepY)
+    }
+
     func dot(at point: CGPoint, size: CGFloat) -> CGRect {
         let extent = max(1, (size * scale).rounded()) / scale
-        let x = rect.minX + point.x * stepX - extent / 2
-        let y = rect.minY + point.y * stepY - extent / 2
-        return CGRect(x: snap(x), y: snap(y), width: extent, height: extent)
-    }
-
-    func tileRect(at point: CGPoint, width: CGFloat, height: CGFloat) -> CGRect {
-        CGRect(
-            x: snap(rect.minX + point.x.rounded(.down) * stepX),
-            y: snap(rect.minY + point.y.rounded(.down) * stepY),
-            width: snap(width * stepX), height: snap(height * stepY)
-        )
+        let center = screenPoint(at: point)
+        return CGRect(
+            x: snap(center.x - extent / 2), y: snap(center.y - extent / 2), width: extent, height: extent
+        )
+    }
+
+    func mapSquare(at point: CGPoint, size: CGFloat) -> CGRect {
+        dot(at: point, size: size * min(stepX, stepY))
     }
 
     private func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
@@ -334,12 +452,10 @@
 
 private struct CityArtwork {
     let image: CGImage?
-    let impactSites: [CGPoint]
 
     init(map: CityMap, cityID: Int) {
         var rasters: [UInt8] = []
         rasters.reserveCapacity(map.tiles.count * 4)
-        var roofCenters: [CGPoint] = []
         for (index, tile) in map.tiles.enumerated() {
             let x = index % CityMap.width
             let y = index / CityMap.width
@@ -354,13 +470,6 @@
             rasters.append(UInt8(clamping: swatch.1 + shade))
             rasters.append(UInt8(clamping: swatch.2 + shade))
             rasters.append(255)
-            if tile.isRoof && hasRoofAbove && hasRoofToLeft {
-                roofCenters.append(CGPoint(x: x, y: y))
-            }
-        }
-        let stride = max(1, roofCenters.count / 11)
-        impactSites = roofCenters.enumerated().compactMap { index, point in
-            (index + cityID * 3) % stride == 0 ? point : nil
         }
         if let provider = CGDataProvider(data: Data(rasters) as CFData) {
             image = CGImage(
```

### `Sources/AirRaidAlert/TouchBarController.swift`

```diff
diff --git a/Sources/AirRaidAlert/TouchBarController.swift b/Sources/AirRaidAlert/TouchBarController.swift
--- a/Sources/AirRaidAlert/TouchBarController.swift
+++ b/Sources/AirRaidAlert/TouchBarController.swift
@@ -65,11 +65,15 @@
 
 private final class CityTouchButton: NSButton {
     enum VisualState: Equatable {
-        case normal, yellow, orange, red, notified, struck
+        case normal, yellow, orange, red, notified, raiding, struck
 
         init(city: CityState) {
             guard let warning = city.warning else {
-                self = city.damage > 0 ? .struck : .normal
+                if let raid = city.raid {
+                    self = city.damage < raid.bombs.count ? .raiding : .struck
+                } else {
+                    self = .normal
+                }
                 return
             }
             if city.notified {
@@ -92,6 +96,7 @@
             case .orange: return "橙色预警"
             case .red: return "红色预警"
             case .notified: return "已发送疏散通知"
+            case .raiding: return "空袭中"
             case .struck: return "已受击"
             }
         }
@@ -103,6 +108,7 @@
             case .orange: return NSColor(red: 0.96, green: 0.56, blue: 0.32, alpha: 1)
             case .red: return NSColor(red: 0.97, green: 0.44, blue: 0.42, alpha: 1)
             case .notified: return NSColor(red: 0.38, green: 0.78, blue: 0.64, alpha: 1)
+            case .raiding: return NSColor(red: 0.68, green: 0.41, blue: 0.39, alpha: 1)
             case .struck: return NSColor(white: 0.11, alpha: 1)
             }
         }
```

### `Tests/AirRaidAlertTests/SimulationTests.swift`

```diff
diff --git a/Tests/AirRaidAlertTests/SimulationTests.swift b/Tests/AirRaidAlertTests/SimulationTests.swift
--- a/Tests/AirRaidAlertTests/SimulationTests.swift
+++ b/Tests/AirRaidAlertTests/SimulationTests.swift
@@ -31,11 +31,15 @@
         }
     }
 
-    func testMovingDotsAndTwoSecondAlertPhases() {
+    func testSlowerDotsAndTwoSecondAlertPhases() {
         let game = Simulation(seed: 42)
         let initial = game.cities[2].residents.map(\.position)
         game.advance(by: 1)
-        XCTAssertNotEqual(game.cities[2].residents.map(\.position), initial)
+        let displacements = zip(initial, game.cities[2].residents.map(\.position)).map {
+            hypot($1.x - $0.x, $1.y - $0.y)
+        }
+        XCTAssertGreaterThan(displacements.max() ?? 0, 0)
+        XCTAssertLessThanOrEqual(displacements.max() ?? 0, 2.6)
         XCTAssertNil(game.cities[2].warning)
         game.advance(by: 1.05)
         XCTAssertEqual(game.cities[2].warning, .yellow)
@@ -45,11 +49,12 @@
         XCTAssertEqual(game.cities[2].warning, .red)
         game.advance(by: 2)
         XCTAssertNil(game.cities[2].warning)
-        XCTAssertNotNil(game.cities[2].impactAge)
-        XCTAssertGreaterThan(game.cities[2].damage, 0)
+        XCTAssertNotNil(game.cities[2].raid)
+        XCTAssertEqual(game.cities[2].damage, 0)
+        XCTAssertEqual(game.alive, game.population)
     }
 
-    func testEarlyNotificationSavesMoreResidentsThanNoNotification() {
+    func testEarlyNotificationSavesMoreResidentsThanNoNotification() throws {
         let protected = Simulation(seed: 42)
         let unprotected = Simulation(seed: 42)
         protected.advance(by: 2.05)
@@ -57,24 +62,92 @@
         XCTAssertFalse(protected.notify(cityID: 3))
         XCTAssertFalse(protected.notify(cityID: 0))
         XCTAssertTrue(protected.cities[2].residents.contains { $0.status == .evacuating })
-        protected.advance(by: 6)
-        unprotected.advance(by: 8.05)
+        try finishFirstRaid(protected)
+        try finishFirstRaid(unprotected)
         XCTAssertGreaterThan(protected.sheltered, unprotected.sheltered)
         XCTAssertGreaterThan(protected.alive, unprotected.alive)
         XCTAssertEqual(protected.population, unprotected.population)
     }
 
-    func testLateNotificationLeavesMoreResidentsExposed() {
+    func testLateNotificationLeavesMoreResidentsExposed() throws {
         let early = Simulation(seed: 42)
         let late = Simulation(seed: 42)
         early.advance(by: 2.05)
         late.advance(by: 6.05)
         XCTAssertTrue(early.notify(cityID: 3))
         XCTAssertTrue(late.notify(cityID: 3))
-        early.advance(by: 6)
-        late.advance(by: 2)
+        try finishFirstRaid(early)
+        try finishFirstRaid(late)
         XCTAssertGreaterThan(early.sheltered, late.sheltered)
         XCTAssertGreaterThan(early.alive, late.alive)
+        XCTAssertEqual(early.cities[2].raid?.bombs.map(\.impactPosition), late.cities[2].raid?.bombs.map(\.impactPosition))
+    }
+
+    func testRaidShowsAircraftAndBombsBeforeAnyPopulationChange() throws {
+        let game = Simulation(seed: 42)
+        game.advance(by: 8.05)
+        let raid = try XCTUnwrap(game.cities[2].raid)
+        XCTAssertTrue((5...8).contains(raid.aircraft.count))
+        XCTAssertEqual(raid.bombs.count, 30)
+        XCTAssertTrue(raid.bombs.allSatisfy { $0.dropTime >= raid.startedAt && $0.dropTime < $0.impactTime })
+        for bomb in raid.bombs {
+            let release = try XCTUnwrap(bomb.position(at: bomb.dropTime))
+            XCTAssertTrue(raid.aircraft.contains { aircraft in
+                guard let plane = aircraft.position(at: bomb.dropTime) else { return false }
+                return hypot(release.x - plane.x, release.y - plane.y) < 0.000_001
+            })
+        }
+        let first = try XCTUnwrap(raid.bombs.min { $0.impactTime < $1.impactTime })
+        let dropping = (first.dropTime + first.impactTime) / 2
+        XCTAssertNil(first.position(at: first.dropTime - 0.01))
+        XCTAssertNotNil(first.position(at: dropping))
+        XCTAssertNil(first.position(at: first.impactTime + 0.01))
+        game.advance(by: dropping - game.elapsed)
+        XCTAssertTrue(raid.aircraft.contains { $0.position(at: game.elapsed) != nil })
+        XCTAssertEqual(game.alive, game.population)
+        XCTAssertTrue(game.cities[2].raid?.bombs.allSatisfy { $0.casualties == nil } ?? false)
+    }
+
+    func testEachBombOnlyCountsOutdoorResidentsInsideItsVisibleFootprint() throws {
+        let game = Simulation(seed: 42)
+        game.advance(by: 6.05)
+        XCTAssertTrue(game.notify(cityID: 3))
+        game.advance(by: 2)
+        let raid = try XCTUnwrap(game.cities[2].raid)
+        let impactTimes = Set(raid.bombs.map(\.impactTime)).sorted()
+        for time in impactTimes {
+            let previous = game.cities[2].residents.map(\.status)
+            game.advance(by: time - game.elapsed)
+            let city = game.cities[2]
+            let bombs = try XCTUnwrap(city.raid?.bombs.filter { $0.impactTime == time })
+            let residents = city.residents
+            var exposed = Set(residents.indices.filter {
+                previous[$0] != .lost && residents[$0].status != .sheltered
+            })
+            var expectedLosses = Set<Int>()
+            for bomb in bombs {
+                // 用落地当刻的点位置和画面所用的圆形范围独立重算命中。
+                let hit = exposed.filter { index in
+                    let point = residents[index].position
+                    return hypot(point.x - bomb.impactPosition.x, point.y - bomb.impactPosition.y) <= bomb.radius
+                }
+                XCTAssertEqual(bomb.casualties, hit.count)
+                expectedLosses.formUnion(hit)
+                exposed.subtract(hit)
+            }
+            let actualLosses = residents.indices.filter { previous[$0] != .lost && residents[$0].status == .lost }
+            XCTAssertEqual(Set(actualLosses), expectedLosses)
+
+            let recordedLosses = game.cities.reduce(0) { total, city in
+                total + (city.raid?.bombs.compactMap(\.casualties).reduce(0, +) ?? 0)
+            }
+            XCTAssertEqual(game.population - game.alive, recordedLosses)
+        }
+        XCTAssertEqual(game.cities[2].damage, 30)
+        let casualties = try XCTUnwrap(game.cities[2].raid).bombs.compactMap(\.casualties)
+        XCTAssertTrue(casualties.contains(0))
+        XCTAssertTrue(casualties.contains { $0 > 0 })
+        XCTAssertGreaterThan(game.sheltered, 0)
     }
 
     func testPauseFreezesClockAndRoundCanRestart() {
@@ -91,11 +164,20 @@
         game.advance(by: 100)
         XCTAssertTrue(game.isFinished)
         XCTAssertEqual(game.remaining, 0)
+        XCTAssertTrue(game.cities.allSatisfy { city in
+            city.damage == 30 && city.raid?.bombs.allSatisfy { $0.casualties != nil } == true
+        })
         game.reset()
         XCTAssertFalse(game.isFinished)
         XCTAssertFalse(game.isPaused)
         XCTAssertEqual(game.remaining, game.duration)
         XCTAssertEqual(game.alive, 2000)
-        XCTAssertTrue(game.cities.allSatisfy { $0.damage == 0 && $0.warning == nil })
+        XCTAssertTrue(game.cities.allSatisfy { $0.damage == 0 && $0.warning == nil && $0.raid == nil })
+    }
+
+    private func finishFirstRaid(_ game: Simulation) throws {
+        game.advance(by: 8.05 - game.elapsed)
+        let lastImpact = try XCTUnwrap(game.cities[2].raid?.bombs.map(\.impactTime).max())
+        game.advance(by: lastImpact - game.elapsed + 0.01)
     }
 }
```
