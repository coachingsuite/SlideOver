import AppKit
import QuartzCore
import ScreenCaptureKit

/// Takes still snapshots of Slide Over windows for the switcher cards.
enum Thumbnailer {
    static func capture(windowIDs: [CGWindowID], maxWidth: CGFloat,
                        completion: @escaping (CGWindowID, CGImage) -> Void) {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else { return }
            for id in windowIDs {
                guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
                let aspect = max(window.frame.width, 1) / max(window.frame.height, 1)
                let w = min(maxWidth, window.frame.width) * 2
                let config = SCStreamConfiguration()
                config.width = max(Int(w), 64)
                config.height = max(Int(w / aspect), 64)
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    await MainActor.run { completion(id, image) }
                }
            }
        }
    }
}

/// Root view of the switcher: catches clicks and trackpad swipes.
final class SwitcherView: NSView {
    weak var panel: SwitcherPanel?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        panel?.clicked(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        panel?.scrolled(event, at: convert(event.locationInWindow, from: nil))
    }
}

/// iPad-style Slide Over switcher in the Slide Over area: the windows as overlapping cards.
///
/// Trackpad: two fingers sideways → the cards follow your fingers and settle on the nearest
/// one when you lift them. Two fingers up on a card → throw it away (removes it from Slide Over).
final class SwitcherPanel: OverlayPanel {
    var onPick: ((Int) -> Void)?
    var onSelect: ((Int) -> Void)?      // the centred card changed
    var onRemove: ((Int) -> Void)?      // card was swiped away
    var onCancel: (() -> Void)?

    private let root = SwitcherView()
    private let blur = NSVisualEffectView()
    private let cardsView = NSView()
    private let cardsHost = CALayer()
    private var cards: [CALayer] = []
    private var imageLayers: [CALayer] = []
    private var spacing: CGFloat = 300

    /// Continuous carousel position: 0 = first card centred, 1.5 = halfway between 2nd and 3rd.
    private var position: CGFloat = 0
    private var selected: Int { cards.isEmpty ? 0 : min(max(Int(position.rounded()), 0), cards.count - 1) }

    // Gesture state
    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var gestureDX: CGFloat = 0
    private var gestureDY: CGFloat = 0
    private var startPosition: CGFloat = 0
    private var liftIndex: Int?           // card being swiped up
    private var lastWheelStep: CFTimeInterval = 0

    private let spring = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        level = .modalPanel   // above the floating mirror
        hasShadow = true

        root.panel = self
        root.wantsLayer = true
        contentView = root

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        blur.frame = root.bounds
        root.addSubview(blur)

