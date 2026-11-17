import AppKit

/// One keyboard shortcut: a physical key plus modifiers. Stored per action in the
/// preferences and matched in the event tap (which, unlike classic hotkeys, also sees
/// the Globe key).
struct Shortcut: Equatable {
    static let ctrl: UInt = 1, opt: UInt = 2, shift: UInt = 4, cmd: UInt = 8, globe: UInt = 16

    var keyCode: Int
    var mods: UInt
    var label: String      // the key's character, remembered when it was recorded

    static func == (a: Shortcut, b: Shortcut) -> Bool { a.keyCode == b.keyCode && a.mods == b.mods }

    static func mods(from f: CGEventFlags) -> UInt {
        var m: UInt = 0
        if f.contains(.maskControl) { m |= ctrl }
        if f.contains(.maskAlternate) { m |= opt }
        if f.contains(.maskShift) { m |= shift }
        if f.contains(.maskCommand) { m |= cmd }
        if f.contains(.maskSecondaryFn) { m |= globe }
        return m
    }

    static func mods(from f: NSEvent.ModifierFlags) -> UInt {
        var m: UInt = 0
        if f.contains(.control) { m |= ctrl }
        if f.contains(.option) { m |= opt }
        if f.contains(.shift) { m |= shift }
        if f.contains(.command) { m |= cmd }
        if f.contains(.function) { m |= globe }
        return m
    }

    /// The modifier keys you physically hold (used for "keep holding to see the switcher").
    var holdFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & Shortcut.ctrl != 0 { f.insert(.control) }
        if mods & Shortcut.opt != 0 { f.insert(.option) }
        if mods & Shortcut.shift != 0 { f.insert(.shift) }
        if mods & Shortcut.cmd != 0 { f.insert(.command) }
        return f
    }

    // Arrow and navigation keys always report the "function" flag, pressed with Globe or not.
    private static let arrows: Set<Int> = [123, 124, 125, 126]
    private static let globeArrows: [Int: String] = [115: "←", 119: "→", 116: "↑", 121: "↓"]   // Home End PgUp PgDn
    private static let fKeys: [Int: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                               98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
    private static let named: [Int: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 76: "⌅", 48: "⇥",
                                               49: "Space", 51: "⌫", 117: "⌦", 53: "Esc"]

    /// A shortcut must not swallow ordinary typing or plain navigation keys.
    var isUsable: Bool {
        if mods & (Shortcut.ctrl | Shortcut.opt | Shortcut.cmd) != 0 { return true }
        if Shortcut.fKeys[keyCode] != nil { return true }
        let navigation = Shortcut.arrows.contains(keyCode) || Shortcut.globeArrows[keyCode] != nil || keyCode == 117
        return mods & Shortcut.globe != 0 && !navigation
    }

    var display: String {
        var parts: [String] = []
        let key: String
        var showGlobe = mods & Shortcut.globe != 0
        if let arrow = Shortcut.globeArrows[keyCode] {
            key = arrow                 // on a Mac keyboard these are Globe + arrow
            showGlobe = true
        } else if let f = Shortcut.fKeys[keyCode] {
            key = f
            showGlobe = false
        } else if let n = Shortcut.named[keyCode] {
            key = n
            if Shortcut.arrows.contains(keyCode) || keyCode == 117 { showGlobe = false }
        } else {
            key = label.isEmpty ? "Key \(keyCode)" : label
        }
        if showGlobe { parts.append("🌐") }
        var m = ""
        if mods & Shortcut.ctrl != 0 { m += "⌃" }
        if mods & Shortcut.opt != 0 { m += "⌥" }
        if mods & Shortcut.shift != 0 { m += "⇧" }
        if mods & Shortcut.cmd != 0 { m += "⌘" }
        if !m.isEmpty { parts.append(m) }
        parts.append(key)
        return parts.joined(separator: " ")
    }
}

enum ShortcutAction: String, CaseIterable {
    case addRight, addLeft, add, toggle, toggle2, next, previous, overview, remove

    var title: String {
        switch self {
        case .addRight: return "Front window into Slide Over, right side"
        case .addLeft: return "Front window into Slide Over, left side"
        case .add: return "Front window into Slide Over, current side"
        case .toggle: return "Show / hide Slide Over"
        case .toggle2: return "Show / hide Slide Over (second shortcut)"
        case .next: return "Next window (hold to see the switcher)"
        case .previous: return "Previous window"
        case .overview: return "Show all Slide Over windows"
        case .remove: return "Take current window out of Slide Over"
        }
    }

    var defaultShortcut: Shortcut {
        let co = Shortcut.ctrl | Shortcut.opt
        switch self {
        case .addRight: return Shortcut(keyCode: 119, mods: Shortcut.opt | Shortcut.globe, label: "")   // Globe ⌥ →
        case .addLeft: return Shortcut(keyCode: 115, mods: Shortcut.opt | Shortcut.globe, label: "")    // Globe ⌥ ←
        case .add: return Shortcut(keyCode: 0, mods: co, label: "A")
        case .toggle: return Shortcut(keyCode: 42, mods: Shortcut.globe, label: "$")                    // key left of Return (Swiss)
        case .toggle2: return Shortcut(keyCode: 1, mods: co, label: "S")
        case .next: return Shortcut(keyCode: 45, mods: co, label: "N")
        case .previous: return Shortcut(keyCode: 35, mods: co, label: "P")
        case .overview: return Shortcut(keyCode: 13, mods: co, label: "W")
        case .remove: return Shortcut(keyCode: 2, mods: co, label: "D")
        }
    }
}

