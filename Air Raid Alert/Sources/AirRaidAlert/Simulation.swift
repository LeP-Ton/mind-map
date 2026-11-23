import Foundation

enum WarningPhase: Equatable {
    case yellow
    case orange
}

enum ResidentStatus: Equatable {
    case roaming
    case evacuating
    case sheltered
    case lost
}

enum PopulationDensity: String {
    case low = "低"
    case medium = "中"
    case high = "高"
}

struct Resident {
    fileprivate(set) var position: CGPoint
    fileprivate(set) var status = ResidentStatus.roaming
    fileprivate let walkingSpeed: Double
    fileprivate let evacuationSpeed: Double
    fileprivate var random: SimulationRandom
    fileprivate var fromNode: Int
    fileprivate var toNode: Int
    fileprivate var edgeLength: Double
    fileprivate var distanceAlongEdge: Double
}

struct CityState {
    let id: Int
    let name: String
    let map: CityMap
    fileprivate(set) var residents: [Resident]
    fileprivate(set) var warning: WarningPhase?
    fileprivate(set) var notified = false
    fileprivate(set) var raid: RaidState?
    fileprivate(set) var completedRaids: [RaidState] = []
    fileprivate(set) var damage = 0
    fileprivate let shelterRoutes: [ShelterRoute]

    var density: PopulationDensity {
        if residents.count >= 190 { return .high }
        if residents.count >= 100 { return .medium }
        return .low
    }

    var livingPopulation: Int {
        residents.lazy.filter { $0.status != .lost }.count
    }
}

struct RaidState {
    static let impactEffectDuration: TimeInterval = 1.45

    let startedAt: TimeInterval
    let aircraft: [RaidAircraft]
    let bombs: [RaidBomb]
}

struct RaidAircraft {
    let heading: CGFloat
    fileprivate let startsAt: TimeInterval
    fileprivate let duration: TimeInterval
    fileprivate let origin: CGPoint
    fileprivate let destination: CGPoint

    func position(at elapsed: TimeInterval) -> CGPoint? {
        let progress = (elapsed - startsAt) / duration
        guard (0...1).contains(progress) else { return nil }
        return position(along: progress)
    }

    fileprivate func position(along progress: Double) -> CGPoint {
        interpolate(from: origin, to: destination, progress: progress)
    }
}

struct RaidBomb {
    let dropTime: TimeInterval
    let impactTime: TimeInterval
    let impactPosition: CGPoint
    let radius: CGFloat
    fileprivate(set) var casualties: Int?
    fileprivate let dropPosition: CGPoint

    func position(at elapsed: TimeInterval) -> CGPoint? {
        guard elapsed >= dropTime, elapsed < impactTime else { return nil }
        let progress = (elapsed - dropTime) / (impactTime - dropTime)
        return interpolate(from: dropPosition, to: impactPosition, progress: progress)
    }
}

private func interpolate(from start: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
    CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
}

// 从所有防空洞反向搜索，市民只需查表即可在道路上选择最近的避难路径。
fileprivate struct ShelterRoute {
    var distance = Double.infinity
    var next: Int?
}

final class Simulation {
    private enum EventKind {
        case warning(WarningPhase)
        case raid(RaidState)
        case impact(bombIndex: Int)
        case allClear
    }

    private struct AlertEvent {
        let time: TimeInterval
        let cityIndex: Int
        let kind: EventKind
    }

    // 顺序对应地图的从左到右、从上到下，也是触控条的排列顺序。
    private static let cityConfigurations: [(name: String, population: Int)] = [
        ("松浦", 150), ("柳溪", 45), ("石桥", 200), ("云津", 120),
        ("枫湾", 190), ("南陵", 55), ("竹塘", 130), ("青川", 100),
        ("白沙", 135), ("榆关", 195), ("杏村", 65), ("临汀", 115),
        ("蒲渡", 140), ("桂岭", 110), ("安泽", 215), ("鹤台", 35)
    ]
    private static let cityCount = cityConfigurations.count
    private static let originalResidentsPerCity = 125
    private static let maximumMovementStep: TimeInterval = 1.0 / 30
    private static let warningPhaseDuration: TimeInterval = 1
    private static let minimumCityWarningGap: TimeInterval = 16

    let duration: TimeInterval = 100
    private(set) var elapsed: TimeInterval = 0
    private(set) var isPaused = false
    private(set) var cities: [CityState]

