import AppKit

final class TouchBarController: NSObject {
    private let onNotify: (Int) -> Void
    private let buttons = (1...16).map { CityTouchButton(cityID: $0) }

    // 把 16 个城镇键放进同一个原生项目，在系统分配的应用区域内一起伸缩。
    private lazy var bar: NSTouchBar = {
        let identifier = NSTouchBarItem.Identifier("com.airraidalert.touchbar.cities")
        let citiesItem = NSCustomTouchBarItem(identifier: identifier)
        citiesItem.visibilityPriority = .high
        citiesItem.view = CityTouchRow(buttons: buttons)

        let touchBar = NSTouchBar()
        touchBar.templateItems = [citiesItem]
        touchBar.defaultItemIdentifiers = [identifier]
        return touchBar
    }()

    init(onNotify: @escaping (Int) -> Void) {
        self.onNotify = onNotify
        super.init()
        for button in buttons {
            button.target = self
            button.action = #selector(notify(_:))
        }
    }

    func makeBar() -> NSTouchBar {
        bar
    }

    func update(cities: [CityState], inputEnabled: Bool = true) {
        for city in cities {
            let index = city.id - 1
            guard buttons.indices.contains(index) else { continue }
            let state = CityTouchButton.VisualState(city: city)
            buttons[index].update(
                name: city.name,
                densityMark: city.density.rawValue,
                state: state,
                enabled: inputEnabled && state.canNotify
            )
        }
    }

    @objc private func notify(_ sender: CityTouchButton) {
        guard sender.isEnabled else { return }
        onNotify(sender.cityID)
    }
}

private final class CityTouchRow: NSView {
    private let buttons: [CityTouchButton]
    private let spacing: CGFloat = 1
    private let groupSpacing: CGFloat = 2

    private var totalSpacing: CGFloat {
        let gapCount = buttons.count - 1
        let groupGapCount = gapCount / 4
        return CGFloat(gapCount - groupGapCount) * spacing + CGFloat(groupGapCount) * groupSpacing
    }

    init(buttons: [CityTouchButton]) {
        self.buttons = buttons
        super.init(frame: .zero)
        for button in buttons {
            addSubview(button)
        }

        // 让 AppKit 可以分配更宽的容器，也允许面板变窄时压缩单键。
        setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        let minimum = widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(buttons.count) * 20 + totalSpacing)
        minimum.priority = .defaultHigh
        minimum.isActive = true
    }

    required init?(coder: NSCoder) { nil }

    // 宽松的理想尺寸供 AppKit 排布，实际可用宽度仍由系统控制区决定。
    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(buttons.count) * 68 + totalSpacing, height: 30)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = newSize != frame.size
        super.setFrameSize(newSize)
        if sizeChanged {
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let minimumWidth = CGFloat(buttons.count) * 20 + totalSpacing
        let spacingScale = min(1, bounds.width / minimumWidth)
        let buttonWidth = (bounds.width - totalSpacing * spacingScale) / CGFloat(buttons.count)
        var x = bounds.minX

        // 除组间细缝外，整个容器均为可触区域。每四键对应主画面的一行。
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: x, y: bounds.minY, width: buttonWidth, height: bounds.height)
            let gap = (index + 1).isMultiple(of: 4) ? groupSpacing : spacing
            x += buttonWidth + gap * spacingScale
        }
    }
}

private final class CityTouchButton: NSButton {
    enum VisualState: Equatable {
        case normal, yellow, orange, notified, raiding, struck

        init(city: CityState) {
            guard let warning = city.warning else {
                // 损毁会跨波累计，当前空袭（含落弹后的收尾）以 raid 是否存在为准。
                if city.raid != nil {
                    self = .raiding
                } else {
                    self = city.damage > 0 ? .struck : .normal
                }
                return
            }
            if city.notified {
                self = .notified
                return
            }
            switch warning {
            case .yellow: self = .yellow
            case .orange: self = .orange
            }
        }

        var canNotify: Bool { self == .yellow || self == .orange }

        var accessibilityStatus: String {
            switch self {
            case .normal: return "暂无预警"
            case .yellow: return "黄色预警"
            case .orange: return "橙色预警"
            case .notified: return "已发送疏散通知"
            case .raiding: return "空袭中"
            case .struck: return "已受击"
            }
        }

        var background: NSColor {
            switch self {
            case .normal: return NSColor(white: 0.17, alpha: 1)
            case .yellow: return NSColor(red: 0.96, green: 0.78, blue: 0.33, alpha: 1)
            case .orange: return NSColor(red: 0.96, green: 0.56, blue: 0.32, alpha: 1)
            case .notified: return NSColor(red: 0.38, green: 0.78, blue: 0.64, alpha: 1)
            case .raiding: return NSColor(red: 0.97, green: 0.44, blue: 0.42, alpha: 1)
            case .struck: return NSColor(white: 0.11, alpha: 1)
            }
        }
    }

    let cityID: Int
    private var visualState = VisualState.normal
    private var densityMark = ""

    init(cityID: Int) {
        self.cityID = cityID
        super.init(frame: .zero)
        title = ""
        font = .systemFont(ofSize: 12, weight: .semibold)
        setButtonType(.momentaryPushIn)
        isBordered = false
        isEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    func update(name: String, densityMark: String, state: VisualState, enabled: Bool) {
        guard title != name || self.densityMark != densityMark || visualState != state || isEnabled != enabled else { return }
        title = name
        self.densityMark = densityMark
        visualState = state
        isEnabled = enabled
        setAccessibilityLabel("\(name)，\(densityMark)密度，\(state.accessibilityStatus)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var fillColor = visualState.background
        if cell?.isHighlighted == true {
            fillColor = fillColor.blended(withFraction: 0.25, of: .white) ?? fillColor
        }
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()

        let quiet = visualState == .normal || visualState == .struck
        let availableWidth = bounds.width - 3
        guard availableWidth > 0, !title.isEmpty else { return }
        let labelFont = font ?? NSFont.systemFont(ofSize: 12, weight: .semibold)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: quiet ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        ]
        let label = title as NSString
        var size = label.size(withAttributes: attributes)
        if size.width > availableWidth {
            // 极窄的系统布局下保留完整双字镇名。
            let pointSize = max(1, labelFont.pointSize * availableWidth / size.width)
            attributes[.font] = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
            size = label.size(withAttributes: attributes)
        }

        // 名称和单字密度标记分行居中，让两字城名在窄键上也能完整显示。
        let densityLabel = densityMark as NSString
        let densityAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor(white: quiet ? 0.62 : 0.17, alpha: 1)
        ]
        let densitySize = densityLabel.size(withAttributes: densityAttributes)
        let lineSpacing: CGFloat = 1
        let minY = bounds.midY - (size.height + lineSpacing + densitySize.height) / 2
        let nameY = isFlipped ? minY : minY + densitySize.height + lineSpacing
        let densityY = isFlipped ? minY + size.height + lineSpacing : minY
        label.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: nameY),
            withAttributes: attributes
        )
        densityLabel.draw(
            at: NSPoint(x: bounds.midX - densitySize.width / 2, y: densityY),
            withAttributes: densityAttributes
        )
    }
}
