import AppKit
import Carbon

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [], _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = SlideOverController()
    private var signalSources: [DispatchSourceSignal] = []
    private let swipeTap = SwipeTap()
    private let setup = SetupWindowController()
    private let shortcutsWindow = ShortcutsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled",
                               accessibilityDescription: "SlideOver") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "▐"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.recoverOrphanedWindows()

        // Hold ⌃⌥ + two-finger swipe left/right: move through the Slide Over windows.
        // ⌃⌥ + swipe up: show all Slide Over windows.
        swipeTap.isEnabled = { [weak self] in
            guard let c = self?.controller else { return false }
            return !c.items.isEmpty && !c.isSwitcherOpen
        }
        swipeTap.onStep = { [weak self] step in self?.controller.cycle(step) }
        swipeTap.onUp = { [weak self] in self?.controller.showOverview() }
        swipeTap.onShortcut = { [weak self] action in self?.perform(action) }
        shortcutsWindow.onRecordingChanged = { [weak self] recording in self?.swipeTap.suspended = recording }
        swipeTap.start()

        // `pkill SlideOver` (used by build.sh) and Ctrl-C should clean up like a normal quit.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        // First launch, or Accessibility missing: show the setup window instead of bare system prompts.
        setup.onAccessibilityGranted = { [weak self] in self?.swipeTap.start() }
        let firstLaunch = !UserDefaults.standard.bool(forKey: "setupShown")
        if firstLaunch || !AX.isTrusted {
            UserDefaults.standard.set(true, forKey: "setupShown")
            setup.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.restoreAll()
    }

    /// Runs the action behind a keyboard shortcut.
    private func perform(_ action: ShortcutAction) {
        let c = controller
        switch action {
        case .addRight: c.addFrontmostWindow(to: .right)
        case .addLeft: c.addFrontmostWindow(to: .left)
        case .add: c.addFrontmostWindow()
        case .toggle, .toggle2: c.toggle()
        case .next, .previous:
            c.switcherHoldFlags = ShortcutStore.shared.shortcut(for: action)?.holdFlags ?? []
            if action == .next { c.next() } else { c.previous() }
        case .overview: c.toggleOverview()
        case .remove: c.removeCurrent()
        }
    }

    /// Menu title with the action's current shortcut after it.
    private func menuTitle(_ title: String, _ action: ShortcutAction) -> String {
        guard let s = ShortcutStore.shared.shortcut(for: action) else { return title }
        return "\(title)     \(s.display)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        swipeTap.start()   // no-op once running; picks up a freshly granted Accessibility permission
        let c = controller

        if !AX.isTrusted {
            menu.addItem(ActionItem("⚠︎ Grant Accessibility access…") {
                AX.requestTrust()
                Self.openSettings("Privacy_Accessibility")
            })
        }
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(ActionItem("⚠︎ Grant Screen Recording (floating mirror)…") {
                CGRequestScreenCaptureAccess()
                Self.openSettings("Privacy_ScreenCapture")
            })
        }
        if menu.items.count > 0 { menu.addItem(.separator()) }

        menu.addItem(ActionItem(menuTitle("Add Front Window to Slide Over", .add)) { c.addFrontmostWindow() })
        menu.addItem(ActionItem(menuTitle(c.isShown ? "Hide Slide Over" : "Show Slide Over", .toggle)) { c.toggle() })
        menu.addItem(ActionItem(menuTitle("Next Slide Over Window", .next)) { c.next() })
        menu.addItem(ActionItem(menuTitle("Previous Slide Over Window", .previous)) { c.previous() })
        menu.addItem(ActionItem(menuTitle("Show All Slide Over Windows", .overview)) { c.toggleOverview() })
        menu.addItem(ActionItem(menuTitle("Remove Current Window", .remove)) { c.removeCurrent() })

        if !c.items.isEmpty {
            menu.addItem(.separator())
            for item in c.items {
                let mi = ActionItem(item.title) { c.show(item) }
                if let icon = item.icon?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    mi.image = icon
                }
                mi.state = item === c.current ? .on : .off
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())

        let sideMenu = NSMenu()
        for s in [Side.left, Side.right] {
            let mi = ActionItem(s == .left ? "Left" : "Right") { c.side = s }
            mi.state = c.side == s ? .on : .off
            sideMenu.addItem(mi)
        }
        let sideItem = NSMenuItem(title: "Side", action: nil, keyEquivalent: "")
        sideItem.submenu = sideMenu
        menu.addItem(sideItem)

        let widthMenu = NSMenu()
        for (name, w) in [("Narrow", 440.0), ("Regular", 560.0), ("Wide", 680.0), ("Extra Wide", 820.0)] {
            let mi = ActionItem("\(name) (\(Int(w)) pt)") { c.width = CGFloat(w) }
            mi.state = abs(c.width - CGFloat(w)) < 1 ? .on : .off
            widthMenu.addItem(mi)
        }
        let widthItem = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        widthItem.submenu = widthMenu
        menu.addItem(widthItem)

        let hover = ActionItem("Slide In When Pointer Hits Edge") { c.edgeHoverEnabled.toggle() }
        hover.state = c.edgeHoverEnabled ? .on : .off
        menu.addItem(hover)

        let desktops = ActionItem("Keep Slide Over Apps on All Desktops") { c.allDesktopsEnabled.toggle() }
        desktops.state = c.allDesktopsEnabled ? .on : .off
        menu.addItem(desktops)

        let live = ActionItem("Live Floating Preview (shows recording indicator)") { c.liveMirror.toggle() }
        live.state = c.liveMirror ? .on : .off
        menu.addItem(live)

        let login = ActionItem("Launch at Login") { LoginItem.set(!LoginItem.isEnabled) }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(ActionItem("Keyboard Shortcuts…") { [weak self] in self?.shortcutsWindow.show() })
        menu.addItem(ActionItem("Setup…") { [weak self] in self?.setup.show() })
        if Support.url != nil {
            menu.addItem(ActionItem("☕ Buy Me a Coffee…") { Support.open() })
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit SlideOver (restores windows)", key: "q", mods: .command) {
            NSApp.terminate(nil)
        })
    }

    private static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