    private let startingCities: [CityState]
    private let raidSeed: UInt64
    private var orderRandom: SimulationRandom
    private var events: [AlertEvent]
    private var nextEventIndex = 0

    var remaining: TimeInterval { duration - elapsed }
    var isFinished: Bool { elapsed >= duration }
    var population: Int { cities.reduce(0) { $0 + $1.residents.count } }
    var alive: Int { cities.reduce(0) { $0 + $1.livingPopulation } }
    var sheltered: Int { residentCount(in: .sheltered) }

    init(seed: UInt64 = 0x4152_4149_4C45_5254, scheduleSeed: UInt64? = nil) {
        var random = SimulationRandom(state: seed)
        let cities = Self.cityConfigurations.enumerated().map { index, configuration in
            let mapSeed = random.next()
            let map = CityMap.make(seed: mapSeed)
            // 保留原有道路种子和已有居民点，新增人口使用独立的单城随机流。
            let baseline = (0..<Self.originalResidentsPerCity).map { _ in
                Self.makeResident(on: map.roads, random: &random)
            }
            var residents = Array(baseline.prefix(configuration.population))
            var additionalRandom = SimulationRandom(state: mapSeed ^ 0x5245_5349_4445_4E54)
            for _ in residents.count..<configuration.population {
                residents.append(Self.makeResident(on: map.roads, random: &additionalRandom))
            }
            return CityState(
                id: index + 1,
                name: configuration.name,
                map: map,
                residents: residents,
                shelterRoutes: Self.findShelterRoutes(in: map)
            )
        }
        let raidSeed = seed ^ 0x5241_4944_504C_414E
        var orderRandom = SimulationRandom(state: scheduleSeed ?? seed)
        events = Self.makeAlertEvents(orderRandom: &orderRandom, raidSeed: raidSeed)
        self.raidSeed = raidSeed
        self.orderRandom = orderRandom
        startingCities = cities
        self.cities = cities
    }

    func advance(by interval: TimeInterval) {
        guard !isPaused, !isFinished, interval.isFinite, interval > 0 else { return }
        let endTime = min(duration, elapsed + interval)

        // 每枚落弹前先把居民推进到命中时刻，同一份数据也驱动飞行和落地画面。
        while elapsed < endTime {
            let eventTime = nextEventIndex < events.count ? events[nextEventIndex].time : duration
            let nextTime = min(endTime, elapsed + Self.maximumMovementStep, eventTime)
            moveResidents(by: nextTime - elapsed)
            elapsed = nextTime
            applyDueEvents()
        }
    }

    @discardableResult
    func notify(cityID: Int) -> Bool {
        guard !isPaused, !isFinished, (1...Self.cityCount).contains(cityID) else { return false }
        let cityIndex = cityID - 1
        guard cities[cityIndex].warning != nil, !cities[cityIndex].notified else { return false }
        cities[cityIndex].notified = true
        Self.beginEvacuation(in: &cities[cityIndex])
        return true
    }

    func togglePause() {
        guard !isFinished else { return }
        isPaused.toggle()
    }

    func reset() {
        elapsed = 0
        isPaused = false
        cities = startingCities
        events = Self.makeAlertEvents(orderRandom: &orderRandom, raidSeed: raidSeed)
        nextEventIndex = 0
    }

    private func residentCount(in status: ResidentStatus) -> Int {
        var count = 0
        for city in cities {
            for resident in city.residents where resident.status == status {
                count += 1
            }
        }
        return count
    }

