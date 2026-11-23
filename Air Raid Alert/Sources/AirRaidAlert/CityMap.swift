import Foundation

enum TerrainTile: UInt8 {
    case soil, vegetation, water, road, roof, roofAlt, roofDark, yard
}

struct RoadNode {
    let position: CGPoint
    let neighbors: [Int]
}

struct CityMap {
    static let width = 96
    static let height = 54

    let tiles: [TerrainTile]
    let roads: [RoadNode]
    let shelters: [Int]

    static func make(seed: UInt64) -> CityMap {
        var generator = CityMapGenerator(seed: seed)
        return generator.build()
    }
}

private struct CityMapGenerator {
    private let width = CityMap.width
    private let height = CityMap.height
    private let columns = 6
    private let rows = 5
    private var randomState: UInt64
    private var tiles = Array(repeating: TerrainTile.soil, count: CityMap.width * CityMap.height)
    private var nodes: [CGPoint] = []
    private var neighbors: [[Int]] = []

    init(seed: UInt64) {
        randomState = seed
    }

    mutating func build() -> CityMap {
        layTerrain()
        layRoads()
        layBuildings()
        let shelters = [7, 10, 14, 19, 22]
        return CityMap(
            tiles: tiles,
            roads: nodes.indices.map { RoadNode(position: nodes[$0], neighbors: neighbors[$0]) },
            shelters: shelters
        )
    }

    private mutating func layTerrain() {
        let coast = random(8)
        let bend = random(15) - 7
        for y in 0..<height {
            for x in 0..<width {
                // 低频地表斑块和不同的河岸走向让城市之间能从远处辨认。
                let patch = sin(Double(x + bend) * 0.14) + cos(Double(y - bend) * 0.23)
                let river = 18 + 8 * sin(Double(y + bend) * 0.09)
                let shore = 6 + 4 * cos(Double(x + bend) * 0.10)
                let onWater: Bool
                switch coast {
                case 0: onWater = Double(x) < river * 0.58
                case 1: onWater = abs(Double(x) - river) < 2.6
                case 2: onWater = Double(y) > Double(height) - shore
                case 3: onWater = Double(x) > Double(width) - river * 0.54
                case 4: onWater = abs(Double(y) - shore - 2) < 1.8
                default: onWater = false
                }
                if onWater {
                    set(.water, x: x, y: y)
                } else if patch > 0.55 && random(9) > 1 || random(31) == 0 {
                    set(.vegetation, x: x, y: y)
                }
            }
        }
    }

    private mutating func layRoads() {
        let avenueRow = 1 + random(rows - 2)
        let left = 8 + random(8)
        let top = 6 + random(4)
        let xSpacing = 13 + random(2)
        let ySpacing = 8 + random(2)
        for row in 0..<rows {
            let shift = random(9) - 4
            for column in 0..<columns {
                let x = left + column * xSpacing + shift + random(7) - 3
                let y = top + row * ySpacing + random(7) - 3
                nodes.append(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                neighbors.append([])
            }
        }
        for row in 0..<rows {
            for column in 0..<(columns - 1) {
                // 中部主路贯通一城，次路随街廓错位。
                let index = row * columns + column
                connect(index, index + 1, wide: row == avenueRow)
            }
            guard row + 1 < rows else { continue }
            let connectingColumn = 1 + random(columns - 2)
            for column in 0..<columns where column == connectingColumn || random(5) < 2 {
                let index = row * columns + column
                connect(index, index + columns, wide: column == connectingColumn)
            }
        }
    }

    private mutating func connect(_ first: Int, _ second: Int, wide: Bool) {
        neighbors[first].append(second)
        neighbors[second].append(first)
        let start = nodes[first]
        let end = nodes[second]
        let steps = Int(max(abs(end.x - start.x), abs(end.y - start.y)) * 2)
        for step in 0...steps {
            let progress = CGFloat(step) / CGFloat(max(steps, 1))
            let x = Int(start.x + (end.x - start.x) * progress)
            let y = Int(start.y + (end.y - start.y) * progress)
            set(.road, x: x, y: y)
            if wide {
                if abs(end.x - start.x) >= abs(end.y - start.y) {
                    set(.road, x: x, y: y + 1)
                } else {
                    set(.road, x: x + 1, y: y)
                }
            }
        }
    }

    private mutating func layBuildings() {
        let density = 4 + random(5)
        let roofBias = random(3)
        for first in nodes.indices {
            for second in neighbors[first] where second > first {
                let start = nodes[first]
                let end = nodes[second]
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = hypot(dx, dy)
                let lots = max(1, Int(length / 4))
                for side in [-1.0, 1.0] {
                    for lot in 0..<lots where random(10) < density {
                        // 沿路两侧生长建筑组，坐标始终落在同一组地图像素上。
                        let progress = (CGFloat(lot) + 0.5) / CGFloat(lots)
                        let setback = CGFloat(side) * CGFloat(2 + random(3))
                        let x = Int(start.x + dx * progress - dy * setback / length)
                        let y = Int(start.y + dy * progress + dx * setback / length)
                        let horizontal = abs(dx) >= abs(dy)
                        let broad = 2 + random(5)
                        let narrow = 1 + random(3)
                        let tile = [TerrainTile.roof, .roofAlt, .roofDark][(random(3) + roofBias) % 3]
                        placeLot(tile, x: x, y: y, width: horizontal ? broad : narrow, height: horizontal ? narrow : broad)
                    }
                }
            }
        }

        for _ in 0..<(18 + density * 3) {
            let x = 7 + random(width - 14)
            let y = 6 + random(height - 12)
            let nearTown = nodes.contains { abs($0.x - CGFloat(x)) + abs($0.y - CGFloat(y)) < 10 }
            guard nearTown else { continue }
            let tile: TerrainTile = random(3) == 0 ? .yard : .roofDark
            let w = 2 + random(6)
            let h = 2 + random(5)
            placeLot(tile, x: x, y: y, width: w, height: h)
        }
    }

    private mutating func placeLot(_ tile: TerrainTile, x: Int, y: Int, width w: Int, height h: Int) {
        let left = x - w / 2
        let top = y - h / 2
        guard left >= 1, top >= 1, left + w < width, top + h < height else { return }
        for row in top..<(top + h) {
            for column in left..<(left + w) {
                let current = tiles[row * width + column]
                guard current == .soil || current == .vegetation else { return }
            }
        }
        for row in top..<(top + h) {
            for column in left..<(left + w) {
                let accent = tile != .yard && w >= 5 && row == top && random(5) > 1
                set(accent ? .roofDark : tile, x: column, y: row)
            }
        }
    }

    private mutating func set(_ tile: TerrainTile, x: Int, y: Int) {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return }
        tiles[y * width + x] = tile
    }

    private mutating func random(_ upperBound: Int) -> Int {
        randomState &+= 0x9e3779b97f4a7c15
        var value = randomState
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Int((value ^ (value >> 31)) % UInt64(upperBound))
    }
}
