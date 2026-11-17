import AppKit
import ScreenCaptureKit

/// Borderless, non-activating floating panel that lives on every Space.
/// Clicking it never steals focus from the app you're working in.
class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// View that reports clicks, horizontal drags and scrolls.
final class ClickView: NSView {
    var onClick: (() -> Void)?
    var onDragEnd: ((CGFloat) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    private var startX: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startX = NSEvent.mouseLocation.x
    }

    override func mouseUp(with event: NSEvent) {
        let dx = NSEvent.mouseLocation.x - startX
        if abs(dx) < 6 { onClick?() } else { onDragEnd?(dx) }
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}

private func makePill(in view: NSView, frame: NSRect) {
    view.wantsLayer = true
    let pill = CALayer()
    pill.frame = frame
    pill.cornerRadius = min(frame.width, frame.height) / 2
    pill.backgroundColor = NSColor(white: 0.45, alpha: 0.8).cgColor
    pill.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
    pill.borderWidth = 0.5
    view.layer?.addSublayer(pill)
}

/// The little tab at the screen edge while Slide Over is stashed. Click to bring it back.
final class PullTab: OverlayPanel {
    let view = ClickView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 90))
        level = .statusBar
        makePill(in: view, frame: NSRect(x: 4, y: 5, width: 6, height: 80))
        contentView = view
    }

    func place(on screen: NSScreen, side: Side) {
        let sf = screen.frame
        let vf = screen.visibleFrame
        let x = side == .right ? sf.maxX - frame.width : sf.minX
        setFrameOrigin(NSPoint(x: x, y: vf.midY - frame.height / 2))
        orderFrontRegardless()
    }
}

/// The grabber above the Slide Over window (like the "…" bar on iPad).
/// Click = stash it away. Drag left/right across = move it to the other side.
final class Handle: OverlayPanel {
    let view = ClickView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 90, height: 14))
        makePill(in: view, frame: NSRect(x: 20, y: 4, width: 50, height: 6))
        contentView = view
    }

    func place(above axFrame: CGRect) {
        let r = ScreenGeo.toCocoa(axFrame)
        setFrameOrigin(NSPoint(x: r.midX - frame.width / 2, y: r.maxY + 2))
        orderFrontRegardless()
    }
}

/// A copy of the Slide Over window that floats above everything while another app
/// has focus. macOS gives no public API to keep *another app's* window on top, so this
/// panel takes the real window's spot. Clicking or scrolling it brings the real window back.
///
/// Default: a still snapshot taken when focus leaves (no screen-sharing indicator stays on).
/// Live mode: a continuous ScreenCaptureKit stream, which makes macOS show its
/// screen-recording indicator for as long as the mirror is visible.
final class MirrorPanel: OverlayPanel, SCStreamOutput, SCStreamDelegate {
    let view = ClickView()
    var liveMode = UserDefaults.standard.bool(forKey: "liveMirror")

    private let imageLayer = CALayer()
    private var stream: SCStream?
    private let frameQueue = DispatchQueue(label: "SlideOver.mirror.frames")
    private var generation = 0
    private var windowID: CGWindowID?
    private var wantVisible = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        hasShadow = true
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageLayer.contentsGravity = .resize
        view.layer?.addSublayer(imageLayer)
        contentView = view
    }

    /// Remember which window to mirror. Nothing is captured until the mirror is needed.
    func prepare(windowID: CGWindowID, axFrame: CGRect) {
        stopCapture()
        self.windowID = windowID
        updateFrame(axFrame)
    }

    func updateFrame(_ axFrame: CGRect) {
        setFrame(ScreenGeo.toCocoa(axFrame), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = view.bounds
        CATransaction.commit()
    }

    func setVisible(_ visible: Bool) {
        wantVisible = visible
        generation += 1
        stopStream()
        guard visible, let id = windowID, CGPreflightScreenCaptureAccess() else {
            orderOut(nil)
            return
        }
        let gen = generation
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = frame.size

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  gen == self.generation, self.wantVisible,
                  let window = content.windows.first(where: { $0.windowID == id })
            else { return }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(size.width * scale)
            config.height = Int(size.height * scale)
            config.showsCursor = false

            if self.liveMode {
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 5
                do {
                    let s = SCStream(filter: filter, configuration: config, delegate: self)
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frameQueue)
                    try await s.startCapture()
                    guard gen == self.generation, self.wantVisible else {
                        try? await s.stopCapture()
                        return
                    }
                    self.stream = s
                } catch {
                    NSLog("SlideOver: live mirror failed: \(error)")
                    return
                }
            } else {
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                      gen == self.generation, self.wantVisible
                else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.imageLayer.contents = image
                CATransaction.commit()
            }
            self.orderFrontRegardless()
        }
    }

    func stopCapture() {
        windowID = nil
        wantVisible = false
        generation += 1
        stopStream()
        orderOut(nil)
    }

    private func stopStream() {
        if let s = stream {
            stream = nil
            Task { try? await s.stopCapture() }
        }
    }

    // MARK: SCStreamOutput (live mode)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.imageLayer.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SlideOver: mirror stream stopped: \(error)")
    }
}
