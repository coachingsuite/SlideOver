import AppKit

/// Trackpad gestures while ⌃⌥ is held, anywhere on screen:
///  • two fingers left / right → next / previous Slide Over window (one window per swipe)
///  • two fingers up           → show all Slide Over windows
/// Uses an event tap (covered by the Accessibility permission) so the swipe is swallowed
/// and the app under the pointer doesn't scroll at the same time.
final class SwipeTap {
    var onStep: ((Int) -> Void)?
    var onUp: (() -> Void)?
    var onShortcut: ((ShortcutAction) -> Void)?
    var suspended = false                // true while a shortcut is being recorded
    var isEnabled: () -> Bool = { true }

    private var tap: CFMachPort?
    private var dx: CGFloat = 0          // finger travel to the right
    private var dy: CGFloat = 0          // finger travel upwards
    private var swallowing = false       // this gesture belongs to us
    private var fired = false            // this gesture already triggered its action
    private let threshold: CGFloat = 50

    /// Safe to call repeatedly; does nothing until Accessibility access is granted.
    func start() {
        guard tap == nil, AX.isTrusted else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SwipeTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let used = type == .keyDown ? me.handleKey(event) : me.handle(event)
            return used ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue)
                                            | CGEventMask(1 << CGEventType.keyDown.rawValue),
                                        callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        tap = t
        let source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    /// Keyboard shortcuts (editable, see Shortcuts.swift). Matched here because the tap also
    /// sees the Globe key, which classic global hotkeys can't use.
    private func handleKey(_ event: CGEvent) -> Bool {
        guard !suspended else { return false }
        let mods = Shortcut.mods(from: event.flags)
        guard mods != 0 else { return false }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let action = ShortcutStore.shared.action(keyCode: keyCode, mods: mods) else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onShortcut?(action) }
        return true
    }

    /// Returns true if the event was used (and should not reach the app underneath).
    private func handle(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let held = flags.contains(.maskControl) && flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand) && !flags.contains(.maskShift)
        // Fast path: ordinary scrolling is passed straight through.
        if !swallowing && !held { return false }

        guard let e = NSEvent(cgEvent: event), e.hasPreciseScrollingDeltas else { return false }

        // A new gesture starts (or the keys went down mid-swipe): decide whether it's ours.
        // Once it is, the whole gesture — including the coasting after the fingers lift —
        // is swallowed, so nothing underneath scrolls and the switcher doesn't get half a swipe.
        if e.phase == .began || e.phase == .mayBegin || (!swallowing && e.momentumPhase == []) {
            swallowing = held && isEnabled()
            dx = 0
            dy = 0
            fired = false
        }
        guard swallowing else { return false }
        if e.momentumPhase != [] || fired { return true }

        // Which way the fingers move, whatever the natural-scrolling setting.
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        dx += sign * e.scrollingDeltaX
        dy += -sign * e.scrollingDeltaY

        if hypot(dx, dy) > threshold {
            fired = true                       // one action per swipe
            if dy > 0 && dy > abs(dx) * 1.2 {
                onUp?()
            } else if abs(dx) > abs(dy) {
                onStep?(dx < 0 ? 1 : -1)       // fingers left → next, right → previous
            }
        }
        return true
    }
}
