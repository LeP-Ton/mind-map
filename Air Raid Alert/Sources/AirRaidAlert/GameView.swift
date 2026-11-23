import AppKit

/// 主屏幕绘制俯视城市与战况，实体 Touch Bar 处理防空通知。
final class GameView: NSView {
    var onTogglePause: (() -> Void)?
    var onRestart: (() -> Void)?

    private let simulation: Simulation
    private var cityArtwork: [Int: CityArtwork] = [:]
    private let actionButton = NSButton(title: "暂停", target: nil, action: nil)

    private let background = NSColor(srgbRed: 0.055, green: 0.083, blue: 0.094, alpha: 1)
    private let headerBackground = NSColor(srgbRed: 0.076, green: 0.107, blue: 0.118, alpha: 1)
    private let secondaryInk = NSColor(srgbRed: 0.58, green: 0.67, blue: 0.66, alpha: 1)
    private let paperInk = NSColor(srgbRed: 0.91, green: 0.93, blue: 0.87, alpha: 1)
    private let shelterInk = NSColor(srgbRed: 0.43, green: 0.88, blue: 0.74, alpha: 1)
    private let raidInk = NSColor(srgbRed: 0.94, green: 0.42, blue: 0.41, alpha: 1)
    private let aircraftInk = NSColor(srgbRed: 0.68, green: 0.79, blue: 0.85, alpha: 1)
    private let bombInk = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.43, alpha: 1)
    private let flashInk = NSColor(srgbRed: 1, green: 0.87, blue: 0.63, alpha: 1)
    private let smokeInk = NSColor(srgbRed: 0.67, green: 0.64, blue: 0.59, alpha: 1)
    private let rubbleInk = NSColor(srgbRed: 0.29, green: 0.24, blue: 0.20, alpha: 0.84)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(simulation: Simulation) {
        self.simulation = simulation
        super.init(frame: .zero)
        actionButton.target = self
        actionButton.action = #selector(activateActionButton)
        actionButton.bezelStyle = .rounded
        actionButton.focusRingType = .default
        actionButton.font = Self.chineseFont(12, semibold: true)
        addSubview(actionButton)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        let guide = ScreenLayout(bounds: bounds)
        actionButton.frame = guide.action
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let guide = ScreenLayout(bounds: bounds)
        paint(bounds, color: background, in: context)
        drawHeader(guide: guide, in: context)
        for (index, city) in simulation.cities.enumerated() {
            draw(city: city, in: guide.cityRect(at: index), context: context)
        }
        if simulation.isFinished {
            drawResultCard(in: context)
        }
    }

    @objc private func activateActionButton() {
        if simulation.isFinished {
            onRestart?()
        } else {
            onTogglePause?()
        }
    }

    private func drawHeader(guide: ScreenLayout, in context: CGContext) {
        paint(guide.header, color: headerBackground, in: context)
        paint(
            CGRect(x: 0, y: guide.header.maxY - 1, width: bounds.width, height: 1),
            color: NSColor(srgbRed: 0.18, green: 0.24, blue: 0.25, alpha: 1),
            in: context
        )
        let startX = guide.headerInset
        paint(CGRect(x: startX, y: 18, width: 3, height: 29), color: shelterInk, in: context)
        drawText(
            "躲避空袭", at: CGPoint(x: startX + 14, y: 16),
            font: Self.chineseFont(24, semibold: true), color: paperInk
        )

        let seconds = Int(ceil(simulation.remaining))
        let metrics: [(String, String, NSColor)] = [
            ("剩余时间", String(format: "%02d:%02d", seconds / 60, seconds % 60), paperInk),
            ("城市总人口", String(simulation.population), paperInk),
            ("当前存活人数", String(simulation.alive), paperInk),
            ("当前避难人数", String(simulation.sheltered), shelterInk)
        ]
        for (index, metric) in metrics.enumerated() {
            let x = guide.metricsStart + CGFloat(index) * guide.metricWidth
            paint(
                CGRect(x: x - 13, y: 17, width: 1, height: 33),
                color: secondaryInk.withAlphaComponent(0.21), in: context
            )
            drawText(metric.0, at: CGPoint(x: x, y: 10), font: Self.chineseFont(10), color: secondaryInk)
            drawText(metric.1, at: CGPoint(x: x, y: 24), font: Self.digits(24), color: metric.2)
        }

        let title = simulation.isFinished ? "重开" : simulation.isPaused ? "继续" : "暂停"
        if actionButton.title != title {
            actionButton.title = title
        }
    }

    private func draw(city: CityState, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let artwork: CityArtwork
        if let cached = cityArtwork[city.id] {
            artwork = cached
        } else {
            artwork = CityArtwork(map: city.map, cityID: city.id)
            cityArtwork[city.id] = artwork
        }
        let pixel = MapProjection(rect: rect, scale: window?.backingScaleFactor ?? 1)
        context.saveGState()
        context.clip(to: rect)
        paint(rect, color: headerBackground, in: context)
        if let image = artwork.image {
            // Core Graphics 的图像坐标从下方起始，翻转后与仿真左上原点一致。
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        context.setShouldAntialias(false)
        drawImpactScars(in: city, pixel: pixel, context: context)
        drawResidents(city.residents, pixel: pixel, in: context)
        drawShelters(city, pixel: pixel, in: context)
        let labelColor: NSColor
        if let raid = city.raid {
            drawRaid(raid, elapsed: simulation.elapsed, pixel: pixel, in: context)
            drawCityOutline(color: raidInk, rect: rect, in: context)
            labelColor = raidInk
        } else if let phase = city.warning {
            let ink = warningColor(phase)
            let outline = city.notified ? ink.withAlphaComponent(0.42) : ink
            drawCityOutline(color: outline, rect: rect, in: context)
            labelColor = city.notified ? shelterInk : ink
        } else {
            labelColor = paperInk
        }
        context.restoreGState()

        let labelRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 84, height: 20)
        paint(labelRect, color: background.withAlphaComponent(0.94), in: context)
        drawText(
            city.name, at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 1),
            font: Self.chineseFont(13, semibold: true), color: labelColor
        )
        // 档位沿用开局分类，人数随单城存活情况实时刷新。
        drawText(
            "\(city.density.rawValue) · \(city.livingPopulation)",
            at: CGPoint(x: labelRect.minX + 38, y: labelRect.minY + 3),
            font: Self.chineseFont(11, semibold: true), color: secondaryInk
        )
    }

    private func drawResidents(_ residents: [Resident], pixel: MapProjection, in context: CGContext) {
        var ordinaryPoints: [CGRect] = []
        var evacuationPoints: [CGRect] = []
        ordinaryPoints.reserveCapacity(residents.count)
        for resident in residents {
            switch resident.status {
            case .roaming:
                ordinaryPoints.append(pixel.dot(at: resident.position, size: 1.25))
            case .evacuating:
                evacuationPoints.append(pixel.dot(at: resident.position, size: 1.8))
            case .sheltered, .lost:
                break
            }
        }
        context.setFillColor(NSColor(srgbRed: 0.90, green: 0.87, blue: 0.76, alpha: 0.84).cgColor)
        context.fill(ordinaryPoints)
        context.setFillColor(shelterInk.cgColor)
        context.fill(evacuationPoints)
    }

    private func drawShelters(_ city: CityState, pixel: MapProjection, in context: CGContext) {
        let ink = city.notified ? shelterInk : shelterInk.withAlphaComponent(0.56)
        for index in city.map.shelters {
            let position = city.map.roads[index].position
            let plate = pixel.dot(at: position, size: 3.9)
            paint(plate, color: background, in: context)
            paint(pixel.dot(at: position, size: 2.1), color: ink, in: context)
        }
    }

    private func drawCityOutline(color: NSColor, rect: CGRect, in context: CGContext) {
        let thickness: CGFloat = 2
        let dash: CGFloat = 11
        let margin: CGFloat = 2
        let inner = rect.insetBy(dx: margin, dy: margin)
        var marks: [CGRect] = []
        // 短实线贴地图边缘，给城市内部的人流保留对比度。
        for x in stride(from: inner.minX, to: inner.maxX - dash, by: dash * 2.2) {
            marks.append(CGRect(x: x, y: inner.minY, width: dash, height: thickness))
            marks.append(CGRect(x: x, y: inner.maxY - thickness, width: dash, height: thickness))
        }
        for y in stride(from: inner.minY + dash, to: inner.maxY - dash * 1.5, by: dash * 2.2) {
            marks.append(CGRect(x: inner.minX, y: y, width: thickness, height: dash))
            marks.append(CGRect(x: inner.maxX - thickness, y: y, width: thickness, height: dash))
        }
        context.setFillColor(color.cgColor)
        context.fill(marks)
    }

    private func drawImpactScars(in city: CityState, pixel: MapProjection, context: CGContext) {
        guard !city.completedRaids.isEmpty || city.raid != nil else { return }
        // 按城批量绘制各波已经结算的落点，痕迹始终在居民与防空洞标记下方。
        var rims: [CGRect] = []
        var cores: [CGRect] = []
        let capacity = city.completedRaids.reduce(0) { $0 + $1.bombs.count } + (city.raid?.bombs.count ?? 0)
        rims.reserveCapacity(capacity)
        cores.reserveCapacity(capacity)

        func addScars(from raid: RaidState) {
            for bomb in raid.bombs where bomb.casualties != nil {
                let size = bomb.radius * 0.56
                rims.append(pixel.mapSquare(at: bomb.impactPosition, size: size))
                cores.append(pixel.mapSquare(at: bomb.impactPosition, size: size * 0.50))
            }
        }
        for raid in city.completedRaids {
            addScars(from: raid)
        }
        if let raid = city.raid {
            addScars(from: raid)
        }
        context.setFillColor(rubbleInk.cgColor)
        context.fill(rims)
        context.setFillColor(background.withAlphaComponent(0.83).cgColor)
        context.fill(cores)
    }

    private func drawRaid(_ raid: RaidState, elapsed: TimeInterval, pixel: MapProjection, in context: CGContext) {
        var lossLabels: [CGRect] = []
        for bomb in raid.bombs {
            if let point = bomb.position(at: elapsed) {
                drawFallingBomb(bomb, at: point, elapsed: elapsed, pixel: pixel, in: context)
            } else if let casualties = bomb.casualties {
                let age = CGFloat(elapsed - bomb.impactTime)
                if (0..<CGFloat(RaidState.impactEffectDuration)).contains(age) {
                    drawBurst(bomb, age: age, casualties: casualties, pixel: pixel, in: context)
                }
                if casualties > 0, (0..<0.56).contains(age) {
                    drawLossLabel(casualties, at: bomb.impactPosition, age: age, pixel: pixel, placed: &lossLabels)
                }
            }
        }
        for aircraft in raid.aircraft {
            guard let point = aircraft.position(at: elapsed) else { continue }
            let position = pixel.screenPoint(at: point)
            let unit = max(1.15, min(2, pixel.rect.width / 148))
            context.saveGState()
            context.translateBy(x: position.x, y: position.y)
            context.rotate(by: aircraft.heading)
            context.scaleBy(x: unit, y: unit)
            context.setLineWidth(0.58)
            context.setLineJoin(.round)
            context.setStrokeColor(background.cgColor)
            context.setFillColor(aircraftInk.cgColor)
            context.addPath(Self.aircraftOutline)
            context.drawPath(using: .fillStroke)
            paint(CGRect(x: -2.2, y: -0.24, width: 4.5, height: 0.48), color: paperInk, in: context)
            context.restoreGState()
        }
    }

    private func drawFallingBomb(
        _ bomb: RaidBomb, at point: CGPoint, elapsed: TimeInterval, pixel: MapProjection, in context: CGContext
    ) {
        // 短残迹来自同一枚落弹的先前位置，随当前弹体一起消失。
        for index in [2, 1] {
            let time = elapsed - Double(index) * 0.07
            guard let previous = bomb.position(at: time) else { continue }
            let opacity: CGFloat = index == 2 ? 0.34 : 0.64
            paint(pixel.dot(at: previous, size: 1.5), color: bombInk.withAlphaComponent(opacity), in: context)
        }
        paint(pixel.dot(at: point, size: 4.1), color: background.withAlphaComponent(0.84), in: context)
        paint(pixel.dot(at: point, size: 2.8), color: bombInk, in: context)
    }

    private func drawBurst(
        _ bomb: RaidBomb, age: CGFloat, casualties: Int, pixel: MapProjection, in context: CGContext
    ) {
        let origin = bomb.impactPosition
        if age < 0.32 {
            let flashProgress = age / 0.32
            let range = bomb.radius * (0.28 + flashProgress * 0.72)
            let ink = casualties > 0 ? flashInk : bombInk
            paint(
                pixel.dot(at: origin, size: 4.4 - flashProgress * 2),
                color: ink.withAlphaComponent(1 - flashProgress * 0.68), in: context
            )
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4
                let point = CGPoint(x: origin.x + cos(angle) * range, y: origin.y + sin(angle) * range)
                paint(
                    pixel.dot(at: point, size: 2.1),
                    color: bombInk.withAlphaComponent(1 - flashProgress * 0.84), in: context
                )
            }
        }
        let smokeDelay: CGFloat = 0.12
        guard age >= smokeDelay else { return }
        let smokeProgress = (age - smokeDelay) / (CGFloat(RaidState.impactEffectDuration) - smokeDelay)
        for index in 0..<3 {
            let offset = CGFloat(index)
            let drift = CGPoint(
                x: origin.x + bomb.radius * smokeProgress * (0.10 + offset * 0.20),
                y: origin.y - bomb.radius * (smokeProgress * 0.58 + offset * 0.15)
            )
            paint(
                pixel.dot(at: drift, size: 2.5 + smokeProgress * 1.3),
                color: smokeInk.withAlphaComponent((1 - smokeProgress) * (0.58 - offset * 0.11)), in: context
            )
        }
    }

    private func drawLossLabel(
        _ casualties: Int, at point: CGPoint, age: CGFloat, pixel: MapProjection, placed: inout [CGRect]
    ) {
        let text = "−\(casualties)"
        let width = CGFloat(text.count) * 6
        let center = pixel.screenPoint(at: point)
        // 爆点接近时尝试另一侧，给每个扣减数字留出独立的阅读位置。
        let offsets: [(CGFloat, CGFloat)] = [(5, -12), (-width - 4, -12), (5, 4), (-width - 4, 4)]
        for (x, y) in offsets {
            let rect = CGRect(
                x: min(max(center.x + x, pixel.rect.minX + 2), pixel.rect.maxX - width - 2),
                y: min(max(center.y + y - age * 6, pixel.rect.minY + 2), pixel.rect.maxY - 12),
                width: width, height: 11
            )
            guard !placed.contains(where: { $0.intersects(rect) }) else { continue }
            placed.append(rect)
            let opacity = min(1, (0.56 - age) / 0.24)
            drawText(text, at: rect.origin, font: Self.digits(9), color: flashInk.withAlphaComponent(opacity))
            return
        }
    }

    // 机形以向右为原点，图元根据模型朝向旋转。
    private static let aircraftOutline: CGPath = {
        let vertices = [
            CGPoint(x: 4.7, y: 0), CGPoint(x: 3.1, y: -0.8), CGPoint(x: 1.1, y: -0.8),
            CGPoint(x: -0.15, y: -3.55), CGPoint(x: -1.45, y: -3.55), CGPoint(x: -1.12, y: -0.8),
            CGPoint(x: -2.72, y: -0.8), CGPoint(x: -3.46, y: -1.7), CGPoint(x: -4.18, y: -1.7),
            CGPoint(x: -3.95, y: 0), CGPoint(x: -4.18, y: 1.7), CGPoint(x: -3.46, y: 1.7),
            CGPoint(x: -2.72, y: 0.8), CGPoint(x: -1.12, y: 0.8), CGPoint(x: -1.45, y: 3.55),
            CGPoint(x: -0.15, y: 3.55), CGPoint(x: 1.1, y: 0.8), CGPoint(x: 3.1, y: 0.8)
        ]
        let path = CGMutablePath()
        path.addLines(between: vertices)
        path.closeSubpath()
        return path
    }()

    private func drawResultCard(in context: CGContext) {
        let width: CGFloat = 246
        let rect = CGRect(x: bounds.midX - width / 2, y: bounds.midY - 51, width: width, height: 102)
        paint(rect, color: headerBackground.withAlphaComponent(0.98), in: context)
        paint(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2), color: shelterInk, in: context)
        let percent = simulation.population > 0 ? 100 * Double(simulation.alive) / Double(simulation.population) : 0
        drawText(
            "本轮结束", at: CGPoint(x: rect.minX + 20, y: rect.minY + 16),
            font: Self.chineseFont(17, semibold: true), color: paperInk
        )
        drawText(
            "存活率", at: CGPoint(x: rect.minX + 20, y: rect.minY + 63),
            font: Self.chineseFont(12), color: secondaryInk
        )
        drawText(
            String(format: "%.1f%%", percent), at: CGPoint(x: rect.minX + 85, y: rect.minY + 48),
            font: Self.digits(28), color: shelterInk
        )
    }

    private func warningColor(_ phase: WarningPhase) -> NSColor {
        switch phase {
        case .yellow: return NSColor(srgbRed: 0.95, green: 0.80, blue: 0.43, alpha: 1)
        case .orange: return NSColor(srgbRed: 0.96, green: 0.58, blue: 0.33, alpha: 1)
        }
    }

    private func paint(_ rect: CGRect, color: NSColor, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }

    private func drawText(_ text: String, at origin: CGPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func chineseFont(_ size: CGFloat, semibold: Bool = false) -> NSFont {
        let name = semibold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
    }

    private static func digits(_ size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Bold", size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .bold)
    }
}

