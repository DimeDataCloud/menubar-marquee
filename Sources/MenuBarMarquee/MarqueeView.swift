import AppKit
import QuartzCore

/// The marquee itself.
///
/// Same trick as the CSS version — lay the item list out end to end, duplicate
/// it, and translate the whole track left by exactly one copy width on a linear
/// loop. Because copy two is identical to copy one, the wrap point is invisible.
///
/// Done with Core Animation rather than a timer: `transform.translation.x` is
/// animated by the render server, so the loop costs this process ~0% CPU while
/// it runs. That matters for something that scrolls all day in the menu bar.
final class MarqueeView: NSView {

    private let config: Config
    private let trackLayer = CALayer()
    private let fadeMask = CAGradientLayer()

    private var entries: [AppEntry] = []
    private var itemFrames: [CGRect] = []   // x/width of each item within ONE copy
    private var copyWidth: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var isPaused = false      // the layer's clock is actually stopped
    private var hovering = false
    private var cursorPushed = false

    init(config: Config) {
        self.config = config
        super.init(frame: .zero)

        // Layer-hosting, not layer-backed: assign the layer BEFORE setting
        // wantsLayer, or AppKit makes its own and manages the sublayers for us.
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        trackLayer.anchorPoint = .zero
        trackLayer.position = .zero
        root.addSublayer(trackLayer)

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [
            NSColor.clear.cgColor, NSColor.black.cgColor,
            NSColor.black.cgColor, NSColor.clear.cgColor,
        ]
        root.mask = fadeMask
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    func update(entries: [AppEntry]) {
        self.entries = entries
        rebuild()
    }

    /// Tears down and re-lays out the track, resuming at the same point in the
    /// loop so a settings change or an appearance flip doesn't snap it back to
    /// the start.
    func rebuild() {
        // Without this, every frame/opacity/contents change below gets CA's
        // default implicit animation and the strip visibly fades and stretches
        // itself back together on each rebuild.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Read the position before unfreezing, then rebuild against a running
        // clock — CA's local-time maths is only meaningful at speed 1.
        let phase = currentPhase()
        unfreeze()

        trackLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        trackLayer.removeAnimation(forKey: Self.animationKey)
        itemFrames = []
        copyWidth = 0

        guard !entries.isEmpty, bounds.height > 0 else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let font = NSFont.systemFont(ofSize: config.fontSize, weight: .medium)
        let textColor = resolvedLabelColor()

        // Pass 1 — measure. Pass 2 — build, once we know the copy width.
        var x: CGFloat = 0
        var measured: [(entry: AppEntry, text: NSAttributedString?, width: CGFloat)] = []
        for entry in entries {
            var width = config.iconSize
            var attributed: NSAttributedString?
            if config.showNames {
                let string = NSAttributedString(
                    string: entry.name,
                    attributes: [.font: font, .foregroundColor: textColor]
                )
                attributed = string
                width += Self.iconTextGap + ceil(string.size().width)
            }
            measured.append((entry, attributed, width))
            itemFrames.append(CGRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + config.spacing
        }
        // Includes the trailing gap, so the seam between copies gets exactly the
        // same spacing as every other pair. This is what makes the loop invisible.
        copyWidth = x

        // Two copies is the minimum for a seamless loop, but if the whole app
        // list is narrower than the strip, two still leaves a hole — add copies
        // until the track can never under-fill the viewport.
        let copies = max(2, Int(ceil(bounds.width / copyWidth)) + 1)

        for copy in 0..<copies {
            let offset = CGFloat(copy) * copyWidth
            for (index, item) in measured.enumerated() {
                let frame = itemFrames[index]
                for sublayer in itemLayers(icon: item.entry.icon,
                                           text: item.text,
                                           color: textColor,
                                           originX: frame.minX + offset,
                                           scale: scale) {
                    trackLayer.addSublayer(sublayer)
                }
            }
        }

        trackLayer.opacity = Float(config.opacity)
        trackLayer.bounds = CGRect(x: 0, y: 0, width: copyWidth * CGFloat(copies), height: bounds.height)
        trackLayer.position = .zero

        startAnimation(resumingAt: phase)
        applyPauseState()
    }

    private static let iconTextGap: CGFloat = 6
    private static let animationKey = "marquee"

    private func itemLayers(icon: NSImage, text: NSAttributedString?, color: NSColor,
                            originX: CGFloat, scale: CGFloat) -> [CALayer] {
        let height = bounds.height
        let size = config.iconSize

        // App icons are multi-representation .icns. Pointing the image at the
        // size we actually draw lets AppKit hand CA the right rep instead of
        // downsampling the 512pt one.
        icon.size = NSSize(width: size, height: size)

        let iconLayer = CALayer()
        iconLayer.contents = icon
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        iconLayer.frame = CGRect(x: originX,
                                 y: ((height - size) / 2).rounded(),
                                 width: size,
                                 height: size)

        guard let text else { return [iconLayer] }

        let textSize = text.size()
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.isWrapped = false
        textLayer.truncationMode = .none
        textLayer.alignmentMode = .left
        textLayer.contentsScale = scale
        // Redundant when the attributed string's colour is honoured, and the
        // fallback when it isn't — CATextLayer is inconsistent about NSColor.
        textLayer.foregroundColor = color.cgColor
        textLayer.frame = CGRect(x: originX + size + Self.iconTextGap,
                                 y: ((height - ceil(textSize.height)) / 2).rounded(),
                                 width: ceil(textSize.width) + 2,
                                 height: ceil(textSize.height))

        return [iconLayer, textLayer]
    }

    /// `labelColor` is appearance-dependent, so resolve it inside the view's
    /// current appearance or it bakes in whatever was active at launch.
    private func resolvedLabelColor() -> NSColor {
        var color = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return color
    }

    // MARK: - Animation

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Where we are in the loop, 0...1 — used to stitch a rebuild back together.
    private func currentPhase() -> CGFloat {
        guard copyWidth > 0 else { return 0 }
        let value = (trackLayer.presentation() ?? trackLayer).value(forKeyPath: "transform.translation.x")
        let tx = CGFloat((value as? NSNumber)?.doubleValue ?? 0)
        var fraction = (-tx / copyWidth).truncatingRemainder(dividingBy: 1)
        if fraction < 0 { fraction += 1 }
        return fraction
    }

    private func startAnimation(resumingAt phase: CGFloat) {
        guard copyWidth > 0 else { return }
        guard !reduceMotion else {
            // Motion is off system-wide: park the track and leave it readable.
            trackLayer.transform = CATransform3DIdentity
            return
        }

        let duration = CFTimeInterval(copyWidth / config.speed)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -copyWidth
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.timeOffset = duration * CFTimeInterval(phase)

        trackLayer.add(animation, forKey: Self.animationKey)
    }

    /// Paused from the status menu, as opposed to paused because the cursor is
    /// resting on the strip. The two are tracked separately so a rebuild — or
    /// the cursor leaving — can't silently undo the other one.
    private(set) var manuallyPaused = false

    func setManuallyPaused(_ paused: Bool) {
        manuallyPaused = paused
        applyPauseState()
    }

    private func applyPauseState() {
        if manuallyPaused || (hovering && config.pauseOnHover) {
            freeze()
        } else {
            unfreeze()
        }
    }

    /// The standard CALayer stop-the-clock idiom: drop the layer's speed to
    /// zero and pin its local time, then rebase `beginTime` on the way back.
    private func freeze() {
        guard !isPaused, trackLayer.animation(forKey: Self.animationKey) != nil else { return }
        let stopped = trackLayer.convertTime(CACurrentMediaTime(), from: nil)
        trackLayer.speed = 0
        trackLayer.timeOffset = stopped
        isPaused = true
    }

    private func unfreeze() {
        guard isPaused else { return }
        let stopped = trackLayer.timeOffset
        trackLayer.speed = 1
        trackLayer.timeOffset = 0
        trackLayer.beginTime = 0
        trackLayer.beginTime = trackLayer.convertTime(CACurrentMediaTime(), from: nil) - stopped
        isPaused = false
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        let fraction = bounds.width > 0 ? min(0.45, config.fadeWidth / bounds.width) : 0
        fadeMask.locations = [0, NSNumber(value: Double(fraction)),
                              NSNumber(value: Double(1 - fraction)), 1]
        CATransaction.commit()

        // Rebuild when the strip resizes enough to change the layout: a new
        // height moves every item, and a wider strip may need more copies to
        // stay filled.
        let needsMoreCopies = copyWidth > 0 && trackLayer.bounds.width < bounds.width + copyWidth
        if copyWidth == 0 || trackLayer.bounds.height != bounds.height || needsMoreCopies {
            rebuild()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .activeAlways — the panel never becomes key, so the mouse-tracking
        // modes that depend on activation would never fire.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyPauseState()
        if !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyPauseState()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only the icons themselves are clickable. Everything else — the gaps, and
    /// the area below the menu bar when large icons make the strip overhang —
    /// passes the click through to whatever is underneath, so the strip never
    /// steals a click meant for a window below it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return entry(at: local) != nil ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let entry = entry(at: convert(event.locationInWindow, from: nil)) else { return }
        NSWorkspace.shared.openApplication(at: entry.url,
                                           configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }

    /// Maps a click to an app by undoing the live track translation, then
    /// folding the result back into one copy's worth of coordinates.
    private func entry(at point: CGPoint) -> AppEntry? {
        guard copyWidth > 0, !entries.isEmpty else { return nil }
        let value = (trackLayer.presentation() ?? trackLayer).value(forKeyPath: "transform.translation.x")
        let tx = CGFloat((value as? NSNumber)?.doubleValue ?? 0)

        var local = (point.x - tx).truncatingRemainder(dividingBy: copyWidth)
        if local < 0 { local += copyWidth }

        let slop = config.spacing / 2
        for (index, frame) in itemFrames.enumerated()
        where local >= frame.minX - slop && local < frame.maxX + slop {
            return entries[index]
        }
        return nil
    }
}
