# 会话-5《躲避空袭》原生游戏原型

## 背景与结果

- 将美术方向改为 90° 垂直俯视的抽象卫星像素图。地图是 4×4 排列的 16 座独立城市，建筑由像素色块组成，居民以细小的活动方点呈现。
- 实现 Swift 与 AppKit（macOS 界面框架）原型。无外部依赖。每城 125 个居民点，合计 2000。首轮为 100 秒，警报按黄、橙、红各持续两秒。居民收到通知后沿连通道路前往最近的防空洞。已避难居民计入统计，未能及时避难的居民在受击时可能损失。
- 主屏幕绘制城市、预警、受击效果和人口统计，提供暂停、继续和重开。实体 Touch Bar（触控条）提供与城市编号对应的 16 个按键，已发送通知的按键转为青绿。

## 测试方法与结果

- 使用完整 Xcode 工具链执行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`，通过 5 项自动测试。覆盖城市差异与道路连通、居民移动、两秒预警切换、提前与延后通知的结果差异，以及暂停与重开。
- 核对了 1280 × 720 与 960 × 650 两档离屏渲染。16 个编号、顶部中文统计、三色预警及沿路分布的居民点均清楚可辨。
- 用 `./run.sh --test-input` 构建并启动 macOS 程序。缺少 Swift 包管理器模块的命令行工具环境下，脚本会选用本机已安装的标准位置 Xcode。测试键位四行 `1 2 3 4 / Q W E R / A S D F / Z X C V` 对应 01 至 16。第 2 秒左右可按 `3` 通知首座预警城市并观察点变为青绿、朝避难点聚集以及人数变化。空格暂停或继续，一轮结束后回车重开。
- AppKit 原生触控条项目已在无窗口联调中核对 16 键顺序、预警启用、暂停禁用和点按回调。实体设备上的宽度和点按仍待真机验证。

## 代码变更

### `.gitignore`

```diff
diff --git a/.gitignore b/.gitignore
new file mode 100644
index 00000000..af136696
--- /dev/null
+++ b/.gitignore
@@ -0,0 +1,2 @@
+/.build/
+/.swiftpm/
```

### `Package.swift`

```diff
diff --git a/Package.swift b/Package.swift
new file mode 100644
index 00000000..b4bb2d4a
--- /dev/null
+++ b/Package.swift
@@ -0,0 +1,11 @@
+// swift-tools-version: 5.7
+import PackageDescription
+
+let package = Package(
+    name: "AirRaidAlert",
+    platforms: [.macOS(.v12)],
+    targets: [
+        .executableTarget(name: "AirRaidAlert"),
+        .testTarget(name: "AirRaidAlertTests", dependencies: ["AirRaidAlert"])
+    ]
+)
```

### `run.sh`

```diff
diff --git a/run.sh b/run.sh
new file mode 100755
index 00000000..754de3c1
--- /dev/null
+++ b/run.sh
@@ -0,0 +1,14 @@
+#!/bin/bash
+set -euo pipefail
+
+cd -- "$(dirname -- "$0")"
+
+# 命令行工具缺少包管理器模块时，使用本机已有的完整 Xcode。
+if [[ -z "${DEVELOPER_DIR:-}" &&
+      "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools &&
+      -d /Applications/Xcode.app/Contents/Developer ]]; then
+    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
+fi
+
+swift build --product AirRaidAlert
+exec .build/debug/AirRaidAlert "$@"
```

### `Sources/AirRaidAlert/CityMap.swift`

```diff
diff --git a/Sources/AirRaidAlert/CityMap.swift b/Sources/AirRaidAlert/CityMap.swift
new file mode 100644
index 00000000..436ebe81
--- /dev/null
+++ b/Sources/AirRaidAlert/CityMap.swift
@@ -0,0 +1,200 @@
+import Foundation
+
+enum TerrainTile: UInt8 {
+    case soil, vegetation, water, road, roof, roofAlt, roofDark, yard
+}
+
+struct RoadNode {
+    let position: CGPoint
+    let neighbors: [Int]
+}
+
+struct CityMap {
+    static let width = 96
+    static let height = 54
+
+    let tiles: [TerrainTile]
+    let roads: [RoadNode]
+    let shelters: [Int]
+
+    static func make(seed: UInt64) -> CityMap {
+        var generator = CityMapGenerator(seed: seed)
+        return generator.build()
+    }
+}
+
+private struct CityMapGenerator {
+    private let width = CityMap.width
+    private let height = CityMap.height
+    private let columns = 6
+    private let rows = 5
+    private var randomState: UInt64
+    private var tiles = Array(repeating: TerrainTile.soil, count: CityMap.width * CityMap.height)
+    private var nodes: [CGPoint] = []
+    private var neighbors: [[Int]] = []
+
+    init(seed: UInt64) {
+        randomState = seed
+    }
+
+    mutating func build() -> CityMap {
+        layTerrain()
+        layRoads()
+        layBuildings()
+        let shelters = [7, 10, 14, 19, 22]
+        return CityMap(
+            tiles: tiles,
+            roads: nodes.indices.map { RoadNode(position: nodes[$0], neighbors: neighbors[$0]) },
+            shelters: shelters
+        )
+    }
+
+    private mutating func layTerrain() {
+        let coast = random(8)
+        let bend = random(15) - 7
+        for y in 0..<height {
+            for x in 0..<width {
+                // 低频地表斑块和不同的河岸走向让城市之间能从远处辨认。
+                let patch = sin(Double(x + bend) * 0.14) + cos(Double(y - bend) * 0.23)
+                let river = 18 + 8 * sin(Double(y + bend) * 0.09)
+                let shore = 6 + 4 * cos(Double(x + bend) * 0.10)
+                let onWater: Bool
+                switch coast {
+                case 0: onWater = Double(x) < river * 0.58
+                case 1: onWater = abs(Double(x) - river) < 2.6
+                case 2: onWater = Double(y) > Double(height) - shore
+                case 3: onWater = Double(x) > Double(width) - river * 0.54
+                case 4: onWater = abs(Double(y) - shore - 2) < 1.8
+                default: onWater = false
+                }
+                if onWater {
+                    set(.water, x: x, y: y)
+                } else if patch > 0.55 && random(9) > 1 || random(31) == 0 {
+                    set(.vegetation, x: x, y: y)
+                }
+            }
+        }
+    }
+
+    private mutating func layRoads() {
+        let avenueRow = 1 + random(rows - 2)
+        let left = 8 + random(8)
+        let top = 6 + random(4)
+        let xSpacing = 13 + random(2)
+        let ySpacing = 8 + random(2)
+        for row in 0..<rows {
+            let shift = random(9) - 4
+            for column in 0..<columns {
+                let x = left + column * xSpacing + shift + random(7) - 3
+                let y = top + row * ySpacing + random(7) - 3
+                nodes.append(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
+                neighbors.append([])
+            }
+        }
+        for row in 0..<rows {
+            for column in 0..<(columns - 1) {
+                // 中部主路贯通一城，次路随街廓错位。
+                let index = row * columns + column
+                connect(index, index + 1, wide: row == avenueRow)
+            }
+            guard row + 1 < rows else { continue }
+            let connectingColumn = 1 + random(columns - 2)
+            for column in 0..<columns where column == connectingColumn || random(5) < 2 {
+                let index = row * columns + column
+                connect(index, index + columns, wide: column == connectingColumn)
+            }
+        }
+    }
+
+    private mutating func connect(_ first: Int, _ second: Int, wide: Bool) {
+        neighbors[first].append(second)
+        neighbors[second].append(first)
+        let start = nodes[first]
+        let end = nodes[second]
+        let steps = Int(max(abs(end.x - start.x), abs(end.y - start.y)) * 2)
+        for step in 0...steps {
+            let progress = CGFloat(step) / CGFloat(max(steps, 1))
+            let x = Int(start.x + (end.x - start.x) * progress)
+            let y = Int(start.y + (end.y - start.y) * progress)
+            set(.road, x: x, y: y)
+            if wide {
+                if abs(end.x - start.x) >= abs(end.y - start.y) {
+                    set(.road, x: x, y: y + 1)
+                } else {
+                    set(.road, x: x + 1, y: y)
+                }
+            }
+        }
+    }
+
+    private mutating func layBuildings() {
+        let density = 4 + random(5)
+        let roofBias = random(3)
+        for first in nodes.indices {
+            for second in neighbors[first] where second > first {
+                let start = nodes[first]
+                let end = nodes[second]
+                let dx = end.x - start.x
+                let dy = end.y - start.y
+                let length = hypot(dx, dy)
+                let lots = max(1, Int(length / 4))
+                for side in [-1.0, 1.0] {
+                    for lot in 0..<lots where random(10) < density {
+                        // 沿路两侧生长建筑组，坐标始终落在同一组地图像素上。
+                        let progress = (CGFloat(lot) + 0.5) / CGFloat(lots)
+                        let setback = CGFloat(side) * CGFloat(2 + random(3))
+                        let x = Int(start.x + dx * progress - dy * setback / length)
+                        let y = Int(start.y + dy * progress + dx * setback / length)
+                        let horizontal = abs(dx) >= abs(dy)
+                        let broad = 2 + random(5)
+                        let narrow = 1 + random(3)
+                        let tile = [TerrainTile.roof, .roofAlt, .roofDark][(random(3) + roofBias) % 3]
+                        placeLot(tile, x: x, y: y, width: horizontal ? broad : narrow, height: horizontal ? narrow : broad)
+                    }
+                }
+            }
+        }
+
+        for _ in 0..<(18 + density * 3) {
+            let x = 7 + random(width - 14)
+            let y = 6 + random(height - 12)
+            let nearTown = nodes.contains { abs($0.x - CGFloat(x)) + abs($0.y - CGFloat(y)) < 10 }
+            guard nearTown else { continue }
+            let tile: TerrainTile = random(3) == 0 ? .yard : .roofDark
+            let w = 2 + random(6)
+            let h = 2 + random(5)
+            placeLot(tile, x: x, y: y, width: w, height: h)
+        }
+    }
+
+    private mutating func placeLot(_ tile: TerrainTile, x: Int, y: Int, width w: Int, height h: Int) {
+        let left = x - w / 2
+        let top = y - h / 2
+        guard left >= 1, top >= 1, left + w < width, top + h < height else { return }
+        for row in top..<(top + h) {
+            for column in left..<(left + w) {
+                let current = tiles[row * width + column]
+                guard current == .soil || current == .vegetation else { return }
+            }
+        }
+        for row in top..<(top + h) {
+            for column in left..<(left + w) {
+                let accent = tile != .yard && w >= 5 && row == top && random(5) > 1
+                set(accent ? .roofDark : tile, x: column, y: row)
+            }
+        }
+    }
+
+    private mutating func set(_ tile: TerrainTile, x: Int, y: Int) {
+        guard (0..<width).contains(x), (0..<height).contains(y) else { return }
+        tiles[y * width + x] = tile
+    }
+
+    private mutating func random(_ upperBound: Int) -> Int {
+        randomState &+= 0x9e3779b97f4a7c15
+        var value = randomState
+        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
+        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
+        return Int((value ^ (value >> 31)) % UInt64(upperBound))
+    }
+}
```

### `Sources/AirRaidAlert/Simulation.swift`

```diff
diff --git a/Sources/AirRaidAlert/Simulation.swift b/Sources/AirRaidAlert/Simulation.swift
new file mode 100644
index 00000000..462306c6
--- /dev/null
+++ b/Sources/AirRaidAlert/Simulation.swift
@@ -0,0 +1,371 @@
+import Foundation
+
+enum WarningPhase: Equatable {
+    case yellow
+    case orange
+    case red
+}
+
+enum ResidentStatus: Equatable {
+    case roaming
+    case evacuating
+    case sheltered
+    case lost
+}
+
+struct Resident {
+    fileprivate(set) var position: CGPoint
+    fileprivate(set) var status = ResidentStatus.roaming
+    fileprivate let walkingSpeed: Double
+    fileprivate let evacuationSpeed: Double
+    fileprivate let exposureRisk: Double
+    fileprivate var fromNode: Int
+    fileprivate var toNode: Int
+    fileprivate var edgeLength: Double
+    fileprivate var distanceAlongEdge: Double
+}
+
+struct CityState {
+    let id: Int
+    let map: CityMap
+    fileprivate(set) var residents: [Resident]
+    fileprivate(set) var warning: WarningPhase?
+    fileprivate(set) var notified = false
+    fileprivate(set) var impactAge: Double?
+    fileprivate(set) var damage = 0
+    fileprivate let shelterRoutes: [ShelterRoute]
+}
+
+// 从所有防空洞反向搜索，市民只需查表即可在道路上选择最近的避难路径。
+fileprivate struct ShelterRoute {
+    var distance = Double.infinity
+    var next: Int?
+}
+
+final class Simulation {
+    private enum EventKind {
+        case warning(WarningPhase)
+        case impact
+    }
+
+    private struct AlertEvent {
+        let time: TimeInterval
+        let cityIndex: Int
+        let kind: EventKind
+    }
+
+    private static let cityCount = 16
+    private static let residentsPerCity = 125
+    private static let impactEffectDuration: TimeInterval = 2.4
+    private static let exposedLossChance = 0.42
+    private static let maximumMovementStep: TimeInterval = 1.0 / 30
+
+    let duration: TimeInterval = 100
+    private(set) var elapsed: TimeInterval = 0
+    private(set) var isPaused = false
+    private(set) var cities: [CityState]
+
+    private let startingCities: [CityState]
+    private let startingRandom: SimulationRandom
+    private let events: [AlertEvent]
+    private var nextEventIndex = 0
+    private var random: SimulationRandom
+
+    var remaining: TimeInterval { duration - elapsed }
+    var isFinished: Bool { elapsed >= duration }
+    var population: Int { Self.cityCount * Self.residentsPerCity }
+    var alive: Int { population - residentCount(in: .lost) }
+    var sheltered: Int { residentCount(in: .sheltered) }
+
+    init(seed: UInt64 = 0x4152_4149_4C45_5254) {
+        var random = SimulationRandom(state: seed)
+        let cities = (1...Self.cityCount).map { id in
+            let map = CityMap.make(seed: random.next())
+            let residents = (0..<Self.residentsPerCity).map { _ in
+                Self.makeResident(on: map.roads, random: &random)
+            }
+            return CityState(
+                id: id,
+                map: map,
+                residents: residents,
+                shelterRoutes: Self.findShelterRoutes(in: map)
+            )
+        }
+        events = Self.makeAlertEvents(random: &random)
+        startingCities = cities
+        startingRandom = random
+        self.cities = cities
+        self.random = random
+    }
+
+    func advance(by interval: TimeInterval) {
+        guard !isPaused, !isFinished, interval.isFinite, interval > 0 else { return }
+        let endTime = min(duration, elapsed + interval)
+
+        // 即使后台一次补算数秒，也精确停在每个预警和受击时刻。
+        while elapsed < endTime {
+            let eventTime = nextEventIndex < events.count ? events[nextEventIndex].time : duration
+            let nextTime = min(endTime, elapsed + Self.maximumMovementStep, eventTime)
+            moveResidents(by: nextTime - elapsed)
+            elapsed = nextTime
+            applyDueEvents()
+        }
+    }
+
+    @discardableResult
+    func notify(cityID: Int) -> Bool {
+        guard !isPaused, !isFinished, (1...Self.cityCount).contains(cityID) else { return false }
+        let cityIndex = cityID - 1
+        guard cities[cityIndex].warning != nil, !cities[cityIndex].notified else { return false }
+        cities[cityIndex].notified = true
+        Self.beginEvacuation(in: &cities[cityIndex])
+        return true
+    }
+
+    func togglePause() {
+        guard !isFinished else { return }
+        isPaused.toggle()
+    }
+
+    func reset() {
+        elapsed = 0
+        isPaused = false
+        cities = startingCities
+        random = startingRandom
+        nextEventIndex = 0
+    }
+
+    private func residentCount(in status: ResidentStatus) -> Int {
+        var count = 0
+        for city in cities {
+            for resident in city.residents where resident.status == status {
+                count += 1
+            }
+        }
+        return count
+    }
+
+    private static func makeAlertEvents(random: inout SimulationRandom) -> [AlertEvent] {
+        let openingCities = [3, 6, 9, 12, 15]
+        let otherCities = (1...cityCount).filter { !openingCities.contains($0) }
+        let order = openingCities + otherCities.shuffled(using: &random)
+        let startTimes: [TimeInterval] = [2, 4.5, 8, 10, 14, 20, 25, 31, 35, 43, 49, 54, 63, 67, 77, 89]
+        var events: [AlertEvent] = []
+        for (id, start) in zip(order, startTimes) {
+            let cityIndex = id - 1
+            events.append(AlertEvent(time: start, cityIndex: cityIndex, kind: .warning(.yellow)))
+            events.append(AlertEvent(time: start + 2, cityIndex: cityIndex, kind: .warning(.orange)))
+            events.append(AlertEvent(time: start + 4, cityIndex: cityIndex, kind: .warning(.red)))
+            events.append(AlertEvent(time: start + 6, cityIndex: cityIndex, kind: .impact))
+        }
+        events.sort { first, second in
+            if first.time == second.time {
+                return first.cityIndex < second.cityIndex
+            }
+            return first.time < second.time
+        }
+        return events
+    }
+
+    private func applyDueEvents() {
+        while nextEventIndex < events.count, events[nextEventIndex].time <= elapsed {
+            let event = events[nextEventIndex]
+            nextEventIndex += 1
+            switch event.kind {
+            case .warning(let phase):
+                cities[event.cityIndex].warning = phase
+            case .impact:
+                Self.applyImpact(to: &cities[event.cityIndex])
+            }
+        }
+    }
+
+    private static func applyImpact(to city: inout CityState) {
+        city.warning = nil
+        city.damage = 1 + city.id % 4
+        city.impactAge = 0
+        // 受击时只统计尚暴露在外的居民，已避难者始终安全。
+        for index in city.residents.indices {
+            let status = city.residents[index].status
+            guard status == .roaming || status == .evacuating else { continue }
+            if city.residents[index].exposureRisk < exposedLossChance {
+                city.residents[index].status = .lost
+            }
+        }
+    }
+
+    private func moveResidents(by interval: TimeInterval) {
+        guard interval > 0 else { return }
+        for index in cities.indices {
+            Self.moveResidents(in: &cities[index], by: interval, random: &random)
+        }
+    }
+
+    private static func moveResidents(
+        in city: inout CityState,
+        by interval: TimeInterval,
+        random: inout SimulationRandom
+    ) {
+        if let age = city.impactAge {
+            let nextAge = age + interval
+            city.impactAge = nextAge < impactEffectDuration ? nextAge : nil
+        }
+        let roads = city.map.roads
+        let routes = city.shelterRoutes
+        for index in city.residents.indices {
+            move(&city.residents[index], along: roads, routes: routes, by: interval, random: &random)
+        }
+    }
+
+    private static func makeResident(on roads: [RoadNode], random: inout SimulationRandom) -> Resident {
+        let start = Int.random(in: roads.indices, using: &random)
+        let end = roads[start].neighbors.randomElement(using: &random) ?? start
+        let length = edgeDistance(from: start, to: end, on: roads)
+        let fraction = random.fraction()
+        // 部分较远的住民需要完整预警窗口，橙色或红色阶段才通知会缩短可达距离。
+        return Resident(
+            position: position(from: start, to: end, fraction: fraction, on: roads),
+            walkingSpeed: 2.4 + 2.6 * random.fraction(),
+            evacuationSpeed: 6.8 + 2.9 * random.fraction(),
+            exposureRisk: random.fraction(),
+            fromNode: start,
+            toNode: end,
+            edgeLength: length,
+            distanceAlongEdge: fraction * length
+        )
+    }
+
+    private static func beginEvacuation(in city: inout CityState) {
+        let routes = city.shelterRoutes
+        for index in city.residents.indices where city.residents[index].status == .roaming {
+            city.residents[index].status = .evacuating
+            let resident = city.residents[index]
+            let backwardDistance = resident.distanceAlongEdge + routes[resident.fromNode].distance
+            let forwardDistance =
+                resident.edgeLength - resident.distanceAlongEdge + routes[resident.toNode].distance
+            if backwardDistance < forwardDistance {
+                city.residents[index].fromNode = resident.toNode
+                city.residents[index].toNode = resident.fromNode
+                city.residents[index].distanceAlongEdge = resident.edgeLength - resident.distanceAlongEdge
+            }
+        }
+    }
+
+    private static func move(
+        _ resident: inout Resident,
+        along roads: [RoadNode],
+        routes: [ShelterRoute],
+        by interval: TimeInterval,
+        random: inout SimulationRandom
+    ) {
+        let speed: Double
+        switch resident.status {
+        case .roaming: speed = resident.walkingSpeed
+        case .evacuating: speed = resident.evacuationSpeed
+        case .sheltered, .lost: return
+        }
+        var movement = speed * interval
+        while movement > 0 {
+            let roomOnEdge = resident.edgeLength - resident.distanceAlongEdge
+            if movement < roomOnEdge {
+                resident.distanceAlongEdge += movement
+                resident.position = position(
+                    from: resident.fromNode,
+                    to: resident.toNode,
+                    fraction: resident.distanceAlongEdge / resident.edgeLength,
+                    on: roads
+                )
+                return
+            }
+            movement -= roomOnEdge
+            let node = resident.toNode
+            resident.position = roads[node].position
+            let nextNode: Int?
+            if resident.status == .evacuating {
+                if routes[node].distance == 0 {
+                    resident.status = .sheltered
+                    return
+                }
+                nextNode = routes[node].next
+            } else {
+                nextNode = roamingDestination(from: node, previous: resident.fromNode, roads: roads, random: &random)
+            }
+            guard let nextNode else { return }
+            let edgeLength = edgeDistance(from: node, to: nextNode, on: roads)
+            guard edgeLength > 0 else { return }
+            resident.fromNode = node
+            resident.toNode = nextNode
+            resident.edgeLength = edgeLength
+            resident.distanceAlongEdge = 0
+        }
+    }
+
+    private static func roamingDestination(
+        from node: Int,
+        previous: Int,
+        roads: [RoadNode],
+        random: inout SimulationRandom
+    ) -> Int? {
+        let neighbors = roads[node].neighbors
+        guard neighbors.count > 1 else { return neighbors.first }
+        let onward = neighbors.filter { $0 != previous }
+        return onward.randomElement(using: &random)
+    }
+
+    private static func findShelterRoutes(in map: CityMap) -> [ShelterRoute] {
+        let roads = map.roads
+        var routes = Array(repeating: ShelterRoute(), count: roads.count)
+        var settled = Array(repeating: false, count: roads.count)
+        for shelter in map.shelters {
+            routes[shelter].distance = 0
+        }
+        for _ in roads {
+            var nearest: Int?
+            var bestDistance = Double.infinity
+            for index in roads.indices where !settled[index] && routes[index].distance < bestDistance {
+                nearest = index
+                bestDistance = routes[index].distance
+            }
+            guard let node = nearest else { break }
+            settled[node] = true
+            for neighbor in roads[node].neighbors where !settled[neighbor] {
+                let candidate = bestDistance + edgeDistance(from: node, to: neighbor, on: roads)
+                if candidate < routes[neighbor].distance {
+                    routes[neighbor] = ShelterRoute(distance: candidate, next: node)
+                }
+            }
+        }
+        return routes
+    }
+
+    private static func edgeDistance(from start: Int, to end: Int, on roads: [RoadNode]) -> Double {
+        let origin = roads[start].position
+        let destination = roads[end].position
+        return hypot(Double(destination.x - origin.x), Double(destination.y - origin.y))
+    }
+
+    private static func position(from start: Int, to end: Int, fraction: Double, on roads: [RoadNode]) -> CGPoint {
+        let origin = roads[start].position
+        let destination = roads[end].position
+        return CGPoint(
+            x: origin.x + (destination.x - origin.x) * fraction,
+            y: origin.y + (destination.y - origin.y) * fraction
+        )
+    }
+}
+
+private struct SimulationRandom: RandomNumberGenerator {
+    var state: UInt64
+
+    mutating func next() -> UInt64 {
+        state &+= 0x9E37_79B9_7F4A_7C15
+        var value = state
+        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
+        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
+        return value ^ (value >> 31)
+    }
+
+    mutating func fraction() -> Double {
+        Double(next() >> 11) / 9_007_199_254_740_992
+    }
+}
```

### `Sources/AirRaidAlert/GameView.swift`

```diff
diff --git a/Sources/AirRaidAlert/GameView.swift b/Sources/AirRaidAlert/GameView.swift
new file mode 100644
index 00000000..83f266e7
--- /dev/null
+++ b/Sources/AirRaidAlert/GameView.swift
@@ -0,0 +1,399 @@
+import AppKit
+
+/// 主屏幕绘制俯视城市与战况，实体 Touch Bar 处理防空通知。
+final class GameView: NSView {
+    var onTogglePause: (() -> Void)?
+    var onRestart: (() -> Void)?
+
+    private let simulation: Simulation
+    private var cityArtwork: [Int: CityArtwork] = [:]
+    private let actionButton = NSButton(title: "暂停", target: nil, action: nil)
+
+    private let background = NSColor(srgbRed: 0.055, green: 0.083, blue: 0.094, alpha: 1)
+    private let headerBackground = NSColor(srgbRed: 0.076, green: 0.107, blue: 0.118, alpha: 1)
+    private let secondaryInk = NSColor(srgbRed: 0.58, green: 0.67, blue: 0.66, alpha: 1)
+    private let paperInk = NSColor(srgbRed: 0.91, green: 0.93, blue: 0.87, alpha: 1)
+    private let shelterInk = NSColor(srgbRed: 0.43, green: 0.88, blue: 0.74, alpha: 1)
+
+    override var isFlipped: Bool { true }
+    override var isOpaque: Bool { true }
+    override var acceptsFirstResponder: Bool { true }
+
+    init(simulation: Simulation) {
+        self.simulation = simulation
+        super.init(frame: .zero)
+        actionButton.target = self
+        actionButton.action = #selector(activateActionButton)
+        actionButton.bezelStyle = .rounded
+        actionButton.focusRingType = .default
+        actionButton.font = Self.chineseFont(12, semibold: true)
+        addSubview(actionButton)
+    }
+
+    required init?(coder: NSCoder) {
+        return nil
+    }
+
+    override func layout() {
+        super.layout()
+        let guide = ScreenLayout(bounds: bounds)
+        actionButton.frame = guide.action
+    }
+
+    override func draw(_ dirtyRect: NSRect) {
+        guard let context = NSGraphicsContext.current?.cgContext else { return }
+        let guide = ScreenLayout(bounds: bounds)
+        paint(bounds, color: background, in: context)
+        drawHeader(guide: guide, in: context)
+        for (index, city) in simulation.cities.enumerated() {
+            draw(city: city, in: guide.cityRect(at: index), context: context)
+        }
+        if simulation.isFinished {
+            drawResultCard(in: context)
+        }
+    }
+
+    @objc private func activateActionButton() {
+        if simulation.isFinished {
+            onRestart?()
+        } else {
+            onTogglePause?()
+        }
+    }
+
+    private func drawHeader(guide: ScreenLayout, in context: CGContext) {
+        paint(guide.header, color: headerBackground, in: context)
+        paint(
+            CGRect(x: 0, y: guide.header.maxY - 1, width: bounds.width, height: 1),
+            color: NSColor(srgbRed: 0.18, green: 0.24, blue: 0.25, alpha: 1),
+            in: context
+        )
+        let startX = guide.headerInset
+        paint(CGRect(x: startX, y: 18, width: 3, height: 29), color: shelterInk, in: context)
+        drawText(
+            "躲避空袭", at: CGPoint(x: startX + 14, y: 16),
+            font: Self.chineseFont(24, semibold: true), color: paperInk
+        )
+
+        let seconds = Int(ceil(simulation.remaining))
+        let metrics: [(String, String, NSColor)] = [
+            ("剩余时间", String(format: "%02d:%02d", seconds / 60, seconds % 60), paperInk),
+            ("城市总人口", String(simulation.population), paperInk),
+            ("当前存活人数", String(simulation.alive), paperInk),
+            ("已安全避难人数", String(simulation.sheltered), shelterInk)
+        ]
+        for (index, metric) in metrics.enumerated() {
+            let x = guide.metricsStart + CGFloat(index) * guide.metricWidth
+            paint(
+                CGRect(x: x - 13, y: 17, width: 1, height: 33),
+                color: secondaryInk.withAlphaComponent(0.21), in: context
+            )
+            drawText(metric.0, at: CGPoint(x: x, y: 10), font: Self.chineseFont(10), color: secondaryInk)
+            drawText(metric.1, at: CGPoint(x: x, y: 24), font: Self.digits(24), color: metric.2)
+        }
+
+        let title = simulation.isFinished ? "重开" : simulation.isPaused ? "继续" : "暂停"
+        if actionButton.title != title {
+            actionButton.title = title
+        }
+    }
+
+    private func draw(city: CityState, in rect: CGRect, context: CGContext) {
+        guard rect.width > 0, rect.height > 0 else { return }
+        let artwork: CityArtwork
+        if let cached = cityArtwork[city.id] {
+            artwork = cached
+        } else {
+            artwork = CityArtwork(map: city.map, cityID: city.id)
+            cityArtwork[city.id] = artwork
+        }
+        let pixel = MapProjection(rect: rect, scale: window?.backingScaleFactor ?? 1)
+        context.saveGState()
+        context.clip(to: rect)
+        paint(rect, color: headerBackground, in: context)
+        if let image = artwork.image {
+            // Core Graphics 的图像坐标从下方起始，翻转后与仿真左上原点一致。
+            context.saveGState()
+            context.translateBy(x: rect.minX, y: rect.maxY)
+            context.scaleBy(x: 1, y: -1)
+            context.interpolationQuality = .none
+            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
+            context.restoreGState()
+        }
+        context.setShouldAntialias(false)
+        drawDamage(city: city, artwork: artwork, pixel: pixel, in: context)
+        drawResidents(city.residents, pixel: pixel, in: context)
+        drawShelters(city, pixel: pixel, in: context)
+        if let phase = city.warning {
+            drawWarning(phase: phase, rect: rect, in: context)
+        }
+        context.restoreGState()
+
+        let labelColor = city.warning.map(warningColor) ?? (city.notified ? shelterInk : paperInk)
+        let labelRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 30, height: 20)
+        paint(labelRect, color: background.withAlphaComponent(0.94), in: context)
+        drawText(
+            String(format: "%02d", city.id), at: CGPoint(x: labelRect.minX + 5, y: labelRect.minY + 1),
+            font: Self.digits(14), color: labelColor
+        )
+    }
+
+    private func drawResidents(_ residents: [Resident], pixel: MapProjection, in context: CGContext) {
+        var ordinaryPoints: [CGRect] = []
+        var evacuationPoints: [CGRect] = []
+        ordinaryPoints.reserveCapacity(residents.count)
+        for resident in residents {
+            switch resident.status {
+            case .roaming:
+                ordinaryPoints.append(pixel.dot(at: resident.position, size: 1.25))
+            case .evacuating:
+                evacuationPoints.append(pixel.dot(at: resident.position, size: 1.8))
+            case .sheltered, .lost:
+                break
+            }
+        }
+        context.setFillColor(NSColor(srgbRed: 0.90, green: 0.87, blue: 0.76, alpha: 0.84).cgColor)
+        context.fill(ordinaryPoints)
+        context.setFillColor(shelterInk.cgColor)
+        context.fill(evacuationPoints)
+    }
+
+    private func drawShelters(_ city: CityState, pixel: MapProjection, in context: CGContext) {
+        let ink = city.notified ? shelterInk : shelterInk.withAlphaComponent(0.56)
+        for index in city.map.shelters {
+            let position = city.map.roads[index].position
+            let plate = pixel.dot(at: position, size: 3.9)
+            paint(plate, color: background, in: context)
+            paint(pixel.dot(at: position, size: 2.1), color: ink, in: context)
+        }
+    }
+
+    private func drawWarning(phase: WarningPhase, rect: CGRect, in context: CGContext) {
+        let ink = warningColor(phase)
+        let thickness: CGFloat = 2
+        let dash: CGFloat = 11
+        let margin: CGFloat = 2
+        let inner = rect.insetBy(dx: margin, dy: margin)
+        var marks: [CGRect] = []
+        // 短实线贴地图边缘，给城市内部的人流保留对比度。
+        for x in stride(from: inner.minX, to: inner.maxX - dash, by: dash * 2.2) {
+            marks.append(CGRect(x: x, y: inner.minY, width: dash, height: thickness))
+            marks.append(CGRect(x: x, y: inner.maxY - thickness, width: dash, height: thickness))
+        }
+        for y in stride(from: inner.minY + dash, to: inner.maxY - dash * 1.5, by: dash * 2.2) {
+            marks.append(CGRect(x: inner.minX, y: y, width: thickness, height: dash))
+            marks.append(CGRect(x: inner.maxX - thickness, y: y, width: thickness, height: dash))
+        }
+        context.setFillColor(ink.cgColor)
+        context.fill(marks)
+    }
+
+    private func drawDamage(
+        city: CityState, artwork: CityArtwork, pixel: MapProjection, in context: CGContext
+    ) {
+        guard city.damage > 0, !artwork.impactSites.isEmpty else { return }
+        let ruin = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.14, alpha: 0.92)
+        let fragments = NSColor(srgbRed: 0.40, green: 0.34, blue: 0.30, alpha: 1)
+        for site in artwork.impactSites.prefix(min(artwork.impactSites.count, city.damage * 3)) {
+            paint(pixel.tileRect(at: site, width: 3, height: 2), color: ruin, in: context)
+            paint(pixel.tileRect(at: site, width: 1, height: 1), color: fragments, in: context)
+        }
+        guard let age = city.impactAge, age < 1.55 else { return }
+        let siteIndex = min(artwork.impactSites.count - 1, max(0, (city.damage - 1) * 3))
+        let origin = artwork.impactSites[siteIndex]
+        let bright = NSColor(srgbRed: 0.99, green: 0.71, blue: 0.41, alpha: 1)
+        let mist = NSColor(srgbRed: 0.53, green: 0.54, blue: 0.50, alpha: 1)
+        let range = CGFloat(age) * 9
+        if age < 0.23 {
+            let flash = pixel.tileRect(at: origin, width: 3, height: 3)
+            paint(flash, color: bright.withAlphaComponent(CGFloat(1 - age * 2)), in: context)
+        }
+        for shard in 0..<13 {
+            let angle = CGFloat(shard) * 2.4
+            let length = range * (0.38 + CGFloat(shard % 5) * 0.115)
+            let point = CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
+            let color = age < 0.38 ? bright : mist
+            let fade = CGFloat(max(0, 1 - age / 1.55))
+            paint(pixel.tileRect(at: point, width: 1, height: 1), color: color.withAlphaComponent(fade), in: context)
+        }
+    }
+
+    private func drawResultCard(in context: CGContext) {
+        let width: CGFloat = 246
+        let rect = CGRect(x: bounds.midX - width / 2, y: bounds.midY - 51, width: width, height: 102)
+        paint(rect, color: headerBackground.withAlphaComponent(0.98), in: context)
+        paint(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2), color: shelterInk, in: context)
+        let percent = simulation.population > 0 ? 100 * Double(simulation.alive) / Double(simulation.population) : 0
+        drawText(
+            "本轮结束", at: CGPoint(x: rect.minX + 20, y: rect.minY + 16),
+            font: Self.chineseFont(17, semibold: true), color: paperInk
+        )
+        drawText(
+            "存活率", at: CGPoint(x: rect.minX + 20, y: rect.minY + 63),
+            font: Self.chineseFont(12), color: secondaryInk
+        )
+        drawText(
+            String(format: "%.1f%%", percent), at: CGPoint(x: rect.minX + 85, y: rect.minY + 48),
+            font: Self.digits(28), color: shelterInk
+        )
+    }
+
+    private func warningColor(_ phase: WarningPhase) -> NSColor {
+        switch phase {
+        case .yellow: return NSColor(srgbRed: 0.95, green: 0.80, blue: 0.43, alpha: 1)
+        case .orange: return NSColor(srgbRed: 0.96, green: 0.58, blue: 0.33, alpha: 1)
+        case .red: return NSColor(srgbRed: 0.94, green: 0.42, blue: 0.41, alpha: 1)
+        }
+    }
+
+    private func paint(_ rect: CGRect, color: NSColor, in context: CGContext) {
+        context.setFillColor(color.cgColor)
+        context.fill(rect)
+    }
+
+    private func drawText(_ text: String, at origin: CGPoint, font: NSFont, color: NSColor) {
+        (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
+    }
+
+    private static func chineseFont(_ size: CGFloat, semibold: Bool = false) -> NSFont {
+        let name = semibold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
+        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
+    }
+
+    private static func digits(_ size: CGFloat) -> NSFont {
+        NSFont(name: "Menlo-Bold", size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .bold)
+    }
+}
+
+private struct ScreenLayout {
+    let header: CGRect
+    let headerInset: CGFloat
+    let metricsStart: CGFloat
+    let metricWidth: CGFloat
+    let action: CGRect
+    private let citySize: CGSize
+    private let cityOrigin: CGPoint
+    private let gap: CGFloat = 7
+
+    init(bounds: CGRect) {
+        let headerHeight: CGFloat = 64
+        let margin: CGFloat = 18
+        let cityAspect = CGFloat(CityMap.width) / CGFloat(CityMap.height)
+        let widthLimit = (bounds.width - margin * 2 - gap * 3) / 4
+        let heightLimit = (bounds.height - headerHeight - margin * 2 - gap * 3) / 4
+        let cityHeight = max(0, floor(min(widthLimit / cityAspect, heightLimit)))
+        let cityWidth = floor(cityHeight * cityAspect)
+        let mapWidth = cityWidth * 4 + gap * 3
+        let mapHeight = cityHeight * 4 + gap * 3
+
+        header = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
+        headerInset = max(margin, min(47, floor((bounds.width - mapWidth) / 2)))
+        metricsStart = headerInset + 170
+        action = CGRect(x: bounds.maxX - headerInset - 65, y: 20, width: 65, height: 25)
+        metricWidth = max(87, (action.minX - metricsStart - 13) / 4)
+        citySize = CGSize(width: cityWidth, height: cityHeight)
+        cityOrigin = CGPoint(
+            x: floor((bounds.width - mapWidth) / 2),
+            y: floor(headerHeight + (bounds.height - headerHeight - mapHeight) / 2)
+        )
+    }
+
+    func cityRect(at index: Int) -> CGRect {
+        CGRect(
+            x: cityOrigin.x + CGFloat(index % 4) * (citySize.width + gap),
+            y: cityOrigin.y + CGFloat(index / 4) * (citySize.height + gap),
+            width: citySize.width, height: citySize.height
+        )
+    }
+}
+
+private struct MapProjection {
+    let rect: CGRect
+    let scale: CGFloat
+
+    private var stepX: CGFloat { rect.width / CGFloat(CityMap.width) }
+    private var stepY: CGFloat { rect.height / CGFloat(CityMap.height) }
+
+    func dot(at point: CGPoint, size: CGFloat) -> CGRect {
+        let extent = max(1, (size * scale).rounded()) / scale
+        let x = rect.minX + point.x * stepX - extent / 2
+        let y = rect.minY + point.y * stepY - extent / 2
+        return CGRect(x: snap(x), y: snap(y), width: extent, height: extent)
+    }
+
+    func tileRect(at point: CGPoint, width: CGFloat, height: CGFloat) -> CGRect {
+        CGRect(
+            x: snap(rect.minX + point.x.rounded(.down) * stepX),
+            y: snap(rect.minY + point.y.rounded(.down) * stepY),
+            width: snap(width * stepX), height: snap(height * stepY)
+        )
+    }
+
+    private func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
+}
+
+private struct CityArtwork {
+    let image: CGImage?
+    let impactSites: [CGPoint]
+
+    init(map: CityMap, cityID: Int) {
+        var rasters: [UInt8] = []
+        rasters.reserveCapacity(map.tiles.count * 4)
+        var roofCenters: [CGPoint] = []
+        for (index, tile) in map.tiles.enumerated() {
+            let x = index % CityMap.width
+            let y = index / CityMap.width
+            let hasRoofToLeft = x > 0 && map.tiles[index - 1].isRoof
+            let hasRoofAbove = y > 0 && map.tiles[index - CityMap.width].isRoof
+            let swatch = Self.color(for: tile)
+            // 边界保留硬边，连续色块采用轻微变化表现地表材质。
+            let noise = (x * 13 + y * 23 + x * y * 7 + cityID * 3) % 9 - 4
+            let edge = tile.isRoof && (!hasRoofToLeft || !hasRoofAbove) ? -8 : 0
+            let shade = tile.isRoof ? edge + noise / 3 : noise
+            rasters.append(UInt8(clamping: swatch.0 + shade))
+            rasters.append(UInt8(clamping: swatch.1 + shade))
+            rasters.append(UInt8(clamping: swatch.2 + shade))
+            rasters.append(255)
+            if tile.isRoof && hasRoofAbove && hasRoofToLeft {
+                roofCenters.append(CGPoint(x: x, y: y))
+            }
+        }
+        let stride = max(1, roofCenters.count / 11)
+        impactSites = roofCenters.enumerated().compactMap { index, point in
+            (index + cityID * 3) % stride == 0 ? point : nil
+        }
+        if let provider = CGDataProvider(data: Data(rasters) as CFData) {
+            image = CGImage(
+                width: CityMap.width, height: CityMap.height, bitsPerComponent: 8,
+                bitsPerPixel: 32, bytesPerRow: CityMap.width * 4,
+                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
+                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
+                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
+            )
+        } else {
+            image = nil
+        }
+    }
+
+    private static func color(for tile: TerrainTile) -> (Int, Int, Int) {
+        switch tile {
+        case .soil: return (45, 58, 57)
+        case .vegetation: return (35, 64, 55)
+        case .water: return (24, 53, 63)
+        case .road: return (61, 74, 75)
+        case .roof: return (126, 125, 106)
+        case .roofAlt: return (117, 95, 79)
+        case .roofDark: return (87, 98, 94)
+        case .yard: return (77, 80, 67)
+        }
+    }
+}
+
+private extension TerrainTile {
+    var isRoof: Bool {
+        switch self {
+        case .roof, .roofAlt, .roofDark: return true
+        default: return false
+        }
+    }
+}
```

### `Sources/AirRaidAlert/TouchBarController.swift`

```diff
diff --git a/Sources/AirRaidAlert/TouchBarController.swift b/Sources/AirRaidAlert/TouchBarController.swift
new file mode 100644
index 00000000..917aa1fc
--- /dev/null
+++ b/Sources/AirRaidAlert/TouchBarController.swift
@@ -0,0 +1,156 @@
+import AppKit
+
+final class TouchBarController: NSObject {
+    private let onNotify: (Int) -> Void
+    private let buttons = (1...16).map { CityTouchButton(cityID: $0) }
+
+    // 把 16 个键放进同一个原生项目，触控条缩窄时一起压缩，避免只隐藏部分编号。
+    private lazy var bar: NSTouchBar = {
+        let identifier = NSTouchBarItem.Identifier("com.airraidalert.touchbar.cities")
+        let citiesItem = NSCustomTouchBarItem(identifier: identifier)
+        citiesItem.visibilityPriority = .high
+        citiesItem.view = makeCityRow()
+
+        let touchBar = NSTouchBar()
+        touchBar.templateItems = [citiesItem]
+        touchBar.defaultItemIdentifiers = [identifier]
+        return touchBar
+    }()
+
+    init(onNotify: @escaping (Int) -> Void) {
+        self.onNotify = onNotify
+        super.init()
+        for button in buttons {
+            button.target = self
+            button.action = #selector(notify(_:))
+        }
+    }
+
+    func makeBar() -> NSTouchBar {
+        bar
+    }
+
+    func update(cities: [CityState], inputEnabled: Bool = true) {
+        for city in cities {
+            let index = city.id - 1
+            guard buttons.indices.contains(index) else { continue }
+            let state = CityTouchButton.VisualState(city: city)
+            buttons[index].update(state: state, enabled: inputEnabled && state.canNotify)
+        }
+    }
+
+    private func makeCityRow() -> NSStackView {
+        let row = NSStackView(views: buttons)
+        row.orientation = .horizontal
+        row.userInterfaceLayoutDirection = .leftToRight
+        row.alignment = .centerY
+        row.distribution = .fillEqually
+        row.spacing = 3
+        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
+        for (index, button) in buttons.enumerated() {
+            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
+            // 每组对应主画面的一行，略宽的间隔帮助定位。
+            if (index + 1).isMultiple(of: 4), index < buttons.count - 1 {
+                row.setCustomSpacing(6, after: button)
+            }
+        }
+        return row
+    }
+
+    @objc private func notify(_ sender: CityTouchButton) {
+        guard sender.isEnabled else { return }
+        onNotify(sender.cityID)
+    }
+}
+
+private final class CityTouchButton: NSButton {
+    enum VisualState: Equatable {
+        case normal, yellow, orange, red, notified, struck
+
+        init(city: CityState) {
+            guard let warning = city.warning else {
+                self = city.damage > 0 ? .struck : .normal
+                return
+            }
+            if city.notified {
+                self = .notified
+                return
+            }
+            switch warning {
+            case .yellow: self = .yellow
+            case .orange: self = .orange
+            case .red: self = .red
+            }
+        }
+
+        var canNotify: Bool { self == .yellow || self == .orange || self == .red }
+
+        var accessibilityStatus: String {
+            switch self {
+            case .normal: return "暂无预警"
+            case .yellow: return "黄色预警"
+            case .orange: return "橙色预警"
+            case .red: return "红色预警"
+            case .notified: return "已发送疏散通知"
+            case .struck: return "已受击"
+            }
+        }
+
+        var background: NSColor {
+            switch self {
+            case .normal: return NSColor(white: 0.17, alpha: 1)
+            case .yellow: return NSColor(red: 0.96, green: 0.78, blue: 0.33, alpha: 1)
+            case .orange: return NSColor(red: 0.96, green: 0.56, blue: 0.32, alpha: 1)
+            case .red: return NSColor(red: 0.97, green: 0.44, blue: 0.42, alpha: 1)
+            case .notified: return NSColor(red: 0.38, green: 0.78, blue: 0.64, alpha: 1)
+            case .struck: return NSColor(white: 0.11, alpha: 1)
+            }
+        }
+    }
+
+    let cityID: Int
+    private var visualState = VisualState.normal
+
+    init(cityID: Int) {
+        self.cityID = cityID
+        super.init(frame: .zero)
+        title = String(format: "%02d", cityID)
+        font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
+        setButtonType(.momentaryPushIn)
+        isBordered = false
+        isEnabled = false
+        setAccessibilityLabel("城市 \(title)，\(visualState.accessibilityStatus)")
+        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
+    }
+
+    required init?(coder: NSCoder) { nil }
+
+    override var intrinsicContentSize: NSSize { NSSize(width: 35, height: 30) }
+
+    func update(state: VisualState, enabled: Bool) {
+        guard visualState != state || isEnabled != enabled else { return }
+        visualState = state
+        isEnabled = enabled
+        setAccessibilityLabel("城市 \(title)，\(state.accessibilityStatus)")
+        needsDisplay = true
+    }
+
+    override func draw(_ dirtyRect: NSRect) {
+        var fillColor = visualState.background
+        if cell?.isHighlighted == true {
+            fillColor = fillColor.blended(withFraction: 0.25, of: .white) ?? fillColor
+        }
+        fillColor.setFill()
+        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
+
+        let quiet = visualState == .normal || visualState == .struck
+        let attributes: [NSAttributedString.Key: Any] = [
+            .font: font ?? NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
+            .foregroundColor: quiet ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.08, alpha: 1)
+        ]
+        let label = title as NSString
+        let size = label.size(withAttributes: attributes)
+        let center = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
+        label.draw(at: center, withAttributes: attributes)
+    }
+}
```

### `Sources/AirRaidAlert/main.swift`

```diff
diff --git a/Sources/AirRaidAlert/main.swift b/Sources/AirRaidAlert/main.swift
new file mode 100644
index 00000000..72b3404c
--- /dev/null
+++ b/Sources/AirRaidAlert/main.swift
@@ -0,0 +1,146 @@
+import AppKit
+
+private final class GameWindow: NSWindow {
+    private let controls: TouchBarController
+    private let testInputEnabled: Bool
+    var onTestKey: ((UInt16) -> Bool)?
+
+    init(view: GameView, controls: TouchBarController, testInputEnabled: Bool) {
+        self.controls = controls
+        self.testInputEnabled = testInputEnabled
+        let display = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
+        let size = NSSize(width: min(1440, display.width - 48), height: min(940, display.height - 52))
+        super.init(
+            contentRect: NSRect(origin: .zero, size: size),
+            styleMask: [.titled, .closable, .miniaturizable, .resizable],
+            backing: .buffered,
+            defer: false
+        )
+        title = "躲避空袭"
+        contentMinSize = NSSize(width: 920, height: 600)
+        contentView = view
+        isReleasedWhenClosed = false
+        appearance = NSAppearance(named: .darkAqua)
+        center()
+    }
+
+    override func makeTouchBar() -> NSTouchBar? {
+        controls.makeBar()
+    }
+
+    override func keyDown(with event: NSEvent) {
+        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
+        if testInputEnabled, modifiers.isEmpty, !event.isARepeat, onTestKey?(event.keyCode) == true {
+            return
+        }
+        super.keyDown(with: event)
+    }
+}
+
+private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
+    private let simulation = Simulation()
+    private var gameView: GameView?
+    private var window: GameWindow?
+    private var touchBar: TouchBarController?
+    private var refreshTimer: Timer?
+    private var lastFrame = ProcessInfo.processInfo.systemUptime
+
+    // 测试键按实体键位映射成四行，方便没有触控条的机器验证通知与疏散。
+    private let testKeyCodes: [UInt16] = [18, 19, 20, 21, 12, 13, 14, 15, 0, 1, 2, 3, 6, 7, 8, 9]
+
+    func applicationDidFinishLaunching(_ notification: Notification) {
+        let view = GameView(simulation: simulation)
+        let touchBar = TouchBarController { [weak self] cityID in
+            self?.notify(cityID: cityID)
+        }
+        let gameWindow = GameWindow(
+            view: view,
+            controls: touchBar,
+            testInputEnabled: CommandLine.arguments.contains("--test-input")
+        )
+        view.onTogglePause = { [weak self] in self?.togglePause() }
+        view.onRestart = { [weak self] in self?.restartRound() }
+        gameWindow.onTestKey = { [weak self] code in self?.handleTestKey(code) ?? false }
+        gameView = view
+        window = gameWindow
+        self.touchBar = touchBar
+
+        setUpMenu()
+        refresh()
+        gameWindow.makeKeyAndOrderFront(nil)
+        NSApp.activate(ignoringOtherApps: true)
+        lastFrame = ProcessInfo.processInfo.systemUptime
+        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.frame() }
+        RunLoop.main.add(timer, forMode: .common)
+        refreshTimer = timer
+    }
+
+    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
+        true
+    }
+
+    func applicationWillTerminate(_ notification: Notification) {
+        refreshTimer?.invalidate()
+    }
+
+    private func setUpMenu() {
+        let mainMenu = NSMenu()
+        let appItem = NSMenuItem()
+        mainMenu.addItem(appItem)
+        let appMenu = NSMenu()
+        appMenu.addItem(withTitle: "退出躲避空袭", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
+        appItem.submenu = appMenu
+        NSApp.mainMenu = mainMenu
+    }
+
+    private func frame() {
+        let now = ProcessInfo.processInfo.systemUptime
+        defer { lastFrame = now }
+        guard !simulation.isPaused, !simulation.isFinished else { return }
+        // 唤醒或窗口短暂卡顿时限制单帧追赶，避免界面上整段预警突然消失。
+        simulation.advance(by: min(now - lastFrame, 0.25))
+        refresh()
+    }
+
+    private func refresh() {
+        gameView?.needsDisplay = true
+        touchBar?.update(cities: simulation.cities, inputEnabled: !simulation.isPaused && !simulation.isFinished)
+    }
+
+    private func notify(cityID: Int) {
+        if simulation.notify(cityID: cityID) {
+            refresh()
+        }
+    }
+
+    private func togglePause() {
+        simulation.togglePause()
+        lastFrame = ProcessInfo.processInfo.systemUptime
+        refresh()
+    }
+
+    private func restartRound() {
+        simulation.reset()
+        lastFrame = ProcessInfo.processInfo.systemUptime
+        refresh()
+    }
+
+    private func handleTestKey(_ code: UInt16) -> Bool {
+        if let index = testKeyCodes.firstIndex(of: code) {
+            notify(cityID: index + 1)
+        } else if code == 49 {
+            togglePause()
+        } else if code == 36, simulation.isFinished {
+            restartRound()
+        } else {
+            return false
+        }
+        return true
+    }
+}
+
+let app = NSApplication.shared
+private let appDelegate = ApplicationDelegate()
+app.setActivationPolicy(.regular)
+app.delegate = appDelegate
+app.run()
```

### `Tests/AirRaidAlertTests/SimulationTests.swift`

```diff
diff --git a/Tests/AirRaidAlertTests/SimulationTests.swift b/Tests/AirRaidAlertTests/SimulationTests.swift
new file mode 100644
index 00000000..cfbe9f77
--- /dev/null
+++ b/Tests/AirRaidAlertTests/SimulationTests.swift
@@ -0,0 +1,101 @@
+import Foundation
+import XCTest
+@testable import AirRaidAlert
+
+final class SimulationTests: XCTestCase {
+    func testSixteenDistinctConnectedCitiesAndPopulation() {
+        let game = Simulation(seed: 42)
+        XCTAssertEqual(game.cities.map(\.id), Array(1...16))
+        XCTAssertEqual(Set(game.cities.map { $0.map.tiles.map(\.rawValue) }).count, 16)
+        XCTAssertEqual(game.population, 2000)
+        XCTAssertEqual(game.alive, 2000)
+        XCTAssertEqual(game.sheltered, 0)
+
+        for city in game.cities {
+            let map = city.map
+            XCTAssertEqual(city.residents.count, 125)
+            XCTAssertEqual(map.tiles.count, CityMap.width * CityMap.height)
+            XCTAssertFalse(map.shelters.isEmpty)
+            var reached: Set<Int> = [0]
+            var pending = [0]
+            while let current = pending.popLast() {
+                let road = map.roads[current]
+                let tile = Int(road.position.y) * CityMap.width + Int(road.position.x)
+                XCTAssertEqual(map.tiles[tile], .road)
+                for next in road.neighbors where reached.insert(next).inserted {
+                    pending.append(next)
+                }
+            }
+            XCTAssertEqual(reached.count, map.roads.count)
+            XCTAssertTrue(map.shelters.allSatisfy(reached.contains))
+        }
+    }
+
+    func testMovingDotsAndTwoSecondAlertPhases() {
+        let game = Simulation(seed: 42)
+        let initial = game.cities[2].residents.map(\.position)
+        game.advance(by: 1)
+        XCTAssertNotEqual(game.cities[2].residents.map(\.position), initial)
+        XCTAssertNil(game.cities[2].warning)
+        game.advance(by: 1.05)
+        XCTAssertEqual(game.cities[2].warning, .yellow)
+        game.advance(by: 2)
+        XCTAssertEqual(game.cities[2].warning, .orange)
+        game.advance(by: 2)
+        XCTAssertEqual(game.cities[2].warning, .red)
+        game.advance(by: 2)
+        XCTAssertNil(game.cities[2].warning)
+        XCTAssertNotNil(game.cities[2].impactAge)
+        XCTAssertGreaterThan(game.cities[2].damage, 0)
+    }
+
+    func testEarlyNotificationSavesMoreResidentsThanNoNotification() {
+        let protected = Simulation(seed: 42)
+        let unprotected = Simulation(seed: 42)
+        protected.advance(by: 2.05)
+        XCTAssertTrue(protected.notify(cityID: 3))
+        XCTAssertFalse(protected.notify(cityID: 3))
+        XCTAssertFalse(protected.notify(cityID: 0))
+        XCTAssertTrue(protected.cities[2].residents.contains { $0.status == .evacuating })
+        protected.advance(by: 6)
+        unprotected.advance(by: 8.05)
+        XCTAssertGreaterThan(protected.sheltered, unprotected.sheltered)
+        XCTAssertGreaterThan(protected.alive, unprotected.alive)
+        XCTAssertEqual(protected.population, unprotected.population)
+    }
+
+    func testLateNotificationLeavesMoreResidentsExposed() {
+        let early = Simulation(seed: 42)
+        let late = Simulation(seed: 42)
+        early.advance(by: 2.05)
+        late.advance(by: 6.05)
+        XCTAssertTrue(early.notify(cityID: 3))
+        XCTAssertTrue(late.notify(cityID: 3))
+        early.advance(by: 6)
+        late.advance(by: 2)
+        XCTAssertGreaterThan(early.sheltered, late.sheltered)
+        XCTAssertGreaterThan(early.alive, late.alive)
+    }
+
+    func testPauseFreezesClockAndRoundCanRestart() {
+        let game = Simulation(seed: 42)
+        game.advance(by: 2.05)
+        let pausedTime = game.elapsed
+        let positions = game.cities[2].residents.map(\.position)
+        game.togglePause()
+        game.advance(by: 3)
+        XCTAssertEqual(game.elapsed, pausedTime)
+        XCTAssertEqual(game.cities[2].residents.map(\.position), positions)
+        XCTAssertFalse(game.notify(cityID: 3))
+        game.togglePause()
+        game.advance(by: 100)
+        XCTAssertTrue(game.isFinished)
+        XCTAssertEqual(game.remaining, 0)
+        game.reset()
+        XCTAssertFalse(game.isFinished)
+        XCTAssertFalse(game.isPaused)
+        XCTAssertEqual(game.remaining, game.duration)
+        XCTAssertEqual(game.alive, 2000)
+        XCTAssertTrue(game.cities.allSatisfy { $0.damage == 0 && $0.warning == nil })
+    }
+}
```
