import AppKit
import QuartzCore

enum Side: String {
    case left, right
}

/// One window that has been put into Slide Over.
final class SlideItem {
    let pid: pid_t
    let bundleID: String?
    let window: AXUIElement
    let windowID: CGWindowID
    let appName: String
    let icon: NSImage?
    let originalFrame: CGRect
    /// Size the user resized this window to while it was in Slide Over.
    var savedSize: CGSize?
    /// How far below the top of the screen's usable area the user placed the window.
    var savedTopOffset: CGFloat?
    /// Fixed place in the swipe order (the order the windows were added in).
    var order = 0

    init(pid: pid_t, bundleID: String?, window: AXUIElement, windowID: CGWindowID, appName: String, icon: NSImage?, originalFrame: CGRect) {
        self.pid = pid
        self.bundleID = bundleID
        self.window = window
        self.windowID = windowID
        self.appName = appName
        self.icon = icon
        self.originalFrame = originalFrame
    }

    var title: String {
        if let t = AX.title(window), !t.isEmpty { return "\(appName) — \(t)" }
        return appName
    }
}

/// Drives AX window positions with an ease-out curve at 60 fps.
/// One animation per window, so two windows can move at once (swap animation).
final class Animator {
    private var timers: [CGWindowID: Timer] = [:]

    func animate(id: CGWindowID, from: CGPoint, to: CGPoint, duration: Double = 0.26,
                 step: @escaping (CGPoint) -> Void, completion: (() -> Void)? = nil) {
        timers[id]?.invalidate()
        let start = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            let e = 1 - pow(1 - p, 3)
            step(CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e))
            if p >= 1 {
                timer.invalidate()
                self?.timers[id] = nil
                completion?()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timers[id] = t
    }
}

final class SlideOverController {
    private(set) var items: [SlideItem] = []
    private(set) var current: SlideItem?
    private(set) var isShown = false
    var onChange: (() -> Void)?

    var side: Side = Side(rawValue: UserDefaults.standard.string(forKey: "side") ?? "") ?? .right {
        didSet {
            UserDefaults.standard.set(side.rawValue, forKey: "side")
            if side != oldValue { reparkHiddenItems() }
            relayout()
        }
    }

    var width: CGFloat = {
        let w = UserDefaults.standard.double(forKey: "width")
        return w > 0 ? CGFloat(w) : 560
    }() {
        didSet {
            UserDefaults.standard.set(Double(width), forKey: "width")
            // Picking a width from the menu overrides sizes set by hand.
            for item in items { item.savedSize = nil }
            relayout()
        }
    }

    /// Live floating preview (continuous capture → macOS shows its screen-recording indicator).
    var liveMirror: Bool {
        get { mirror.liveMode }
        set {
            mirror.liveMode = newValue
            UserDefaults.standard.set(newValue, forKey: "liveMirror")
        }
    }

    var edgeHoverEnabled: Bool = UserDefaults.standard.object(forKey: "edgeHover") as? Bool ?? true {
        didSet { UserDefaults.standard.set(edgeHoverEnabled, forKey: "edgeHover") }
    }

    private let margin: CGFloat = 10
    private let topMargin: CGFloat = 22   // leaves room for the grabber handle
    private let animator = Animator()
    private let pullTab = PullTab()
    private let handle = Handle()
    private let mirror = MirrorPanel()
    private let switcher = SwitcherPanel()
    private var switcherOrder: [SlideItem] = []
    private var switcherIndex = 0
    private var switcherActive = false
    private var switcherVisible = false
    private var switcherSticky = false
    private var modifierPoll: Timer?
    private var outsideClickMonitor: Any?
    private var thumbnails: [CGWindowID: CGImage] = [:]
    private var lastOtherPID: pid_t?
    private var shownScreen: NSScreen?
    private var edgeTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private let myPID = ProcessInfo.processInfo.processIdentifier

