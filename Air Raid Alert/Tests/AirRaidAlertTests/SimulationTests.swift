import Foundation
import XCTest
@testable import AirRaidAlert

final class SimulationTests: XCTestCase {
    func testSixteenDistinctConnectedCitiesAndPopulation() {
        let game = Simulation(seed: 42)
        XCTAssertEqual(game.cities.map(\.id), Array(1...16))
        XCTAssertEqual(Set(game.cities.map(\.name)).count, 16)
        XCTAssertTrue(game.cities.allSatisfy { $0.name.count == 2 && !$0.name.contains(where: \.isNumber) })
        XCTAssertEqual(game.cities[2].name, "石桥")
        XCTAssertEqual(Set(game.cities.map { $0.map.tiles.map(\.rawValue) }).count, 16)
        let openingPopulations = [150, 45, 200, 120, 190, 55, 130, 100, 135, 195, 65, 115, 140, 110, 215, 35]
        XCTAssertEqual(game.cities.map { $0.residents.count }, openingPopulations)
        XCTAssertEqual(game.cities.map(\.livingPopulation), openingPopulations)
        XCTAssertEqual(game.cities.filter { $0.density == .high }.count, 4)
        XCTAssertEqual(game.cities.filter { $0.density == .medium }.count, 8)
        XCTAssertEqual(game.cities.filter { $0.density == .low }.count, 4)
        XCTAssertEqual(game.cities[2].density, .high)
        XCTAssertEqual(game.cities[15].density, .low)
        XCTAssertEqual(game.population, 2000)
        XCTAssertEqual(game.alive, 2000)
        XCTAssertEqual(game.sheltered, 0)

        for city in game.cities {
            let map = city.map
            XCTAssertEqual(map.tiles.count, CityMap.width * CityMap.height)
            XCTAssertFalse(map.shelters.isEmpty)
            var reached: Set<Int> = [0]
            var pending = [0]
            while let current = pending.popLast() {
                let road = map.roads[current]
                let tile = Int(road.position.y) * CityMap.width + Int(road.position.x)
                XCTAssertEqual(map.tiles[tile], .road)
                for next in road.neighbors where reached.insert(next).inserted {
                    pending.append(next)
                }
            }
            XCTAssertEqual(reached.count, map.roads.count)
            XCTAssertTrue(map.shelters.allSatisfy(reached.contains))
        }
    }

    func testSlowerDotsAndOpeningAlertPhases() {
        let game = Simulation(seed: 42)
        let initial = game.cities[2].residents.map(\.position)
        game.advance(by: 1)
        let displacements = zip(initial, game.cities[2].residents.map(\.position)).map {
            hypot($1.x - $0.x, $1.y - $0.y)
        }
        XCTAssertGreaterThan(displacements.max() ?? 0, 0)
        XCTAssertLessThanOrEqual(displacements.max() ?? 0, 2.6)
        XCTAssertNil(game.cities[2].warning)
        game.advance(by: 1.05)
        XCTAssertEqual(game.cities[2].warning, .yellow)
        game.advance(by: 1)
        XCTAssertEqual(game.cities[2].warning, .orange)
        game.advance(by: 1)
        XCTAssertNil(game.cities[2].warning)
        XCTAssertNotNil(game.cities[2].raid)
        XCTAssertFalse(game.notify(cityID: 3))
        XCTAssertEqual(game.cities[2].damage, 0)
        XCTAssertEqual(game.alive, game.population)
    }

    func testOneSecondWarningPhasesInMiddleAndLateWaves() throws {
        let game = Simulation(seed: 42)
        let starts: [TimeInterval] = [32.4, 63.2]
        for start in starts {
            game.advance(by: start - 0.01 - game.elapsed)
            let previousWarnings = game.cities.map(\.warning)
            game.advance(by: 0.02)
            let index = try XCTUnwrap(game.cities.indices.first {
                previousWarnings[$0] == nil && game.cities[$0].warning == .yellow
            })
            let phases: [WarningPhase?] = [.yellow, .orange, nil]
            for phase in 0..<2 {
                let boundary = start + Double(phase + 1)
                game.advance(by: boundary - 0.01 - game.elapsed)
                XCTAssertEqual(game.cities[index].warning, phases[phase])
                game.advance(by: 0.02)
                XCTAssertEqual(game.cities[index].warning, phases[phase + 1])
            }
            XCTAssertNotNil(game.cities[index].raid)
            XCTAssertFalse(game.notify(cityID: game.cities[index].id))
        }
    }

    func testEarlyNotificationSavesMoreResidentsThanNoNotification() throws {
        let protected = Simulation(seed: 42)
        let unprotected = Simulation(seed: 42)
        protected.advance(by: 2.05)
        XCTAssertTrue(protected.notify(cityID: 3))
        XCTAssertFalse(protected.notify(cityID: 3))
        XCTAssertFalse(protected.notify(cityID: 0))
        XCTAssertTrue(protected.cities[2].residents.contains { $0.status == .evacuating })
        try finishFirstRaid(protected)
        try finishFirstRaid(unprotected)
        XCTAssertGreaterThan(protected.sheltered, unprotected.sheltered)
        XCTAssertGreaterThan(protected.alive, unprotected.alive)
        XCTAssertEqual(protected.population, unprotected.population)
    }