    private static func makeAlertEvents(
        orderRandom: inout SimulationRandom,
        raidSeed: UInt64
    ) -> [AlertEvent] {
        // 首轮让玩家建立位置感，后两轮缩短部分间隔，最后一轮集中出现连发预警。
        let startTimes: [[TimeInterval]] = [
            [2, 4.5, 8, 10, 12.4, 14.4, 16.6, 18.4, 20.4, 22.1, 23.7, 25.6, 27, 28.6, 29.7, 31],
            [32.4, 33.7, 35, 36.6, 38, 40.2, 43, 44, 45.2, 46.3, 47.5, 50.2, 52.5, 54, 55.3, 57.1],
            [63.2, 63.48, 63.76, 64.1, 64.44, 64.82, 70.8, 71.55, 72.5, 74.6, 84.45, 84.74, 85.03, 85.39, 85.77, 86.2]
        ]
        let openingCities = [2, 5] // 石桥、南陵
        var raidRandom = SimulationRandom(state: raidSeed)
        var previousStarts = Array(repeating: -TimeInterval.infinity, count: cityCount)
        var events: [AlertEvent] = []
        for (round, times) in startTimes.enumerated() {
            var candidates = (0..<cityCount).shuffled(using: &orderRandom)
            if round == 0 {
                candidates.removeAll { openingCities.contains($0) }
                candidates.insert(contentsOf: openingCities, at: 0)
            }
            for start in times {
                // 越晚的槽可选城市越多，按洗牌顺序取最先满足间隔的一座即可。
                guard let index = candidates.firstIndex(where: { start - previousStarts[$0] >= minimumCityWarningGap }) else {
                    preconditionFailure("每轮时刻必须为所有城市留出解除后的活动间隔")
                }
                let cityIndex = candidates.remove(at: index)
                previousStarts[cityIndex] = start
                appendWave(startingAt: start, in: cityIndex, to: &events, random: &raidRandom)
            }
        }
        events.sort { first, second in
            if first.time != second.time { return first.time < second.time }
            if first.cityIndex != second.cityIndex { return first.cityIndex < second.cityIndex }
            guard case .impact(let firstIndex) = first.kind,
                  case .impact(let secondIndex) = second.kind else { return false }
            return firstIndex < secondIndex
        }
        return events
    }

    private static func appendWave(
        startingAt start: TimeInterval,
        in cityIndex: Int,
        to events: inout [AlertEvent],
        random: inout SimulationRandom
    ) {
        events.append(AlertEvent(time: start, cityIndex: cityIndex, kind: .warning(.yellow)))
        events.append(AlertEvent(time: start + warningPhaseDuration, cityIndex: cityIndex, kind: .warning(.orange)))
        let raid = makeRaid(startingAt: start + warningPhaseDuration * 2, random: &random)
        events.append(AlertEvent(time: raid.startedAt, cityIndex: cityIndex, kind: .raid(raid)))
        for (bombIndex, bomb) in raid.bombs.enumerated() {
            events.append(AlertEvent(time: bomb.impactTime, cityIndex: cityIndex, kind: .impact(bombIndex: bombIndex)))
        }
        let lastImpact = raid.bombs.last?.impactTime ?? raid.startedAt
        let lastAircraftExit = raid.aircraft.map { $0.startsAt + $0.duration }.max() ?? raid.startedAt
        let clearTime = max(lastImpact + RaidState.impactEffectDuration, lastAircraftExit)
        events.append(AlertEvent(time: clearTime, cityIndex: cityIndex, kind: .allClear))
    }

    private static func makeRaid(startingAt startedAt: TimeInterval, random: inout SimulationRandom) -> RaidState {
        let count = Int.random(in: 5...8, using: &random)
        let bombCount = 30
        let leftToRight = Bool.random(using: &random)
        let mapWidth = CGFloat(CityMap.width)
        let mapHeight = CGFloat(CityMap.height)
        let initialX: CGFloat = leftToRight ? -6 : mapWidth + 6
        let endX: CGFloat = leftToRight ? mapWidth + 6 : -6
        var aircraft: [RaidAircraft] = []
        for index in 0..<count {
            let offset = CGFloat(index) / CGFloat(count - 1)
            let centerY = 9 + (mapHeight - 18) * offset
            let initialY = centerY + CGFloat(random.fraction() - 0.5) * 3
            let endY = centerY + CGFloat(random.fraction() - 0.5) * 6
            aircraft.append(RaidAircraft(
                heading: atan2(endY - initialY, endX - initialX),
                startsAt: startedAt + Double(index) * 0.10,
                duration: 3.95 + random.fraction() * 0.17,
                origin: CGPoint(x: initialX, y: initialY),
                destination: CGPoint(x: endX, y: endY)
            ))
        }

        // 落点在开局由独立种子预排，间隔按飞机航迹分布，与居民的位置和疏散无关。
        var bombs: [RaidBomb] = []
        for index in 0..<bombCount {
            let aircraftIndex = index % count
            let plane = aircraft[aircraftIndex]
            let pass = index / count
            let passes = (bombCount - 1 - aircraftIndex) / count + 1
            let phase = (Double(pass) + 0.25 + random.fraction() * 0.5) / Double(passes)
            let routeProgress = 0.17 + 0.65 * phase
            let dropTime = plane.startsAt + plane.duration * routeProgress
            let dropPosition = plane.position(along: (dropTime - plane.startsAt) / plane.duration)
            let drift = CGFloat(2 + random.fraction() * 4) * (leftToRight ? 1 : -1)
            let impactPosition = CGPoint(
                x: dropPosition.x + drift,
                y: dropPosition.y + CGFloat(random.fraction() - 0.5) * 6
            )
            bombs.append(RaidBomb(
                dropTime: dropTime,
                impactTime: dropTime + 0.46 + random.fraction() * 0.27,
                impactPosition: impactPosition,
                radius: CGFloat(3.2 + random.fraction() * 1.7),
                dropPosition: dropPosition
            ))
        }
        bombs.sort { first, second in
            if first.impactTime == second.impactTime {
                return first.dropTime < second.dropTime
            }
            return first.impactTime < second.impactTime
        }
        return RaidState(startedAt: startedAt, aircraft: aircraft, bombs: bombs)
    }