    init() {
        pullTab.view.onClick = { [weak self] in self?.showCurrent() }
        handle.view.onClick = { [weak self] in self?.hide() }
        handle.view.onDragEnd = { [weak self] dx in self?.handleDragged(dx) }
        mirror.view.onClick = { [weak self] in self?.focusCurrent() }
        mirror.view.onScroll = { [weak self] _ in self?.focusCurrent() }
        switcher.onPick = { [weak self] i in self?.commitSwitcher(pick: i) }
        switcher.onSelect = { [weak self] i in self?.switcherIndex = i }
        switcher.onRemove = { [weak self] i in self?.removeFromSwitcher(i) }
        switcher.onCancel = { [weak self] in self?.cancelSwitcher() }

        let wsCenter = NSWorkspace.shared.notificationCenter
        observers.append(wsCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                              object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.appActivated(app)
            }
        })
        observers.append(wsCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        })
        observers.append(wsCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                              object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.appTerminated(app)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        })
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.mouseMoved()
        }
        // Only with the debug log switched on: record pointer / touch events (no keystrokes).
        var logged = 0
        debugMonitor = !Log.enabled ? nil : NSEvent.addGlobalMonitorForEvents(matching: .any) { [weak self] e in
            guard logged < 600 else { return }
            let t = e.type
            if t == .keyDown || t == .keyUp || t == .flagsChanged || t == .scrollWheel { return }
            let m = NSEvent.mouseLocation
            if t == .mouseMoved && m.x > 120 { return }
            logged += 1
            let sub = e.cgEvent?.getIntegerValueField(.mouseEventSubtype) ?? -1
            Log.write("evt type=\(t.rawValue) x=\(Int(m.x)) y=\(Int(m.y)) sub=\(sub) side=\(self?.side.rawValue ?? "?")")
        }
        touchMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.edgeSwipeEvent(e)
        }
    }

    // MARK: - Public actions

    /// Takes the focused window of the frontmost app and turns it into a Slide Over window.
    func addFrontmostWindow() {
        guard AX.isTrusted else { AX.requestTrust(); return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != myPID,
              let window = AX.focusedWindow(pid: app.processIdentifier),
              let id = AX.windowID(window),
              let frame = AX.frame(window)
        else { NSSound.beep(); return }

        if let existing = items.first(where: { $0.windowID == id }) {
            show(existing)
            return
        }
        let item = SlideItem(pid: app.processIdentifier, bundleID: app.bundleIdentifier, window: window, windowID: id,
                             appName: app.localizedName ?? "App", icon: app.icon,
                             originalFrame: Self.safeFrame(frame))
        item.order = nextOrder
        nextOrder += 1
        items.append(item)
        persistItems()
        show(item)

        if allDesktopsEnabled {
            // Let the slide-in finish, then put the app on all desktops via its Dock menu.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { AllDesktops.assign(app) }
        }
    }

    /// Puts the front window into Slide Over on the given side; the whole Slide Over
    /// (all its windows) moves to that side if it was on the other one.
    func addFrontmostWindow(to newSide: Side) {
        if side != newSide { side = newSide }
        addFrontmostWindow()
    }

    /// After a side change: hidden windows wait just off the new edge instead of the old one.
    private func reparkHiddenItems() {
        let screen = shownScreen ?? ScreenGeo.screenWithMouse()
        for item in items where !(isShown && item === current) {
            guard let f = AX.frame(item.window) else { continue }
            AX.setPosition(item.window, restingSpot(for: item, frame: f, on: screen))
        }
    }

    func toggle() {
        if isShown { hide() } else { showCurrent() }
    }

    func showCurrent() {
        guard let item = current ?? items.first else { NSSound.beep(); return }
        show(item)
    }

    // MARK: - Rotation & switcher
    //
    // Windows are kept in most-recently-used order (items[0] = current), like ⌘Tab:
    //  • tap ⌃⌥N            → animated swap to the previously used window
    //  • hold ⌃⌥, tap N / P → card carousel appears, N/P (or a trackpad swipe) rotates,
    //                         releasing ⌃⌥ opens the highlighted window
    //  • ⌃⌥W                → carousel stays open; click a card to open it

    func next() { rotate(1) }
    func previous() { rotate(-1) }

    func rotate(_ step: Int) {
        pruneDeadItems()
        guard !items.isEmpty else { NSSound.beep(); return }
        if items.count == 1 {
            if !isShown { show(items[0]) }
            return
        }
        if !switcherActive {
            beginSwitcher(sticky: false)
            // Only show the carousel if the keys are still held a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self, self.switcherActive, !self.switcherVisible else { return }
                self.presentSwitcher()
            }
        }
        stepSwitcher(step)
    }

    private var nextOrder = 0
    /// Modifier keys of the shortcut that started the switcher; releasing them picks the window.
    var switcherHoldFlags: NSEvent.ModifierFlags = []
    var isSwitcherOpen: Bool { switcherActive }

    /// Trackpad swipe: go straight to the next / previous window, no switcher.
    /// Uses a fixed order (the order the windows were added), so swiping one way
    /// repeatedly walks through all of them and wraps around.
    func cycle(_ step: Int) {
        pruneDeadItems()
        guard !items.isEmpty else { NSSound.beep(); return }
        if switcherActive { cancelSwitcher() }
        let ring = items.sorted { $0.order < $1.order }
        guard isShown, let cur = current, let idx = ring.firstIndex(where: { $0 === cur }) else {
            showCurrent()   // Slide Over is hidden: the swipe just brings it back
            return
        }
        guard ring.count > 1 else { return }
        let n = ring.count
        show(ring[((idx + step) % n + n) % n], animated: true, animatePrevious: true)
    }

    func showOverview() {
        if !switcherActive { toggleOverview() }
    }

    func toggleOverview() {
        if switcherActive { commitSwitcher(); return }
        pruneDeadItems()
        guard !items.isEmpty else { NSSound.beep(); return }
        beginSwitcher(sticky: true)
        presentSwitcher()
    }

    private func beginSwitcher(sticky: Bool) {
        switcherActive = true
        switcherSticky = sticky
        switcherOrder = items
        switcherIndex = 0
        if !sticky {
            // Commit as soon as ⌃ or ⌥ is released (polling works without extra permissions).
            let t = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                guard let self else { return }
                let hold = self.switcherHoldFlags
                if hold.isEmpty || !NSEvent.modifierFlags.isSuperset(of: hold) {
                    self.commitSwitcher()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            modifierPoll = t
        }
    }

    private func stepSwitcher(_ step: Int) {
        let n = switcherOrder.count
        guard switcherActive, n > 0 else { return }
        switcherIndex = ((switcherIndex + step) % n + n) % n
        if switcherVisible { switcher.select(switcherIndex) }
    }

    private func presentSwitcher() {
        switcherVisible = true
        let screen = isShown ? (shownScreen ?? ScreenGeo.screenWithMouse()) : ScreenGeo.screenWithMouse()
        let fallback = CGSize(width: width, height: screen.visibleFrame.height * 0.8)
        let sizes = switcherOrder.map { AX.frame($0.window)?.size ?? $0.savedSize ?? fallback }

        // The switcher lives in the Slide Over area (the open window's spot, or where it would open).
        var area = slotFrame(on: screen)
        if isShown, let cur = current, let f = AX.frame(cur.window) { area = f }

        switcher.present(axFrame: area,
                         titles: switcherOrder.map { $0.appName },
                         icons: switcherOrder.map { $0.icon },
                         images: switcherOrder.map { thumbnails[$0.windowID] },
                         sizes: sizes,
                         selected: switcherIndex)

        // Hidden apps can't be photographed; their cards keep the picture taken when they were hidden.
        let visibleIDs = switcherOrder
            .filter { NSRunningApplication(processIdentifier: $0.pid)?.isHidden != true }
            .map { $0.windowID }
        Thumbnailer.capture(windowIDs: visibleIDs, maxWidth: 700) { [weak self] id, image in
            guard let self else { return }
            self.thumbnails[id] = image
            if self.switcherVisible, let i = self.switcherOrder.firstIndex(where: { $0.windowID == id }) {
                self.switcher.setImage(image, at: i)
            }
        }

        if switcherSticky {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.cancelSwitcher()
            }
        }
    }

    private func endSwitcherState() {
        modifierPoll?.invalidate()
        modifierPoll = nil
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        switcherActive = false
    }

    private func commitSwitcher(pick: Int? = nil) {
        guard switcherActive, !switcherOrder.isEmpty else { return }
        if let pick, pick >= 0, pick < switcherOrder.count { switcherIndex = pick }
        let target = switcherOrder[switcherIndex]
        let wasVisible = switcherVisible
        endSwitcherState()
        switcherVisible = false

        guard AX.isAlive(target.window) else {
            switcher.dismiss()
            remove(target, restore: false)
            return
        }

        if wasVisible {
            // The carousel covers the slot: place the window instantly, then fade the cards away.
            if target === current && isShown { focusCurrent() } else { show(target, animated: false) }
            switcher.dismiss()
        } else {
            // Quick tap: the old window slides out while the new one slides in.
            show(target, animated: true, animatePrevious: true)
        }
    }

    /// A card was swiped up in the switcher: take that window out of Slide Over.
    private func removeFromSwitcher(_ index: Int) {
        guard switcherActive, index < switcherOrder.count else { return }
        let item = switcherOrder.remove(at: index)
        remove(item, restore: true, focus: false)
        if switcherOrder.isEmpty {
            cancelSwitcher()
        } else {
            switcher.dropCard(at: index)
        }
    }

    private func cancelSwitcher() {
        guard switcherActive else { return }
        endSwitcherState()
        switcherVisible = false
        switcher.dismiss()
    }

    private func pruneDeadItems() {
        for item in items where !AX.isAlive(item.window) {
            remove(item, restore: false)
        }
    }

    func removeCurrent() {
        if let c = current { remove(c) }
    }

    /// Takes a window out of Slide Over and puts it back where it was.
    func remove(_ item: SlideItem, restore: Bool = true, focus: Bool = true) {
        if current === item && isShown {
            isShown = false
            mirror.stopCapture()
            handle.orderOut(nil)
        }
        if restore && AX.isAlive(item.window) {
            NSRunningApplication(processIdentifier: item.pid)?.unhide()
            AX.setFrame(item.window, item.originalFrame)
            if focus { AX.focus(pid: item.pid, window: item.window) }
        }
        items.removeAll { $0 === item }
        persistItems()
        if current === item { current = items.first }
        // You removed the app's last Slide Over window → give the app its old desktop assignment back.
        // (Not when the app just quit or its window closed: the assignment should survive a relaunch.)
        if restore, let bundle = item.bundleID, !items.contains(where: { $0.bundleID == bundle }) {
            AllDesktops.restore(bundleID: bundle)
        }
        refreshPullTab()
        onChange?()
    }

    /// Assign every Slide Over app to All Desktops (Dock → Options → Assign To → All Desktops).
    var allDesktopsEnabled: Bool = UserDefaults.standard.object(forKey: "allDesktops") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(allDesktopsEnabled, forKey: "allDesktops")
            for bundle in Set(items.compactMap { $0.bundleID }) {
                if allDesktopsEnabled {
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                        AllDesktops.assign(app)
                    }
                } else {
                    AllDesktops.restore(bundleID: bundle)
                }
            }
        }
    }

    func restoreAll() {
        cancelSwitcher()
        for item in items where AX.isAlive(item.window) {
            NSRunningApplication(processIdentifier: item.pid)?.unhide()
            AX.setFrame(item.window, item.originalFrame)
        }
        for bundle in Set(items.compactMap { $0.bundleID }) {
            AllDesktops.restore(bundleID: bundle, wait: true)
        }
        items.removeAll()
        persistItems()
        current = nil
        isShown = false
        mirror.stopCapture()
        handle.orderOut(nil)
        pullTab.orderOut(nil)
        onChange?()
    }

    // MARK: - Crash / kill safety

    /// A frame that is guaranteed to be reachable: if `f` is (almost) off every screen,
    /// it is centred on the main screen instead.
    static func safeFrame(_ f: CGRect) -> CGRect {
        for s in NSScreen.screens {
            let vf = ScreenGeo.toAX(s.visibleFrame)
            let i = vf.intersection(f)
            if !i.isNull && i.width >= min(200, f.width) && i.height >= min(100, f.height) { return f }
        }
        let vf = ScreenGeo.toAX((NSScreen.main ?? NSScreen.screens[0]).visibleFrame)
        let w = min(f.width, vf.width - 40)
        let h = min(f.height, vf.height - 40)
        return CGRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)
    }

    /// Keeps a list of the Slide Over windows on disk, so they can be rescued at the next
    /// launch if SlideOver crashed or was killed while they were parked off-screen.
    private func persistItems() {
        let list: [[String: Double]] = items.map {
            ["pid": Double($0.pid), "id": Double($0.windowID),
             "x": Double($0.originalFrame.minX), "y": Double($0.originalFrame.minY),
             "w": Double($0.originalFrame.width), "h": Double($0.originalFrame.height)]
        }
        UserDefaults.standard.set(list, forKey: "slideOverWindows")
    }

    /// Called at launch: puts windows left behind by a previous run back on screen.
    func recoverOrphanedWindows() {
        guard AX.isTrusted,
              let list = UserDefaults.standard.array(forKey: "slideOverWindows") as? [[String: Double]]
        else { return }
        for entry in list {
            guard let pid = entry["pid"], let id = entry["id"],
                  let x = entry["x"], let y = entry["y"], let w = entry["w"], let h = entry["h"],
                  let windows = AX.attribute(AX.app(pid_t(pid)), kAXWindowsAttribute) as? [AXUIElement],
                  let window = windows.first(where: { AX.windowID($0) == CGWindowID(id) })
            else { continue }
            NSRunningApplication(processIdentifier: pid_t(pid))?.unhide()
            AX.unminimize(window)
            AX.setFrame(window, Self.safeFrame(CGRect(x: x, y: y, width: w, height: h)))
        }
        UserDefaults.standard.removeObject(forKey: "slideOverWindows")
    }

    // MARK: - Show / hide

    func show(_ item: SlideItem, animated: Bool = true, animatePrevious: Bool = false) {
        guard AX.isAlive(item.window) else { remove(item, restore: false); return }
        NSRunningApplication(processIdentifier: item.pid)?.unhide()   // parked apps may be hidden

        Log.write("show \(item.appName) id=\(item.windowID) onCurrentSpace=\(AX.isOnCurrentSpace(item.windowID)) minimized=\(AX.isMinimized(item.window)) frame=\(String(describing: AX.frame(item.window)))")

        if let cur = current, cur !== item, isShown {
            rememberSize(of: cur)
            park(cur, animated: animatePrevious)
        }
        current = item
        // Most-recently-used order: the shown window moves to the front.
        items.removeAll { $0 === item }
        items.insert(item, at: 0)
        let screen = ScreenGeo.screenWithMouse()
        shownScreen = screen
        var slot = slotFrame(on: screen)
        if let saved = item.savedSize { slot.size = saved }
        if let offset = item.savedTopOffset {
            slot.origin.y = ScreenGeo.toAX(screen.visibleFrame).minY + offset
        }

        AX.unminimize(item.window)
        let enhanced = AX.enhancedUI(pid: item.pid)
        if enhanced { AX.setEnhancedUI(pid: item.pid, false) }
        AX.setSize(item.window, slot.size)
        let current = AX.frame(item.window)
        // Many apps have a minimum width/height bigger than the slot. macOS keeps the window
        // at that minimum, so place it by its *real* size to keep it fully on screen.
        if let real = current?.size {
            slot = fitted(slot, realSize: real, on: screen)
        }
        let start = current?.origin ?? hiddenOrigin(on: screen, y: slot.minY, width: slot.width)

        isShown = true
        pullTab.orderOut(nil)
        mirror.stopCapture()
        handle.orderOut(nil)
        AX.focus(pid: item.pid, window: item.window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Log.write("after focus: onCurrentSpace=\(AX.isOnCurrentSpace(item.windowID)) frame=\(String(describing: AX.frame(item.window)))")
        }

        let finish = { [weak self] in
            guard let self else { return }
            if enhanced { AX.setEnhancedUI(pid: item.pid, true) }
            guard self.isShown, self.current === item else { return }
            let real = AX.frame(item.window) ?? slot
            self.handle.place(above: real)
            self.mirror.prepare(windowID: item.windowID, axFrame: real)
        }

        // Is the window currently parked off-screen (only a sliver visible)?
        let startRect = CGRect(origin: start, size: slot.size)
        let onScreenPart = startRect.intersection(ScreenGeo.toAX(screen.frame))
        let parked = onScreenPart.isNull || onScreenPart.width < 20 || onScreenPart.height < 20
        // Hidden windows wait below the screen corner, but they always slide in from the side.
        let sideOrigin = hiddenOrigin(on: screen, y: slot.minY, width: slot.width)

        if animated, parked, let image = thumbnails[item.windowID] {
            // Smooth path: slide the snapshot in, then drop the real window into place.
            // The real window first moves beside the screen at the right height, so its
            // final hop is sideways under the snapshot, not up from the bottom corner.
            AX.setPosition(item.window, sideOrigin)
            Ghost.slide(image: image, from: CGRect(origin: sideOrigin, size: slot.size), to: slot, on: screen) {
                AX.setPosition(item.window, slot.origin)
                finish()
            }
        } else if animated {
            if parked { AX.setPosition(item.window, sideOrigin) }
            animator.animate(id: item.windowID, from: parked ? sideOrigin : start, to: slot.origin,
                             step: { AX.setPosition(item.window, $0) },
                             completion: finish)
        } else {
            AX.setPosition(item.window, slot.origin)
            finish()
        }
        onChange?()
    }

    func hide(animated: Bool = true) {
        guard let cur = current, isShown else { return }
        rememberSize(of: cur)
        isShown = false
        mirror.stopCapture()
        handle.orderOut(nil)

        // Hiding hides Slide Over as a whole: every window goes away, and none of the other
        // Slide Over apps may pop in just because focus happens to land on it afterwards.
        let slidePIDs = Set(items.map { $0.pid })
        let wasFront = NSWorkspace.shared.frontmostApplication.map { slidePIDs.contains($0.processIdentifier) } ?? false
        park(cur, animated: animated)
        parkStragglers(except: cur)
        suppressAutoShowUntil = CACurrentMediaTime() + 1.0

        // Hand focus back to whatever you were working in, like on iPad.
        if wasFront {
            if let pid = regularAppToFocus(), let app = NSRunningApplication(processIdentifier: pid) {
                AXUIElementSetAttributeValue(AX.app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                app.activate(options: [])
            } else {
                // No other app has a window on this desktop. Take focus ourselves, otherwise
                // macOS picks an app on another desktop and jumps there.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        onChange?()
    }

    private var suppressAutoShowUntil: CFTimeInterval = 0

    /// Any other Slide Over window that is still (partly) on screen is moved off the edge too.
    private func parkStragglers(except cur: SlideItem) {
        let screen = shownScreen ?? ScreenGeo.screenWithMouse()
        let sf = ScreenGeo.toAX(screen.frame)
        for item in items where item !== cur {
            guard let f = AX.frame(item.window) else { continue }
            let visible = sf.intersection(f)
            if !visible.isNull && visible.width > 20 {
                AX.setPosition(item.window, restingSpot(for: item, frame: f, on: screen))
                hideAppIfIdle(item)
            }
        }
    }

    /// The app that should get focus when Slide Over hides. Only apps with a window on the
    /// desktop you're looking at qualify: focusing an app whose windows are on another desktop
    /// makes macOS jump to that desktop. Prefers the app you last worked in.
    private func regularAppToFocus() -> pid_t? {
        let slidePIDs = Set(items.map { $0.pid })
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var here: [pid_t] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != myPID, !slidePIDs.contains(pid), !here.contains(pid),
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            else { continue }
            here.append(pid)
        }
        if let pid = lastOtherPID, here.contains(pid) { return pid }
        return here.first
    }

    /// Slides a window off the screen edge (1px stays on screen so macOS doesn't pull it back).
    private func park(_ item: SlideItem, animated: Bool) {
        let screen = shownScreen ?? ScreenGeo.screenWithMouse()
        let frame = AX.frame(item.window) ?? slotFrame(on: screen)
        let target = hiddenOrigin(on: screen, y: frame.minY, width: frame.width)   // where it slides to
        let resting = restingSpot(for: item, frame: frame, on: screen)             // where it then waits
        let enhanced = AX.enhancedUI(pid: item.pid)
        if enhanced { AX.setEnhancedUI(pid: item.pid, false) }
        let done = { [weak self] in
            if enhanced { AX.setEnhancedUI(pid: item.pid, true) }
            self?.refreshPullTab()
            self?.hideAppIfIdle(item)
        }
        if animated {
            // Smooth path: snapshot the window, cover it with the snapshot, move the real
            // window off-screen in one jump, and let the snapshot glide out.
            Ghost.snapshot(windowID: item.windowID) { [weak self] image in
                guard let self else { return }
                if let image {
                    self.thumbnails[item.windowID] = image   // also used for the next slide-in
                    Ghost.slide(image: image, from: frame, to: CGRect(origin: target, size: frame.size), on: screen,
                                onShown: { AX.setPosition(item.window, resting) },
                                completion: done)
                } else {
                    self.animator.animate(id: item.windowID, from: frame.origin, to: target,
                                          step: { AX.setPosition(item.window, $0) },
                                          completion: {
                                              AX.setPosition(item.window, resting)
                                              done()
                                          })
                }
            }
        } else {
            AX.setPosition(item.window, resting)
            done()
        }
    }

    /// Switched desktops while Slide Over was open: stash it, so the next edge push / ⌃⌥S
    /// brings the window over to this desktop instead of jumping back.
    private func spaceChanged() {
        Log.write("space changed; isShown=\(isShown) current onCurrentSpace=\(current.map { AX.isOnCurrentSpace($0.windowID) } ?? false)")
        guard isShown, let cur = current else { return }
        if AX.isOnCurrentSpace(cur.windowID) { return }
        rememberSize(of: cur)
        isShown = false
        mirror.stopCapture()
        handle.orderOut(nil)
        refreshPullTab()
        onChange?()
    }

    /// Remembers size and vertical position, so the window comes back exactly where you left it.
    private func rememberSize(of item: SlideItem) {
        guard let f = AX.frame(item.window), f.width > 50, f.height > 50 else { return }
        item.savedSize = f.size
        let screen = shownScreen ?? ScreenGeo.screenWithMouse()
        let vf = ScreenGeo.toAX(screen.visibleFrame)
        // Only while it's actually on this screen (not parked off the edge or on another display).
        if f.midX > vf.minX && f.midX < vf.maxX {
            item.savedTopOffset = max(0, f.minY - vf.minY)
        }
    }

    private func focusCurrent() {
        guard let cur = current, isShown else { return }
        AX.focus(pid: cur.pid, window: cur.window)
    }

    private func relayout() {
        if isShown, let cur = current { show(cur, animated: true) } else { refreshPullTab() }
    }

    // MARK: - Geometry (AX coordinates)

    private func slotFrame(on screen: NSScreen) -> CGRect {
        let vf = ScreenGeo.toAX(screen.visibleFrame)
        let x = side == .right ? vf.maxX - width - margin : vf.minX + margin
        return CGRect(x: x, y: vf.minY + topMargin, width: width, height: vf.height - topMargin - margin)
    }

    /// Re-anchors the slot to the window's actual size against the chosen screen edge.
    private func fitted(_ slot: CGRect, realSize: CGSize, on screen: NSScreen) -> CGRect {
        let vf = ScreenGeo.toAX(screen.visibleFrame)
        let w = min(max(slot.width, realSize.width), vf.width - 2 * margin)
        let h = min(max(slot.height, realSize.height), vf.height - topMargin)
        let x = side == .right ? vf.maxX - w - margin : vf.minX + margin
        // Keep the chosen height position; just make sure the top stays on screen
        // and enough of the window is visible to grab it.
        let y = min(max(slot.minY, vf.minY), vf.maxY - min(h, 120))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A parked window can't be moved completely off screen: macOS keeps its title bar on
    /// screen, and whatever hangs over the edge shows while swiping between desktops.
    /// So if every window of the app is in Slide Over, the whole app is hidden instead
    /// (a hidden app draws nothing at all).
    private func canHideApp(of item: SlideItem) -> Bool {
        let pid = item.pid
        let slideIDs = Set(items.filter { $0.pid == pid }.map { $0.windowID })
        guard let windows = AX.attribute(AX.app(pid), kAXWindowsAttribute) as? [AXUIElement] else { return false }
        let ids = windows.compactMap { AX.windowID($0) }
        return !ids.isEmpty && ids.allSatisfy { slideIDs.contains($0) }
    }

    /// Where a hidden window rests. If its app gets hidden, it simply stays beside the screen
    /// at its own height, so it slides straight back in sideways. Only windows of apps that
    /// can't be hidden go to the bottom corner, where the least of them shows.
    private func restingSpot(for item: SlideItem, frame f: CGRect, on screen: NSScreen) -> CGPoint {
        canHideApp(of: item)
            ? hiddenOrigin(on: screen, y: f.minY, width: f.width)
            : parkingSpot(on: screen, width: f.width)
    }

    private func hideAppIfIdle(_ item: SlideItem) {
        let pid = item.pid
        if isShown, current?.pid == pid { return }
        guard items.contains(where: { $0 === item }) else { return }   // removed in the meantime
        guard canHideApp(of: item) else { return }
        // Hiding the front app makes macOS pick the next one, possibly on another desktop.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    /// Where hidden windows wait: just outside the bottom corner of the screen, so nothing of
    /// them hangs over the left or right edge. (Slide Over apps are on every desktop, and a
    /// window hanging over the side edge shows up while you swipe between desktops.)
    private func parkingSpot(on screen: NSScreen, width w: CGFloat) -> CGPoint {
        let sf = ScreenGeo.toAX(screen.frame)
        let x = side == .right ? sf.maxX - 1 : sf.minX - w + 1
        return CGPoint(x: x, y: sf.maxY - 1)
    }

    /// Just past the side edge at height `y`: where the slide animation starts and ends.
    private func hiddenOrigin(on screen: NSScreen, y: CGFloat, width w: CGFloat) -> CGPoint {
        let sf = ScreenGeo.toAX(screen.frame)
        let x = side == .right ? sf.maxX - 1 : sf.minX - w + 1
        return CGPoint(x: x, y: y)
    }

    private func refreshPullTab() {
        if !isShown && !items.isEmpty {
            pullTab.place(on: shownScreen ?? NSScreen.main ?? NSScreen.screens[0], side: side)
        } else {
            pullTab.orderOut(nil)
        }
    }

    // MARK: - Events

    private func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if pid == myPID { return }

        if items.contains(where: { $0.pid == pid }) {
            // Switched (Cmd-Tab / Dock / click) to an app that owns a Slide Over window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                let focusedID = AX.focusedWindow(pid: pid).flatMap(AX.windowID)
                if let item = self.items.first(where: { $0.windowID == focusedID }) {
                    if item === self.current && self.isShown {
                        self.mirror.setVisible(false)
                    } else if CACurrentMediaTime() >= self.suppressAutoShowUntil {
                        self.show(item)
                    }
                } else if self.isShown {
                    // Focus went to a normal window of that app → keep floating via the mirror.
                    self.syncMirror()
                    self.mirror.setVisible(true)
                }
            }
            return
        }

        lastOtherPID = pid
        if isShown {
            // You clicked into your main app: keep Slide Over floating on top, iPad-style.
            syncMirror()
            mirror.setVisible(true)
            handle.orderFrontRegardless()
        }
    }

    private func syncMirror() {
        guard let cur = current, let f = AX.frame(cur.window) else { return }
        mirror.updateFrame(f)
        handle.place(above: f)
    }

    private func appTerminated(_ app: NSRunningApplication) {
        for item in items where item.pid == app.processIdentifier {
            remove(item, restore: false)
        }
    }

    private func screensChanged() {
        if isShown { hide(animated: false) }
        refreshPullTab()
    }

    private func handleDragged(_ dx: CGFloat) {
        if side == .right && dx < -120 { side = .left }
        else if side == .left && dx > 120 { side = .right }
    }

    // MARK: - Touch-screen edge swipe

    private var touchMonitor: Any?
    private var debugMonitor: Any?
    private var edgeSwipeStart: (x: CGFloat, time: CFTimeInterval, screen: NSScreen)?

    /// On a touch-screen Mac a finger arrives as a pointer press + drag. A press that starts
    /// right at the left screen edge and quickly moves inwards slides Slide Over in.
    /// Only when Slide Over is on the left: the right edge belongs to Notification Center.
    private func edgeSwipeEvent(_ e: NSEvent) {
        guard side == .left, !items.isEmpty, !isShown, !switcherActive else {
            edgeSwipeStart = nil
            return
        }
        let m = NSEvent.mouseLocation
        switch e.type {
        case .leftMouseDown:
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }),
               m.x <= screen.frame.minX + 14 {
                edgeSwipeStart = (m.x, CACurrentMediaTime(), screen)
            } else {
                edgeSwipeStart = nil
            }
        case .leftMouseDragged:
            guard let start = edgeSwipeStart else { return }
            if CACurrentMediaTime() - start.time > 0.6 {
                edgeSwipeStart = nil            // too slow: an ordinary drag, not a swipe
            } else if m.x - start.x > 70 {
                edgeSwipeStart = nil
                shownScreen = start.screen
                showCurrent()
            }
        default:
            edgeSwipeStart = nil
        }
    }

    /// Push the pointer against the screen edge for a moment to slide the window in —
    /// and again to slide it back out. The pointer has to leave the edge in between,
    /// so resting there doesn't make it bounce in and out.
    private var edgeArmed = true

    private func mouseMoved() {
        guard edgeHoverEnabled, !items.isEmpty, !switcherActive else {
            edgeTimer?.invalidate()
            edgeTimer = nil
            return
        }
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        let sf = screen.frame
        let vf = screen.visibleFrame
        let atEdge = side == .right ? m.x >= sf.maxX - 1.5 : m.x <= sf.minX + 0.5
        let awayFromCorners = m.y > vf.minY + 80 && m.y < vf.maxY - 80

        guard atEdge && awayFromCorners else {
            edgeArmed = true
            edgeTimer?.invalidate()
            edgeTimer = nil
            return
        }
        guard edgeArmed, edgeTimer == nil else { return }

        edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.edgeTimer = nil
            let p = NSEvent.mouseLocation
            let still = self.side == .right ? p.x >= sf.maxX - 2 : p.x <= sf.minX + 1
            guard still, self.edgeArmed else { return }
            self.edgeArmed = false
            if self.isShown {
                self.hide()
            } else {
                self.shownScreen = screen
                self.showCurrent()
            }
        }
    }
}
