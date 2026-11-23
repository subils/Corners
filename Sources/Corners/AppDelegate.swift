import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private var overlays: [Overlay] = []
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 40, target: nil, action: nil)
    private let radiusLabel = NSMenuItem()
    private let matchItem = NSMenuItem(title: "Match Display Corners", action: #selector(toggleMatch), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    // Settings live in UserDefaults; reads are served from the in-process cache.
    private var matchDisplay: Bool {
        get { defaults.bool(forKey: "matchDisplay") }
        set { defaults.set(newValue, forKey: "matchDisplay") }
    }
    private var radius: Double {  // manual radius, used when not matching the display
        get { defaults.double(forKey: "radius") }
        set { defaults.set(newValue, forKey: "radius") }
    }
    private var corners: CACornerMask {
        get { CACornerMask(rawValue: UInt(defaults.integer(forKey: "corners"))) }
        set { defaults.set(Int(newValue.rawValue), forKey: "corners") }
    }
    private var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["matchDisplay": true, "radius": 20.0, "corners": 15, "enabled": true])
        enableLaunchAtLoginOnce()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "app", accessibilityDescription: "Corners")
        item.menu = makeMenu()
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        apply()
    }

    private static let allCorners: [CACornerMask] = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner,
                                                     .layerMinXMinYCorner, .layerMaxXMinYCorner]

    /// Syncs four corner windows per screen with the current settings, reusing existing windows.
    /// Matching: each screen uses its own hardware corners, else the built-in panel's (so an
    /// external monitor looks like the laptop), else the manual radius.
    @objc private func apply() {
        let screens = NSScreen.screens, c = corners, manual = CGFloat(radius)
        let count = screens.count * 4  // windows are ordered [screen 0: TL TR BL BR, screen 1: …]
        while overlays.count > count { overlays.removeLast().close() }
        var radii = screens.map { _ in manual }
        if matchDisplay {
            let hardware = screens.map(\.hardwareCornerRadius)
            let fallback = hardware.max().flatMap { $0 > 0 ? $0 : nil } ?? manual
            radii = hardware.map { $0 > 0 ? $0 : fallback }
        }
        updateRadiusControls(radii.first ?? manual)
        guard enabled, !c.isEmpty, radii.contains(where: { $0 > 0 }) else {
            overlays.forEach { $0.orderOut(nil) }
            return
        }
        while overlays.count < count { overlays.append(Overlay(corner: Self.allCorners[overlays.count % 4])) }
        for (i, overlay) in overlays.enumerated() {
            let r = radii[i / 4]
            if r > 0, c.contains(overlay.corner) { overlay.show(on: screens[i / 4], radius: r) } else { overlay.orderOut(nil) }
        }
    }

    /// Displays settle in several steps; coalesce bursts into a single rebuild.
    @objc private func screensChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(apply), object: nil)
        perform(#selector(apply), with: nil, afterDelay: 0.2)
    }

    /// Turns on Launch at Login the first time the app runs from /Applications. After that the
    /// user's choice (menu or System Settings) is respected.
    private func enableLaunchAtLoginOnce() {
        guard !defaults.bool(forKey: "loginConfigured"), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        try? SMAppService.mainApp.register()
        defaults.set(true, forKey: "loginConfigured")
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        matchItem.target = self
        menu.addItem(matchItem)
        radiusLabel.isEnabled = false
        menu.addItem(radiusLabel)

        slider.target = self
        slider.action = #selector(radiusChanged)
        slider.frame = NSRect(x: 28, y: 2, width: 178, height: 24)  // aligned with item titles
        let sliderView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        sliderView.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = sliderView
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        let names: [(String, CACornerMask)] = [("Top Left", .layerMinXMaxYCorner), ("Top Right", .layerMaxXMaxYCorner),
                                               ("Bottom Left", .layerMinXMinYCorner), ("Bottom Right", .layerMaxXMinYCorner)]
        for (title, corner) in names {
            let item = addItem(to: menu, title, #selector(toggleCorner))
            item.tag = Int(corner.rawValue)
            item.state = corners.contains(corner) ? .on : .off
        }
        menu.addItem(.separator())
        addItem(to: menu, "Enabled", #selector(toggleEnabled)).state = enabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Corners", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateRadiusControls(_ shown: CGFloat) {
        matchItem.state = matchDisplay ? .on : .off
        radiusLabel.title = String(format: "Radius: %.1f pt", shown)
        slider.doubleValue = shown
    }

    // Login-item state is owned by the system (the user can change it in System Settings).
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleMatch() {
        matchDisplay.toggle()
        apply()
    }

    @objc private func radiusChanged(_ slider: NSSlider) {
        let value = slider.doubleValue.rounded()  // whole points; skip drag events that don't change it
        guard matchDisplay || value != radius else { return }
        matchDisplay = false  // dragging the slider takes manual control
        radius = value
        apply()
    }

    @objc private func toggleCorner(_ item: NSMenuItem) {
        corners.formSymmetricDifference(CACornerMask(rawValue: UInt(item.tag)))
        item.state = item.state == .on ? .off : .on
        apply()
    }

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        enabled.toggle()
        item.state = enabled ? .on : .off
        apply()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }
}
