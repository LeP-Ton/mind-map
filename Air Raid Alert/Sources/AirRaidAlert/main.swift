import AppKit

private final class GameWindow: NSWindow {
    private let controls: TouchBarController
    private let testInputEnabled: Bool
    var onTestKey: ((UInt16) -> Bool)?

    init(view: GameView, controls: TouchBarController, testInputEnabled: Bool) {
        self.controls = controls
        self.testInputEnabled = testInputEnabled
        let display = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let size = NSSize(width: min(1440, display.width - 48), height: min(940, display.height - 52))
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "躲避空袭"
        contentMinSize = NSSize(width: 920, height: 600)
        contentView = view
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        center()
    }

    override func makeTouchBar() -> NSTouchBar? {
        controls.makeBar()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if testInputEnabled, modifiers.isEmpty, !event.isARepeat, onTestKey?(event.keyCode) == true {
            return
        }
        super.keyDown(with: event)
    }
}

private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let simulation = Simulation(scheduleSeed: UInt64.random(in: .min ... .max))
    private let siren = AirRaidSiren()
    private var gameView: GameView?
    private var window: GameWindow?
    private var touchBar: TouchBarController?
    private var refreshTimer: Timer?
    private var lastFrame = ProcessInfo.processInfo.systemUptime

    // 测试键按实体键位映射成四行，方便没有触控条的机器验证通知与疏散。
    private let testKeyCodes: [UInt16] = [18, 19, 20, 21, 12, 13, 14, 15, 0, 1, 2, 3, 6, 7, 8, 9]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = GameView(simulation: simulation)
        let touchBar = TouchBarController { [weak self] cityID in
            self?.notify(cityID: cityID)
        }
        let gameWindow = GameWindow(
            view: view,
            controls: touchBar,
            testInputEnabled: CommandLine.arguments.contains("--test-input")
        )
        view.onTogglePause = { [weak self] in self?.togglePause() }
        view.onRestart = { [weak self] in self?.restartRound() }
        gameWindow.onTestKey = { [weak self] code in self?.handleTestKey(code) ?? false }
        gameView = view
        window = gameWindow
        self.touchBar = touchBar

        setUpMenu()
        refresh()
        gameWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        lastFrame = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        siren.stop()
    }

    private func setUpMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出躲避空袭", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastFrame = now }
        guard !simulation.isPaused, !simulation.isFinished else { return }
        // 唤醒或窗口短暂卡顿时限制单帧追赶，避免界面上整段预警突然消失。
        simulation.advance(by: min(now - lastFrame, 0.25))
        refresh()
    }

    private func refresh() {
        gameView?.needsDisplay = true
        touchBar?.update(cities: simulation.cities, inputEnabled: !simulation.isPaused && !simulation.isFinished)
    }

    private func notify(cityID: Int) {
        guard simulation.notify(cityID: cityID) else { return }
        refresh()
        siren.play()
    }

    private func togglePause() {
        guard !simulation.isFinished else { return }
        simulation.togglePause()
        if simulation.isPaused {
            siren.pause()
        } else {
            siren.resume()
        }
        lastFrame = ProcessInfo.processInfo.systemUptime
        refresh()
    }

    private func restartRound() {
        siren.stop()
        simulation.reset()
        lastFrame = ProcessInfo.processInfo.systemUptime
        refresh()
    }

    private func handleTestKey(_ code: UInt16) -> Bool {
        if let index = testKeyCodes.firstIndex(of: code) {
            notify(cityID: index + 1)
        } else if code == 49 {
            togglePause()
        } else if code == 36, simulation.isFinished {
            restartRound()
        } else {
            return false
        }
        return true
    }
}

let app = NSApplication.shared
private let appDelegate = ApplicationDelegate()
app.setActivationPolicy(.regular)
app.delegate = appDelegate
app.run()
