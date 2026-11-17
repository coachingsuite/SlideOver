import AppKit
import ApplicationServices

// Private but long-stable symbol (used by Rectangle, AeroSpace, AltTab…) that maps
// an Accessibility window element to its CGWindowID, needed for ScreenCaptureKit.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin wrapper around the Accessibility API for moving other apps' windows.
/// AX coordinates: origin at top-left of the primary screen, y grows downward.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard let value = attribute(app(pid), kAXFocusedWindowAttribute) else { return nil }
        return (value as! AXUIElement)
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let pv = attribute(window, kAXPositionAttribute),
              let sv = attribute(window, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &point)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
    }

    static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
    }

    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        // position → size → position avoids the window being clamped by the screen edge
        setPosition(window, rect.origin)
        setSize(window, rect.size)
        setPosition(window, rect.origin)
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func isAlive(_ window: AXUIElement) -> Bool {
        attribute(window, kAXRoleAttribute) != nil
    }

    static func title(_ window: AXUIElement) -> String? {
        attribute(window, kAXTitleAttribute) as? String
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        (attribute(window, kAXMinimizedAttribute) as? Bool) == true
    }

    @discardableResult
    static func setMinimized(_ window: AXUIElement, _ minimized: Bool) -> AXError {
        let value: CFBoolean = minimized ? kCFBooleanTrue! : kCFBooleanFalse!
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
    }

    /// True if the window is on the desktop (Space) you're looking at right now.
    /// Windows on other desktops — and minimized ones — aren't in the on-screen list.
    static func isOnCurrentSpace(_ windowID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
    }

    static func unminimize(_ window: AXUIElement) {
        if (attribute(window, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    // Chrome/Electron & co. animate AX-driven moves when "enhanced UI" is on, which
    // makes our slide animation laggy. Window managers turn it off while moving.
    static func enhancedUI(pid: pid_t) -> Bool {
        (attribute(app(pid), "AXEnhancedUserInterface") as? Bool) ?? false
    }

    static func setEnhancedUI(pid: pid_t, _ on: Bool) {
        let value: CFBoolean = on ? kCFBooleanTrue! : kCFBooleanFalse!
        AXUIElementSetAttributeValue(app(pid), "AXEnhancedUserInterface" as CFString, value)
    }

    /// Bring a specific window of another app to the front and give it focus.
    static func focus(pid: pid_t, window: AXUIElement) {
        AXUIElementSetAttributeValue(app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        raise(window)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }
}

/// Converting between Cocoa (bottom-left origin) and AX (top-left origin) rects.
enum ScreenGeo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAX(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toCocoa(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func screenWithMouse() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