private struct ScreenLayout {
    let header: CGRect
    let headerInset: CGFloat
    let metricsStart: CGFloat
    let metricWidth: CGFloat
    let action: CGRect
    private let citySize: CGSize
    private let cityOrigin: CGPoint
    private let gap: CGFloat = 7

    init(bounds: CGRect) {
        let headerHeight: CGFloat = 64
        let margin: CGFloat = 18
        let cityAspect = CGFloat(CityMap.width) / CGFloat(CityMap.height)
        let widthLimit = (bounds.width - margin * 2 - gap * 3) / 4
        let heightLimit = (bounds.height - headerHeight - margin * 2 - gap * 3) / 4
        let cityHeight = max(0, floor(min(widthLimit / cityAspect, heightLimit)))
        let cityWidth = floor(cityHeight * cityAspect)
        let mapWidth = cityWidth * 4 + gap * 3
        let mapHeight = cityHeight * 4 + gap * 3

        header = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        headerInset = max(margin, min(47, floor((bounds.width - mapWidth) / 2)))
        metricsStart = headerInset + 170
        action = CGRect(x: bounds.maxX - headerInset - 65, y: 20, width: 65, height: 25)
        metricWidth = max(87, (action.minX - metricsStart - 13) / 4)
        citySize = CGSize(width: cityWidth, height: cityHeight)
        cityOrigin = CGPoint(
            x: floor((bounds.width - mapWidth) / 2),
            y: floor(headerHeight + (bounds.height - headerHeight - mapHeight) / 2)
        )
    }