    private func applyDueEvents() {
        while nextEventIndex < events.count, events[nextEventIndex].time <= elapsed {
            let event = events[nextEventIndex]
            nextEventIndex += 1
            switch event.kind {
            case .warning(let phase):
                if phase == .yellow {
                    cities[event.cityIndex].notified = false
                }
                cities[event.cityIndex].warning = phase
            case .raid(let raid):
                cities[event.cityIndex].warning = nil
                cities[event.cityIndex].raid = raid
            case .impact(let bombIndex):
                Self.applyImpact(of: bombIndex, to: &cities[event.cityIndex])
            case .allClear:
                Self.clearRaid(in: &cities[event.cityIndex])
            }
        }
    }

    private static func applyImpact(of bombIndex: Int, to city: inout CityState) {
        guard let raid = city.raid, raid.bombs[bombIndex].casualties == nil else { return }
        let bomb = raid.bombs[bombIndex]
        let radiusSquared = bomb.radius * bomb.radius
        var casualties = 0

        // 重叠的爆点只会命中仍在地表移动的点，已失去或已入洞的居民不再参与。
        for index in city.residents.indices {
            let resident = city.residents[index]
            guard resident.status == .roaming || resident.status == .evacuating else { continue }
            let dx = resident.position.x - bomb.impactPosition.x
            let dy = resident.position.y - bomb.impactPosition.y
            if dx * dx + dy * dy <= radiusSquared {
                city.residents[index].status = .lost
                casualties += 1
            }
        }
        var bombs = raid.bombs
        bombs[bombIndex].casualties = casualties
        city.raid = RaidState(startedAt: raid.startedAt, aircraft: raid.aircraft, bombs: bombs)
        city.damage += 1
    }

    private static func clearRaid(in city: inout CityState) {
        guard let raid = city.raid else { return }
        city.completedRaids.append(raid)
        city.raid = nil
        city.notified = false
        for index in city.residents.indices {
            switch city.residents[index].status {
            case .sheltered, .evacuating:
                city.residents[index].status = .roaming
            case .roaming, .lost:
                break
            }
        }
    }

    private func moveResidents(by interval: TimeInterval) {
        guard interval > 0 else { return }
        for index in cities.indices {
            Self.moveResidents(in: &cities[index], by: interval)
        }
    }

    private static func moveResidents(in city: inout CityState, by interval: TimeInterval) {
        let roads = city.map.roads
        let routes = city.shelterRoutes
        for index in city.residents.indices {
            move(&city.residents[index], along: roads, routes: routes, by: interval)
        }
    }

    private static func makeResident(on roads: [RoadNode], random: inout SimulationRandom) -> Resident {
        let start = Int.random(in: roads.indices, using: &random)
        let end = roads[start].neighbors.randomElement(using: &random) ?? start
        let length = edgeDistance(from: start, to: end, on: roads)
        let fraction = random.fraction()
        // 部分较远的住民需要完整预警窗口，橙色阶段才通知会缩短可达距离。
        return Resident(
            position: position(from: start, to: end, fraction: fraction, on: roads),
            walkingSpeed: 1.2 + 1.3 * random.fraction(),
            evacuationSpeed: 5.1 + 2.45 * random.fraction(),
            random: SimulationRandom(state: random.next()),
            fromNode: start,
            toNode: end,
            edgeLength: length,
            distanceAlongEdge: fraction * length
        )
    }