final class ShortcutStore {
    static let shared = ShortcutStore()
    private let key = "shortcuts"
    private var map: [ShortcutAction: Shortcut] = [:]

    private init() { load() }

    private func load() {
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        map = [:]
        for action in ShortcutAction.allCases {
            if let d = saved[action.rawValue], let k = d["k"] as? Int {
                if k >= 0 {
                    map[action] = Shortcut(keyCode: k, mods: UInt(d["m"] as? Int ?? 0), label: d["l"] as? String ?? "")
                }   // k < 0: deliberately cleared
            } else {
                map[action] = action.defaultShortcut
            }
        }
    }

    private func save() {
        var out: [String: [String: Any]] = [:]
        for action in ShortcutAction.allCases {
            if let s = map[action] {
                out[action.rawValue] = ["k": s.keyCode, "m": Int(s.mods), "l": s.label]
            } else {
                out[action.rawValue] = ["k": -1, "m": 0, "l": ""]
            }
        }
        UserDefaults.standard.set(out, forKey: key)
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? { map[action] }

    /// Sets (or clears, with nil) a shortcut. A combination can belong to one action only.
    func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if let shortcut {
            for other in ShortcutAction.allCases where other != action && map[other] == shortcut {
                map[other] = nil
            }
        }
        map[action] = shortcut
        save()
    }

    func action(keyCode: Int, mods: UInt) -> ShortcutAction? {
        map.first { $0.value.keyCode == keyCode && $0.value.mods == mods }?.key
    }

    func resetAll() {
        UserDefaults.standard.removeObject(forKey: key)
        load()
    }
}

/// "Keyboard Shortcuts…" window: click a shortcut, press the new keys.
final class ShortcutsWindowController: NSObject, NSWindowDelegate {
    /// Called with true while a shortcut is being recorded (the global shortcuts pause meanwhile).
    var onRecordingChanged: ((Bool) -> Void)?

    private var window: NSWindow?
    private var buttons: [ShortcutAction: NSButton] = [:]
    private var recording: ShortcutAction?
    private var monitor: Any?

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "SlideOver Keyboard Shortcuts"
        w.isReleasedWhenClosed = false
        w.delegate = self

        var rows: [[NSView]] = []
        for (i, action) in ShortcutAction.allCases.enumerated() {
            let title = NSTextField(labelWithString: action.title)
            let button = NSButton(title: "", target: self, action: #selector(record(_:)))
            button.tag = i
            button.widthAnchor.constraint(equalToConstant: 150).isActive = true
            buttons[action] = button
            let clear = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
            clear.tag = i
            rows.append([title, button, clear])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12

        let hint = NSTextField(wrappingLabelWithString:
            "Click a shortcut, then press the new keys. A shortcut needs at least one of ⌃ ⌥ ⌘ or the Globe key. "
            + "Esc cancels. The trackpad gestures (hold ⌃⌥ and swipe) can't be changed here.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = false
        hint.preferredMaxLayoutWidth = 470
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 470).isActive = true

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetAll))

        let stack = NSStackView(views: [grid, hint, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        w.contentView = content
        w.setContentSize(content.fittingSize)
        window = w
    }

    private func refresh() {
        for (action, button) in buttons {
            if recording == action {
                button.title = "Press shortcut…"
            } else {
                button.title = ShortcutStore.shared.shortcut(for: action)?.display ?? "Not set"
            }
        }
    }

    @objc private func record(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        let wasRecordingThis = recording == action
        stopRecording()
        if wasRecordingThis { return }

        recording = action
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captured(event)
            return nil
        }
        refresh()
    }

    private func captured(_ event: NSEvent) {
        guard let action = recording else { return }
        let candidate = Shortcut(keyCode: Int(event.keyCode),
                                 mods: Shortcut.mods(from: event.modifierFlags),
                                 label: (event.charactersIgnoringModifiers ?? "").uppercased())
        if candidate.keyCode == 53 && candidate.mods == 0 {      // Esc: cancel
            stopRecording()
            return
        }
        guard candidate.isUsable else {
            NSSound.beep()
            return
        }
        ShortcutStore.shared.set(candidate, for: action)
        stopRecording()
    }

    private func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        if recording != nil {
            recording = nil
            onRecordingChanged?(false)
        }
        refresh()
    }

    @objc private func clear(_ sender: NSButton) {
        stopRecording()
        ShortcutStore.shared.set(nil, for: ShortcutAction.allCases[sender.tag])
        refresh()
    }

    @objc private func resetAll() {
        stopRecording()
        ShortcutStore.shared.resetAll()
        refresh()
    }
}