    func testLateNotificationLeavesMoreResidentsExposed() throws {
        let early = Simulation(seed: 42)
        let late = Simulation(seed: 42)
        early.advance(by: 2.05)
        late.advance(by: 3.95)
        XCTAssertTrue(early.notify(cityID: 3))
        XCTAssertTrue(late.notify(cityID: 3))
        try finishFirstRaid(early)
        try finishFirstRaid(late)
        XCTAssertGreaterThan(early.sheltered, late.sheltered)
        XCTAssertGreaterThan(early.alive, late.alive)
        XCTAssertEqual(early.cities[2].raid?.bombs.map(\.impactPosition), late.cities[2].raid?.bombs.map(\.impactPosition))
    }

    func testRaidShowsAircraftAndBombsBeforeAnyPopulationChange() throws {
        let game = Simulation(seed: 42)
        game.advance(by: 4.05)
        let raid = try XCTUnwrap(game.cities[2].raid)
        XCTAssertTrue((5...8).contains(raid.aircraft.count))
        XCTAssertEqual(raid.bombs.count, 30)
        XCTAssertTrue(raid.bombs.allSatisfy { $0.dropTime >= raid.startedAt && $0.dropTime < $0.impactTime })
        for bomb in raid.bombs {
            let release = try XCTUnwrap(bomb.position(at: bomb.dropTime))
            XCTAssertTrue(raid.aircraft.contains { aircraft in
                guard let plane = aircraft.position(at: bomb.dropTime) else { return false }
                return hypot(release.x - plane.x, release.y - plane.y) < 0.000_001
            })
        }
        let first = try XCTUnwrap(raid.bombs.min { $0.impactTime < $1.impactTime })
        let dropping = (first.dropTime + first.impactTime) / 2
        XCTAssertNil(first.position(at: first.dropTime - 0.01))
        XCTAssertNotNil(first.position(at: dropping))
        XCTAssertNil(first.position(at: first.impactTime + 0.01))
        game.advance(by: dropping - game.elapsed)
        XCTAssertTrue(raid.aircraft.contains { $0.position(at: game.elapsed) != nil })
        XCTAssertEqual(game.alive, game.population)
        XCTAssertTrue(game.cities[2].raid?.bombs.allSatisfy { $0.casualties == nil } ?? false)
    }

    func testEachBombOnlyCountsOutdoorResidentsInsideItsVisibleFootprint() throws {
        let game = Simulation(seed: 42)
        game.advance(by: 3.05)
        XCTAssertTrue(game.notify(cityID: 3))
        game.advance(by: 1)
        let raid = try XCTUnwrap(game.cities[2].raid)
        let impactTimes = Set(raid.bombs.map(\.impactTime)).sorted()
        for time in impactTimes {
            let previous = game.cities[2].residents.map(\.status)
            game.advance(by: time - game.elapsed)
            let city = game.cities[2]
            let bombs = try XCTUnwrap(city.raid?.bombs.filter { $0.impactTime == time })
            let residents = city.residents
            var exposed = Set(residents.indices.filter {
                previous[$0] != .lost && residents[$0].status != .sheltered
            })
            var expectedLosses = Set<Int>()
            for bomb in bombs {
                // 用落地当刻的点位置和画面所用的圆形范围独立重算命中。
                let hit = exposed.filter { index in
                    let point = residents[index].position
                    return hypot(point.x - bomb.impactPosition.x, point.y - bomb.impactPosition.y) <= bomb.radius
                }
                XCTAssertEqual(bomb.casualties, hit.count)
                expectedLosses.formUnion(hit)
                exposed.subtract(hit)
            }
            let actualLosses = residents.indices.filter { previous[$0] != .lost && residents[$0].status == .lost }
            XCTAssertEqual(Set(actualLosses), expectedLosses)

            XCTAssertEqual(city.livingPopulation, residents.filter { $0.status != .lost }.count)
            XCTAssertEqual(game.alive, game.cities.reduce(0) { $0 + $1.livingPopulation })
            XCTAssertEqual(game.population - game.alive, recordedLosses(in: game))
        }
        XCTAssertEqual(game.cities[2].damage, 30)
        let casualties = try XCTUnwrap(game.cities[2].raid).bombs.compactMap(\.casualties)
        XCTAssertTrue(casualties.contains(0))
        XCTAssertTrue(casualties.contains { $0 > 0 })
        XCTAssertGreaterThan(game.sheltered, 0)
    }