    private static func beginEvacuation(in city: inout CityState) {
        let routes = city.shelterRoutes
        for index in city.residents.indices where city.residents[index].status == .roaming {
            city.residents[index].status = .evacuating
            let resident = city.residents[index]
            let backwardDistance = resident.distanceAlongEdge + routes[resident.fromNode].distance
            let forwardDistance =
                resident.edgeLength - resident.distanceAlongEdge + routes[resident.toNode].distance
            if backwardDistance < forwardDistance {
                city.residents[index].fromNode = resident.toNode
                city.residents[index].toNode = resident.fromNode
                city.residents[index].distanceAlongEdge = resident.edgeLength - resident.distanceAlongEdge
            }
        }
    }

    private static func move(
        _ resident: inout Resident,
        along roads: [RoadNode],
        routes: [ShelterRoute],
        by interval: TimeInterval
    ) {
        let speed: Double
        switch resident.status {
        case .roaming: speed = resident.walkingSpeed
        case .evacuating: speed = resident.evacuationSpeed
        case .sheltered, .lost: return
        }
        var movement = speed * interval
        while movement > 0 {
            let roomOnEdge = resident.edgeLength - resident.distanceAlongEdge
            if movement < roomOnEdge {
                resident.distanceAlongEdge += movement
                resident.position = position(
                    from: resident.fromNode,
                    to: resident.toNode,
                    fraction: resident.distanceAlongEdge / resident.edgeLength,
                    on: roads
                )
                return
            }
            movement -= roomOnEdge
            let node = resident.toNode
            resident.position = roads[node].position
            let nextNode: Int?
            if resident.status == .evacuating {
                if routes[node].distance == 0 {
                    // 记录抵达的边终点，解除后首步从洞口接入下一条道路。
                    resident.distanceAlongEdge = resident.edgeLength
                    resident.status = .sheltered
                    return
                }
                nextNode = routes[node].next
            } else {
                nextNode = roamingDestination(
                    from: node, previous: resident.fromNode, roads: roads, random: &resident.random
                )
            }
            guard let nextNode else { return }
            let edgeLength = edgeDistance(from: node, to: nextNode, on: roads)
            guard edgeLength > 0 else { return }
            resident.fromNode = node
            resident.toNode = nextNode
            resident.edgeLength = edgeLength
            resident.distanceAlongEdge = 0
        }
    }

    private static func roamingDestination(
        from node: Int,
        previous: Int,
        roads: [RoadNode],
        random: inout SimulationRandom
    ) -> Int? {
        let neighbors = roads[node].neighbors
        guard neighbors.count > 1 else { return neighbors.first }
        let onward = neighbors.filter { $0 != previous }
        return onward.randomElement(using: &random)
    }

    private static func findShelterRoutes(in map: CityMap) -> [ShelterRoute] {
        let roads = map.roads
        var routes = Array(repeating: ShelterRoute(), count: roads.count)
        var settled = Array(repeating: false, count: roads.count)
        for shelter in map.shelters {
            routes[shelter].distance = 0
        }
        for _ in roads {
            var nearest: Int?
            var bestDistance = Double.infinity
            for index in roads.indices where !settled[index] && routes[index].distance < bestDistance {
                nearest = index
                bestDistance = routes[index].distance
            }
            guard let node = nearest else { break }
            settled[node] = true
            for neighbor in roads[node].neighbors where !settled[neighbor] {
                let candidate = bestDistance + edgeDistance(from: node, to: neighbor, on: roads)
                if candidate < routes[neighbor].distance {
                    routes[neighbor] = ShelterRoute(distance: candidate, next: node)
                }
            }
        }
        return routes
    }

    private static func edgeDistance(from start: Int, to end: Int, on roads: [RoadNode]) -> Double {
        let origin = roads[start].position
        let destination = roads[end].position
        return hypot(Double(destination.x - origin.x), Double(destination.y - origin.y))
    }

    private static func position(from start: Int, to end: Int, fraction: Double, on roads: [RoadNode]) -> CGPoint {
        interpolate(from: roads[start].position, to: roads[end].position, progress: fraction)
    }
}

fileprivate struct SimulationRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func fraction() -> Double {
        Double(next() >> 11) / 9_007_199_254_740_992
    }
}