    func cityRect(at index: Int) -> CGRect {
        CGRect(
            x: cityOrigin.x + CGFloat(index % 4) * (citySize.width + gap),
            y: cityOrigin.y + CGFloat(index / 4) * (citySize.height + gap),
            width: citySize.width, height: citySize.height
        )
    }
}

private struct MapProjection {
    let rect: CGRect
    let scale: CGFloat

    private var stepX: CGFloat { rect.width / CGFloat(CityMap.width) }
    private var stepY: CGFloat { rect.height / CGFloat(CityMap.height) }

    func screenPoint(at point: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + point.x * stepX, y: rect.minY + point.y * stepY)
    }

    func dot(at point: CGPoint, size: CGFloat) -> CGRect {
        let extent = max(1, (size * scale).rounded()) / scale
        let center = screenPoint(at: point)
        return CGRect(
            x: snap(center.x - extent / 2), y: snap(center.y - extent / 2), width: extent, height: extent
        )
    }

    func mapSquare(at point: CGPoint, size: CGFloat) -> CGRect {
        dot(at: point, size: size * min(stepX, stepY))
    }

    private func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
}

private struct CityArtwork {
    let image: CGImage?

    init(map: CityMap, cityID: Int) {
        var rasters: [UInt8] = []
        rasters.reserveCapacity(map.tiles.count * 4)
        for (index, tile) in map.tiles.enumerated() {
            let x = index % CityMap.width
            let y = index / CityMap.width
            let hasRoofToLeft = x > 0 && map.tiles[index - 1].isRoof
            let hasRoofAbove = y > 0 && map.tiles[index - CityMap.width].isRoof
            let swatch = Self.color(for: tile)
            // 边界保留硬边，连续色块采用轻微变化表现地表材质。
            let noise = (x * 13 + y * 23 + x * y * 7 + cityID * 3) % 9 - 4
            let edge = tile.isRoof && (!hasRoofToLeft || !hasRoofAbove) ? -8 : 0
            let shade = tile.isRoof ? edge + noise / 3 : noise
            rasters.append(UInt8(clamping: swatch.0 + shade))
            rasters.append(UInt8(clamping: swatch.1 + shade))
            rasters.append(UInt8(clamping: swatch.2 + shade))
            rasters.append(255)
        }
        if let provider = CGDataProvider(data: Data(rasters) as CFData) {
            image = CGImage(
                width: CityMap.width, height: CityMap.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: CityMap.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        } else {
            image = nil
        }
    }

    private static func color(for tile: TerrainTile) -> (Int, Int, Int) {
        switch tile {
        case .soil: return (45, 58, 57)
        case .vegetation: return (35, 64, 55)
        case .water: return (24, 53, 63)
        case .road: return (61, 74, 75)
        case .roof: return (126, 125, 106)
        case .roofAlt: return (117, 95, 79)
        case .roofDark: return (87, 98, 94)
        case .yard: return (77, 80, 67)
        }
    }
}

private extension TerrainTile {
    var isRoof: Bool {
        switch self {
        case .roof, .roofAlt, .roofDark: return true
        default: return false
        }
    }
}
