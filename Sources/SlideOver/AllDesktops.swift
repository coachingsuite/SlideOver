import AppKit
import ApplicationServices

/// Puts Slide Over apps on every desktop, so their window is always on the desktop you're on.
///
/// macOS has no public API to move another app's window between desktops. The Dock's
/// "Options → Assign To → All Desktops" does it — but only when chosen *in the Dock menu*
/// (writing the setting to the Dock's preferences doesn't affect open windows). So SlideOver
/// opens the app's Dock menu through the Accessibility API and clicks it, exactly like you
/// would: first "None", then "All Desktops" (re-choosing an already-ticked item does nothing).
enum AllDesktops {
    private static let originalsKey = "allDesktopsOriginals"   // bundle ID → assignment it had before ("" = none)
    private static let queue = DispatchQueue(label: "SlideOver.dockmenu")

    enum Choice {
        case allDesktops, none

        var titles: Set<String> {
            switch self {
            case .allDesktops: return ["All Desktops", "Alle Schreibtische"]
            case .none: return ["None", "Ohne", "Keine"]
            }
        }
        /// Position below the "Assign To" header, used if the title isn't recognised (other languages).
        var offsetBelowHeader: Int {
            switch self {
            case .allDesktops: return 1
            case .none: return 3
            }
        }
    }

    // MARK: Public

    /// Assign a running app to All Desktops (asynchronous; the Dock menu flashes briefly).
    static func assign(_ app: NSRunningApplication) {
        guard let bundle = app.bundleIdentifier?.lowercased() else { return }
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        if originals[bundle] == nil {
            let before = currentBinding(bundle) ?? ""
            originals[bundle] = before == "AllSpaces" ? "" : before
            UserDefaults.standard.set(originals, forKey: originalsKey)
        }
        queue.async {
            let a = choose(.none, for: app)
            usleep(250_000)
            let b = choose(.allDesktops, for: app)
            Log.write("AllDesktops: \(bundle) none=\(a) allDesktops=\(b)")
        }
    }

    /// Undo our assignment if the app had none before SlideOver touched it.
    /// `wait: true` blocks until done — used when SlideOver quits.
    static func restore(bundleID: String, wait: Bool = false) {
        let bundle = bundleID.lowercased()
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        guard let original = originals[bundle] else { return }   // we never touched it
        originals.removeValue(forKey: bundle)
        UserDefaults.standard.set(originals, forKey: originalsKey)
        // Only undo when the app had no assignment before (a specific desktop can't be restored from the menu).
        guard original.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        let work = {
            let ok = choose(.none, for: app)
            Log.write("AllDesktops: restored \(bundle) to None: \(ok)")
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    // MARK: Dock menu automation

    private static func currentBinding(_ bundle: String) -> String? {
        let domain = "com.apple.spaces" as CFString
        CFPreferencesAppSynchronize(domain)
        let b = CFPreferencesCopyAppValue("app-bindings" as CFString, domain) as? [String: String]
        return b?[bundle]
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        (AX.attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func role(_ e: AXUIElement) -> String {
        (AX.attribute(e, kAXRoleAttribute) as? String) ?? ""
    }

    private static func title(_ e: AXUIElement) -> String {
        let t = (AX.attribute(e, kAXTitleAttribute) as? String) ?? ""
        return t.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{200E}\u{200F}…:")))
    }

    private static func poll<T>(timeout: Double = 1.0, _ body: () -> T?) -> T? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let v = body() { return v }
            usleep(30_000)
        } while Date() < end
        return nil
    }

    private static func dockItem(for app: NSRunningApplication) -> AXUIElement? {
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return nil }
        let dock = AX.app(dockPID)
        let wantedPath = app.bundleURL?.resolvingSymlinksInPath().path
        let wantedName = (app.localizedName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F} "))
        for list in children(dock) where role(list) == "AXList" {
            for item in children(list) {
                if let path = wantedPath, let url = AX.attribute(item, "AXURL") as? URL,
                   url.resolvingSymlinksInPath().path == path {
                    return item
                }
            }
            for item in children(list) where !wantedName.isEmpty && title(item) == wantedName {
                return item
            }
        }
        return nil
    }

    /// Opens the app's Dock menu → Options → the chosen "Assign To" item, and presses it.
    private static func choose(_ choice: Choice, for app: NSRunningApplication) -> Bool {
        guard let item = dockItem(for: app) else {
            Log.write("AllDesktops: no Dock item for \(app.localizedName ?? "?")")
            return false
        }
        AXUIElementPerformAction(item, kAXShowMenuAction as CFString)
        guard let menu = poll({ children(item).first { role($0) == "AXMenu" } }) else {
            Log.write("AllDesktops: Dock menu didn't open")
            return false
        }
        func cancel() { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }

        guard let options = children(menu).first(where: { ["Options", "Optionen"].contains(title($0)) }) else {
            Log.write("AllDesktops: no Options item; menu = \(children(menu).map(title))")
            cancel()
            return false
        }
        var submenu = children(options).first { role($0) == "AXMenu" }
        if submenu == nil {
            AXUIElementPerformAction(options, kAXPressAction as CFString)
            submenu = poll({ children(options).first { role($0) == "AXMenu" } })
        }
        guard let sub = submenu else {
            Log.write("AllDesktops: Options submenu didn't open")
            cancel()
            return false
        }

        let entries = children(sub)
        var target = entries.first { choice.titles.contains(title($0)) }
        if target == nil,
           let header = entries.firstIndex(where: { let t = title($0); return t.hasPrefix("Assign To") || t.hasPrefix("Zuordnen") }),
           header + choice.offsetBelowHeader < entries.count {
            target = entries[header + choice.offsetBelowHeader]
        }
        guard let t = target else {
            Log.write("AllDesktops: no Assign To item; submenu = \(entries.map(title))")
            cancel()
            return false
        }
        let err = AXUIElementPerformAction(t, kAXPressAction as CFString)
        if err != .success { cancel() }
        return err == .success
    }
}
