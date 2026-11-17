import AppKit
import ServiceManagement

/// "Launch at login" through the system's login-item service (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SlideOver: could not change the login item: \(error)")
        }
    }
}

/// First-launch window: explains the two permissions, shows whether each is granted
/// (checked once a second), and lists the shortcuts. Also reachable from the menu.
final class SetupWindowController: NSObject, NSWindowDelegate {
    var onAccessibilityGranted: (() -> Void)?

    private var window: NSWindow?
    private var timer: Timer?
    private var wasTrusted = AX.isTrusted
    private let axStatus = NSTextField(labelWithString: "")
    private let scStatus = NSTextField(labelWithString: "")
    private let loginCheck = NSButton(checkboxWithTitle: "Launch SlideOver at login", target: nil, action: nil)
    private let contentWidth: CGFloat = 520

    func show() {
        if window == nil { build() }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Building the window

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       secondary: Bool = false, width: CGFloat? = nil) -> NSTextField {
        let l = width == nil ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.isSelectable = false
        if secondary { l.textColor = .secondaryLabelColor }
        if let width {
            l.preferredMaxLayoutWidth = width
            l.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        }
        return l
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return v
    }

    private func permissionRow(title: String, detail: String, status: NSTextField, action: Selector) -> NSView {
        let text = NSStackView(views: [label(title, weight: .semibold),
                                       label(detail, size: 12, secondary: true, width: 270)])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        let button = NSButton(title: "Open Settings…", target: self, action: action)
        let row = NSStackView(views: [text, spacer(), status, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth + 48, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "SlideOver Setup"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let title = label("Welcome to SlideOver", size: 20, weight: .semibold)
        let intro = label("SlideOver turns any app window into an iPad-style Slide Over panel. "
                          + "macOS asks for two permissions before it can do that.",
                          secondary: true, width: contentWidth)

        let axRow = permissionRow(
            title: "Accessibility (required)",
            detail: "Lets SlideOver move and resize other apps' windows and react to its shortcuts and trackpad gestures.",
            status: axStatus, action: #selector(openAccessibility))
        let scRow = permissionRow(
            title: "Screen Recording (recommended)",
            detail: "Used only for window previews: the floating copy, smooth sliding and the overview cards. "
                + "Nothing is saved or sent anywhere. Relaunch SlideOver after allowing it.",
            status: scStatus, action: #selector(openScreenRecording))

        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        func keys(_ action: ShortcutAction) -> String {
            ShortcutStore.shared.shortcut(for: action)?.display ?? "not set"
        }
        let shortcuts: [(String, String)] = [
            (keys(.addRight) + "   /   " + keys(.addLeft), "Put the front window into Slide Over, right or left"),
            (keys(.toggle), "Show or hide Slide Over (or push the pointer against the edge)"),
            ("Hold ⌃⌥ + swipe left / right", "Next or previous Slide Over window"),
            ("Hold ⌃⌥ + swipe up", "Show all Slide Over windows"),
            (keys(.remove), "Take the current window out of Slide Over"),
        ]
        let grid = NSGridView(views: shortcuts.map { pair -> [NSView] in
            [label(pair.0, size: 12, weight: .medium), label(pair.1, size: 12, secondary: true)]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 16

        loginCheck.target = self
        loginCheck.action = #selector(toggleLogin)
        let relaunchButton = NSButton(title: "Relaunch SlideOver", target: self, action: #selector(relaunch))
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        doneButton.keyEquivalent = "\r"
        var buttonViews: [NSView] = [loginCheck, spacer()]
        if Support.url != nil {
            buttonViews.append(NSButton(title: "☕ Buy Me a Coffee", target: self, action: #selector(coffee)))
        }
        buttonViews += [relaunchButton, doneButton]
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let stack = NSStackView(views: [title, intro, axRow, scRow, line,
                                        label("Shortcuts  (change them under Keyboard Shortcuts… in the menu)", weight: .semibold), grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(20, after: grid)
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

    // MARK: State

    private func refresh() {
        let trusted = AX.isTrusted
        show(axStatus, allowed: trusted)
        show(scStatus, allowed: CGPreflightScreenCaptureAccess())
        loginCheck.state = LoginItem.isEnabled ? .on : .off
        if trusted && !wasTrusted { onAccessibilityGranted?() }
        wasTrusted = trusted
    }

    private func show(_ status: NSTextField, allowed: Bool) {
        status.stringValue = allowed ? "✓ Allowed" : "Not allowed yet"
        status.textColor = allowed ? .systemGreen : .systemOrange
    }

    // MARK: Actions

    @objc private func openAccessibility() {
        AX.requestTrust()   // adds SlideOver to the list in System Settings
        open(pane: "Privacy_Accessibility")
    }

    @objc private func openScreenRecording() {
        CGRequestScreenCaptureAccess()
        open(pane: "Privacy_ScreenCapture")
    }

    private func open(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        LoginItem.set(loginCheck.state == .on)
        refresh()
    }

    @objc private func coffee() {
        Support.open()
    }

    @objc private func done() {
        window?.close()
    }

    /// Quits (which puts all windows back) and starts SlideOver again once it has fully exited.
    @objc private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? p.run()
        NSApp.terminate(nil)
    }
}
