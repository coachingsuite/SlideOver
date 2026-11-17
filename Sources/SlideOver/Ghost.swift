import AppKit
import QuartzCore
import ScreenCaptureKit

/// Smooth window slides.
///
/// Moving another app's window through the Accessibility API frame by frame stutters,
/// because every step is a round trip to that app and it has to redraw. Instead we slide
/// a snapshot of the window (a "ghost") with Core Animation on the GPU, at the display's
/// full refresh rate, and move the real window in one jump at the start or end.
enum Ghost {
    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)

    /// Snapshot of one window at full resolution. Calls back on the main thread (nil without permission).
    static func snapshot(windowID: CGWindowID, completion: @escaping (CGImage?) -> Void) {
        guard CGPreflightScreenCaptureAccess() else { completion(nil); return }
        Task {
            let image = await capture(windowID)
            await MainActor.run { completion(image) }
        }
    }

    private static func capture(_ windowID: CGWindowID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == windowID })
        else { return nil }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let config = SCStreamConfiguration()
        config.width = max(Int(window.frame.width * scale), 16)
        config.height = max(Int(window.frame.height * scale), 16)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Slides `image` from one AX rect to another.
    /// - Parameters:
    ///   - onShown: runs once the ghost covers `from` (move the real window away here).
    ///   - completion: runs when the ghost has arrived (move the real window in here).
    static func slide(image: CGImage, from: CGRect, to: CGRect, on screen: NSScreen,
                      duration: Double = 0.32,
                      onShown: (() -> Void)? = nil,
                      completion: @escaping () -> Void) {
        let panel = OverlayPanel(frame: screen.frame)
        panel.ignoresMouseEvents = true
        panel.level = .floating
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        panel.contentView = view

        func local(_ ax: CGRect) -> CGRect {
            ScreenGeo.toCocoa(ax).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        }
        let a = local(from)
        let b = local(to)

        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.cornerRadius = 10
        layer.masksToBounds = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = b              // final model value
        view.layer?.addSublayer(layer)
        CATransaction.commit()

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: NSPoint(x: a.midX, y: a.midY))
        position.toValue = NSValue(point: NSPoint(x: b.midX, y: b.midY))
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = NSValue(size: a.size)
        size.toValue = NSValue(size: b.size)
        let group = CAAnimationGroup()
        group.animations = [position, size]
        group.duration = duration
        group.timingFunction = curve

        panel.orderFrontRegardless()

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            completion()
            // Give the real window a frame to land before the ghost disappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                panel.orderOut(nil)
            }
        }
        layer.add(group, forKey: "slide")
        CATransaction.commit()

        if let onShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { onShown() }
        }
    }
}