    func testPauseAndRestartWithAllFortyEightRaidsSettled() {
        let game = Simulation(seed: 42)
        game.advance(by: 2.05)
        let pausedTime = game.elapsed
        let positions = game.cities[2].residents.map(\.position)
        game.togglePause()
        game.advance(by: 3)
        XCTAssertEqual(game.elapsed, pausedTime)
        XCTAssertEqual(game.cities[2].residents.map(\.position), positions)
        XCTAssertFalse(game.notify(cityID: 3))
        game.togglePause()
        var openingAlertPeak = 0
        var lateAlertPeak = 0
        var sawMixedDensityAlerts = false
        while !game.isFinished {
            game.advance(by: 0.25)
            let pending = game.cities.filter { $0.warning != nil && !$0.notified }
            if game.elapsed <= 20 {
                openingAlertPeak = max(openingAlertPeak, pending.count)
            } else if game.elapsed >= 60 {
                lateAlertPeak = max(lateAlertPeak, pending.count)
                let high = pending.filter { $0.density == .high }.map(\.livingPopulation).max() ?? 0
                let low = pending.filter { $0.density == .low }.map(\.livingPopulation).max() ?? 0
                sawMixedDensityAlerts = sawMixedDensityAlerts || (low > 0 && high > low)
            }
        }
        XCTAssertTrue(game.isFinished)
        XCTAssertEqual(game.remaining, 0)
        XCTAssertGreaterThanOrEqual(lateAlertPeak, 6)
        XCTAssertGreaterThan(lateAlertPeak, openingAlertPeak)
        XCTAssertTrue(sawMixedDensityAlerts)
        XCTAssertTrue(game.cities.allSatisfy { city in
            let starts = city.completedRaids.map(\.startedAt)
            let wavesAreSeparated = zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= 16 - 0.000_001 }
            return city.damage == 90 && city.raid == nil && city.completedRaids.count == 3 && wavesAreSeparated &&
                city.completedRaids.allSatisfy { raid in
                    raid.bombs.count == 30 && raid.bombs.allSatisfy { $0.casualties != nil }
                }
        })
        XCTAssertEqual(game.population - game.alive, recordedLosses(in: game))
        game.reset()
        XCTAssertFalse(game.isFinished)
        XCTAssertFalse(game.isPaused)
        XCTAssertEqual(game.remaining, game.duration)
        XCTAssertEqual(game.alive, 2000)
        XCTAssertEqual(game.cities.map(\.livingPopulation), game.cities.map { $0.residents.count })
        XCTAssertTrue(game.cities.allSatisfy { city in
            city.damage == 0 && city.warning == nil && city.raid == nil && city.completedRaids.isEmpty
        })
    }

    func testResidentsReturnToRoadAndTownCanBeNotifiedAgain() throws {
        let game = Simulation(seed: 42)
        game.advance(by: 2.05)
        XCTAssertTrue(game.notify(cityID: 3))
        XCTAssertFalse(game.notify(cityID: 3))
        try finishFirstRaid(game)
        let first = game.cities[2]
        let residentID = try XCTUnwrap(first.residents.firstIndex { $0.status == .sheltered })
        let shelter = first.residents[residentID].position
        let aliveBeforeRelease = first.residents.filter { $0.status != .lost }.count
        while game.cities[2].completedRaids.isEmpty && !game.isFinished {
            game.advance(by: 0.1)
        }
        let cleared = game.cities[2]
        XCTAssertEqual(cleared.completedRaids.count, 1)
        XCTAssertNil(cleared.raid)
        XCTAssertFalse(cleared.notified)
        XCTAssertEqual(cleared.residents.filter { $0.status == .roaming }.count, aliveBeforeRelease)
        let position = cleared.residents[residentID].position
        XCTAssertLessThanOrEqual(hypot(position.x - shelter.x, position.y - shelter.y), 0.26)
        XCTAssertFalse(game.notify(cityID: 3))

        while game.cities[2].warning == nil && !game.isFinished {
            game.advance(by: 0.25)
        }
        XCTAssertEqual(game.cities[2].warning, .yellow)
        XCTAssertTrue(game.notify(cityID: 3))
        XCTAssertTrue(game.cities[2].residents.contains { $0.status == .evacuating })
        XCTAssertFalse(game.notify(cityID: 3))
    }

    private func recordedLosses(in game: Simulation) -> Int {
        game.cities.reduce(0) { total, city in
            var cityLosses = city.raid?.bombs.compactMap(\.casualties).reduce(0, +) ?? 0
            for raid in city.completedRaids {
                cityLosses += raid.bombs.compactMap(\.casualties).reduce(0, +)
            }
            return total + cityLosses
        }
    }

    private func finishFirstRaid(_ game: Simulation) throws {
        game.advance(by: 4.05 - game.elapsed)
        let lastImpact = try XCTUnwrap(game.cities[2].raid?.bombs.map(\.impactTime).max())
        game.advance(by: lastImpact - game.elapsed + 0.01)
    }
}