        // Cards are clipped to the rounded panel, so neighbours peek in from the sides.
        cardsView.wantsLayer = true
        cardsView.autoresizingMask = [.width, .height]
        cardsView.frame = root.bounds
        cardsView.layer?.cornerRadius = 16
        cardsView.layer?.masksToBounds = true
        root.addSubview(cardsView)
        cardsView.layer?.addSublayer(cardsHost)
    }

    // MARK: Presenting

    /// Shows the switcher in the Slide Over area (`axFrame`, AX coordinates).
    func present(axFrame: CGRect, titles: [String], icons: [NSImage?], images: [CGImage?],
                 sizes: [CGSize], selected: Int) {
        setFrame(ScreenGeo.toCocoa(axFrame), display: true)
        let bounds = root.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardsHost.frame = bounds
        cards.forEach { $0.removeFromSuperlayer() }
        cards = []
        imageLayers = []

        // Leave room below each card for the app icon and name.
        let maxH = (bounds.height - 110) * 0.85
        let maxW = bounds.width * 0.66
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var widest: CGFloat = 0

        for i in titles.indices {
            let s = sizes[i]
            let aspect = max(s.width, 1) / max(s.height, 1)
            var h = maxH
            var w = h * aspect
            if w > maxW { w = maxW; h = w / aspect }
            widest = max(widest, w)
            let size = CGSize(width: w, height: h)

            let card = CALayer()
            card.bounds = CGRect(origin: .zero, size: size)
            card.shadowColor = NSColor.black.cgColor
            card.shadowOpacity = 0.45
            card.shadowRadius = 20
            card.shadowOffset = CGSize(width: 0, height: -8)
            card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)

            let image = CALayer()
            image.frame = card.bounds
            image.cornerRadius = 14
            image.masksToBounds = true
            image.backgroundColor = NSColor.windowBackgroundColor.cgColor
            image.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
            image.borderWidth = 0.5
            if let cg = images[i] {
                image.contents = cg
                image.contentsGravity = .resize
            } else {
                image.contents = icons[i]
                image.contentsGravity = .center
            }
            card.addSublayer(image)

            let icon = CALayer()
            icon.contents = icons[i]
            icon.contentsGravity = .resizeAspect
            icon.frame = CGRect(x: size.width / 2 - 20, y: -54, width: 40, height: 40)
            card.addSublayer(icon)

            let label = CATextLayer()
            label.string = titles[i]
            label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            label.fontSize = 14
            label.foregroundColor = NSColor.white.cgColor
            label.alignmentMode = .center
            label.truncationMode = .end
            label.contentsScale = scale
            label.frame = CGRect(x: -40, y: -78, width: size.width + 80, height: 20)
            card.addSublayer(label)

            cardsHost.addSublayer(card)
            cards.append(card)
            imageLayers.append(image)
        }

        // Neighbours overlap the selected card a little, like the iPad switcher.
        spacing = max(widest * 0.62, 1)
        position = CGFloat(selected)
        axis = .undecided
        liftIndex = nil
        layoutCards(animated: false)
        CATransaction.commit()

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 1
        }
    }

    /// Keyboard stepping (⌃⌥N / ⌃⌥P).
    func select(_ index: Int) {
        position = CGFloat(index)
        layoutCards(animated: true)
    }

    func setImage(_ image: CGImage, at index: Int) {
        guard index < imageLayers.count else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        imageLayers[index].contents = image
        imageLayers[index].contentsGravity = .resize
        CATransaction.commit()
    }

    /// Drops a card after it was swiped away; the others close the gap.
    func dropCard(at index: Int) {
        guard index < cards.count else { return }
        cards[index].removeFromSuperlayer()
        cards.remove(at: index)
        imageLayers.remove(at: index)
        if CGFloat(index) < position || Int(position) >= cards.count { position = max(0, position - 1) }
        position = min(max(position.rounded(), 0), CGFloat(max(cards.count - 1, 0)))
        layoutCards(animated: true)
        onSelect?(selected)
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
        })
    }

    // MARK: Layout

    private func layoutCards(animated: Bool, duration: Double = 0.4) {
        let bounds = cardsHost.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(spring)

        for (i, card) in cards.enumerated() {
            let offset = CGFloat(i) - position
            let distance = abs(offset)
            card.position = CGPoint(x: bounds.midX + offset * spacing, y: bounds.midY + 40)
            let s = max(0.7, 1 - 0.14 * distance)
            card.transform = CATransform3DMakeScale(s, s, 1)
            card.opacity = distance > 2.5 ? 0 : Float(max(0.0, 1 - 0.28 * distance))
            card.zPosition = -distance
        }
        CATransaction.commit()
    }

    /// Settle on the nearest card with a soft spring.
    private func snap() {
        position = min(max(position.rounded(), 0), CGFloat(max(cards.count - 1, 0)))
        layoutCards(animated: true, duration: 0.35)
        onSelect?(selected)
    }

    // MARK: Input

    private func cardIndex(at point: NSPoint) -> Int? {
        cards.enumerated()
            .filter { $0.element.opacity > 0.05 && $0.element.frame.contains(point) }
            .sorted { $0.element.zPosition > $1.element.zPosition }
            .first?.offset
    }

    fileprivate func clicked(at point: NSPoint) {
        // Clicking a card opens it; clicking the background closes the switcher.
        if let i = cardIndex(at: point) { onPick?(i) } else { onCancel?() }
    }

    fileprivate func scrolled(_ event: NSEvent, at point: NSPoint) {
        guard !cards.isEmpty else { return }

        // Classic mouse wheel: one card per notch, with a short pause so it can't race ahead.
        if !event.hasPreciseScrollingDeltas {
            let now = CACurrentMediaTime()
            let d = abs(event.deltaX) > abs(event.deltaY) ? event.deltaX : -event.deltaY
            guard d != 0, now - lastWheelStep > 0.18 else { return }
            lastWheelStep = now
            position = min(max(position.rounded() + (d > 0 ? -1 : 1), 0), CGFloat(cards.count - 1))
            layoutCards(animated: true, duration: 0.3)
            onSelect?(selected)
            return
        }

        // Trackpad: ignore the momentum phase — we settle ourselves when the fingers lift.
        if event.momentumPhase != [] { return }

        if event.phase == .began || event.phase == .mayBegin {
            axis = .undecided
            gestureDX = 0
            gestureDY = 0
            startPosition = position
            liftIndex = nil
            if event.phase == .mayBegin { return }
        }

        // Convert to "which way the fingers move", whatever the natural-scrolling setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let fingerRight = sign * event.scrollingDeltaX
        let fingerUp = -sign * event.scrollingDeltaY

        if event.phase == .changed || event.phase == .began {
            gestureDX += fingerRight
            gestureDY += fingerUp

            if axis == .undecided, hypot(gestureDX, gestureDY) > 6 {
                if gestureDY > 0 && gestureDY > abs(gestureDX) * 1.2 {
                    axis = .vertical
                    liftIndex = cardIndex(at: point) ?? selected
                } else {
                    axis = .horizontal
                }
            }

            switch axis {
            case .horizontal:
                // Cards follow the fingers 1:1, with a rubber band past the ends.
                var p = startPosition - gestureDX / spacing
                let maxP = CGFloat(cards.count - 1)
                if p < 0 { p = p * 0.3 } else if p > maxP { p = maxP + (p - maxP) * 0.3 }
                position = p
                layoutCards(animated: false)
            case .vertical:
                if let i = liftIndex { lift(card: i, by: max(0, gestureDY)) }
            case .undecided:
                break
            }
        }

        if event.phase == .ended || event.phase == .cancelled {
            switch axis {
            case .horizontal:
                // A quick flick moves at least one card, even if it didn't travel halfway.
                let moved = position - startPosition
                if abs(moved) > 0.18 && abs(moved) < 0.5 {
                    position = startPosition + (moved > 0 ? 1 : -1)
                }
                snap()
            case .vertical:
                if let i = liftIndex {
                    if gestureDY > 90 && event.phase == .ended { throwAway(card: i) } else { lift(card: i, by: 0, animated: true) }
                }
            case .undecided:
                break
            }
            axis = .undecided
            liftIndex = nil
        }
    }

    /// While swiping up, the card rises with the fingers and fades a little.
    private func lift(card i: Int, by dy: CGFloat, animated: Bool = false) {
        guard i < cards.count else { return }
        let bounds = cardsHost.bounds
        let offset = CGFloat(i) - position
        let card = cards[i]
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(spring)
        card.position = CGPoint(x: bounds.midX + offset * spacing, y: bounds.midY + 40 + dy)
        let base = Float(max(0.0, 1 - 0.28 * abs(offset)))
        card.opacity = max(0.2, base - Float(dy / 600))
        CATransaction.commit()
    }

    /// Card flies off the top, then the window is removed from Slide Over.
    private func throwAway(card i: Int) {
        guard i < cards.count else { return }
        let card = cards[i]
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            self?.onRemove?(i)
        }
        card.position = CGPoint(x: card.position.x, y: cardsHost.bounds.maxY + card.bounds.height)
        card.opacity = 0
        CATransaction.commit()
    }
}
