import Cocoa
import QuartzCore

struct AlbumEntry: Decodable, Equatable {
    let album: String
    let artist: String
    let year: Int?
    let trackCount: Int
    let totalTime: Int
    let coverTrackId: String?
    let hasArtwork: Bool

    var title: String { album.isEmpty ? "Unknown Album" : album }
    var artistName: String { artist.trimmingCharacters(in: .whitespaces).isEmpty ? "Unknown Artist" : artist }
}

/// iTunes 10 Cover Flow: a black stage, the selected cover facing forward,
/// neighbours angled away on both sides, mirrored reflections below, the
/// title and artist under the cover, and a scrubber along the bottom.
///
/// Built on Core Animation so the flip animates at the display's refresh
/// rate. Only covers near the selection have layers; the rest are virtual,
/// which is what lets an 11,000-album library scroll without stalling.
@MainActor
final class CoverFlowView: NSView {

    var albums: [AlbumEntry] = [] {
        didSet {
            imageCache.removeAll()
            generation += 1
            let keep = min(selectedIndex, max(0, albums.count - 1))
            selectedIndex = keep
            rebuildLayers()
            relayout(animated: false)
            notifySelection()
        }
    }
    private(set) var selectedIndex = 0

    var onSelectionChanged: (Int) -> Void = { _ in }
    var onOpen: (Int) -> Void = { _ in }
    /// Supplies a cover image for a track persistent ID, on the main actor.
    var imageProvider: (String, @escaping (NSImage?) -> Void) -> Void = { _, done in done(nil) }

    /// Pinch to resize, between 0.6 and 1.4 of the default cover size.
    private var coverScale: CGFloat = 1.0

    private let stage = CALayer()
    private let titleLayer = CATextLayer()
    private let artistLayer = CATextLayer()
    private let scrubber = CoverFlowScrubber()
    private var coverLayers: [Int: CALayer] = [:]
    private var imageCache: [Int: CGImage] = [:]
    private var generation = 0
    private var scrollAccumulator: CGFloat = 0
    private let window_ = 9            // covers kept on each side of the selection

    // MARK: Setup

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor

        // Perspective. Smaller magnitude = more dramatic.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 700.0
        stage.sublayerTransform = perspective
        stage.masksToBounds = true
        root.addSublayer(stage)

        for text in [titleLayer, artistLayer] {
            text.alignmentMode = .center
            text.truncationMode = .end
            text.isWrapped = false
            text.contentsScale = 2
            root.addSublayer(text)
        }
        titleLayer.font = Aqua.font(13, bold: true)
        titleLayer.fontSize = 13
        titleLayer.foregroundColor = NSColor.white.cgColor
        artistLayer.font = Aqua.font(11)
        artistLayer.fontSize = 11
        artistLayer.foregroundColor = NSColor(white: 0.72, alpha: 1).cgColor

        scrubber.onChange = { [weak self] fraction in
            guard let self = self, !self.albums.isEmpty else { return }
            let idx = Int((fraction * CGFloat(self.albums.count - 1)).rounded())
            self.select(idx, animated: false)
        }
        addSubview(scrubber)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        titleLayer.contentsScale = scale
        artistLayer.contentsScale = scale
        for l in coverLayers.values { setScale(l, scale) }
    }

    private func setScale(_ container: CALayer, _ scale: CGFloat) {
        container.contentsScale = scale
        container.sublayers?.forEach { $0.contentsScale = scale; $0.mask?.contentsScale = scale }
    }

    // MARK: Geometry

    private var scrubberHeight: CGFloat { 26 }
    private var textHeight: CGFloat { 44 }

    private var coverSize: CGFloat {
        let stageH = bounds.height - scrubberHeight - textHeight
        return min(360, max(72, stageH * 0.56 * coverScale))
    }

    private var coverCenterY: CGFloat {
        let stageH = bounds.height - scrubberHeight - textHeight
        // Sit the cover above the stage's middle so the reflection has room.
        return scrubberHeight + textHeight + stageH * 0.62
    }

    // Autoresizing views never get layout() called on their own, so the
    // geometry is refreshed from every path that changes the size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        updateGeometry()
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = NSRect(x: 0, y: scrubberHeight + textHeight, width: bounds.width,
                             height: bounds.height - scrubberHeight - textHeight)
        // A subtle gradient on the stage, darker at the bottom, like iTunes.
        stage.backgroundColor = NSColor.black.cgColor
        titleLayer.frame = NSRect(x: 12, y: scrubberHeight + 20, width: bounds.width - 24, height: 18)
        artistLayer.frame = NSRect(x: 12, y: scrubberHeight + 4, width: bounds.width - 24, height: 15)
        scrubber.frame = NSRect(x: 60, y: 6, width: bounds.width - 120, height: 14)
        CATransaction.commit()
        relayout(animated: false)
    }

    // MARK: Layers

    private func rebuildLayers() {
        coverLayers.values.forEach { $0.removeFromSuperlayer() }
        coverLayers.removeAll()
    }

    private func makeCoverLayer() -> CALayer {
        let container = CALayer()
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let image = CALayer()
        image.name = "image"
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true
        image.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        image.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        image.borderWidth = 1
        container.addSublayer(image)

        let reflection = CALayer()
        reflection.name = "reflection"
        reflection.contentsGravity = .resizeAspectFill
        reflection.masksToBounds = true
        reflection.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        reflection.opacity = 0.42
        let mask = CAGradientLayer()
        mask.colors = [NSColor.black.withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        mask.startPoint = CGPoint(x: 0.5, y: 1)
        mask.endPoint = CGPoint(x: 0.5, y: 0.15)
        reflection.mask = mask
        container.addSublayer(reflection)

        setScale(container, window?.backingScaleFactor ?? 2)
        return container
    }

    private func apply(_ image: CGImage?, to container: CALayer) {
        for sub in container.sublayers ?? [] {
            if sub.name == "image" { sub.contents = image }
            if sub.name == "reflection" { sub.contents = image }
        }
    }

    private func relayout(animated: Bool) {
        guard !albums.isEmpty, bounds.width > 0 else {
            coverLayers.values.forEach { $0.isHidden = true }
            titleLayer.string = ""
            artistLayer.string = ""
            return
        }
        let size = coverSize
        let reflectionH = size * 0.55
        let lo = max(0, selectedIndex - window_)
        let hi = min(albums.count - 1, selectedIndex + window_)

        // Drop layers that fell outside the window.
        for (i, l) in coverLayers where i < lo || i > hi {
            l.removeFromSuperlayer()
            coverLayers[i] = nil
        }
        // Evict far-away decoded images.
        for i in Array(imageCache.keys) where abs(i - selectedIndex) > 40 {
            imageCache[i] = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.28)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }

        let midX = bounds.width / 2
        let cy = coverCenterY - stage.frame.minY   // in stage coordinates
        let sideGap = size * 0.72
        let sideStep = size * 0.21
        let angle: CGFloat = 62 * .pi / 180

        for i in lo...hi {
            let layer: CALayer
            if let existing = coverLayers[i] {
                layer = existing
            } else {
                layer = makeCoverLayer()
                coverLayers[i] = layer
                stage.addSublayer(layer)
                // New layers appear in place without sliding in from the origin.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.bounds = CGRect(x: 0, y: 0, width: size, height: size + reflectionH)
                CATransaction.commit()
            }
            layer.isHidden = false
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size + reflectionH)
            for sub in layer.sublayers ?? [] {
                if sub.name == "image" { sub.frame = CGRect(x: 0, y: reflectionH, width: size, height: size) }
                if sub.name == "reflection" {
                    sub.frame = CGRect(x: 0, y: 0, width: size, height: reflectionH)
                    sub.mask?.frame = sub.bounds
                    // Mirror: the reflection shows the bottom of the cover at its top.
                    sub.transform = CATransform3DMakeScale(1, -1, 1)
                    sub.contentsRect = CGRect(x: 0, y: 1 - 0.55, width: 1, height: 0.55)
                }
            }
            // The container's centre is the cover's centre, not the whole bounds'.
            layer.anchorPoint = CGPoint(x: 0.5, y: (reflectionH + size / 2) / (size + reflectionH))

            let d = i - selectedIndex
            var t = CATransform3DIdentity
            let x: CGFloat
            if d == 0 {
                x = midX
                t = CATransform3DTranslate(t, 0, 0, size * 0.25)
            } else {
                let sign: CGFloat = d < 0 ? -1 : 1
                x = midX + sign * (sideGap + CGFloat(abs(d) - 1) * sideStep)
                t = CATransform3DTranslate(t, 0, 0, -size * 0.35)
                t = CATransform3DRotate(t, -sign * angle, 0, 1, 0)
            }
            layer.position = CGPoint(x: x, y: cy)
            layer.transform = t
            // zPosition is a real z coordinate under the perspective transform
            // (eye at z = 700), so keep it tiny; it only needs to order layers.
            layer.zPosition = CGFloat(-abs(d))

            if let img = imageCache[i] {
                apply(img, to: layer)
            } else {
                apply(nil, to: layer)
                load(i)
            }
        }

        let a = albums[selectedIndex]
        titleLayer.string = a.title
        artistLayer.string = a.year.map { "\(a.artistName) · \($0)" } ?? a.artistName
        scrubber.fraction = albums.count > 1 ? CGFloat(selectedIndex) / CGFloat(albums.count - 1) : 0
        CATransaction.commit()
    }

    private func load(_ index: Int) {
        guard index < albums.count, let pid = albums[index].coverTrackId else { return }
        let gen = generation
        imageProvider(pid) { [weak self] image in
            guard let self = self, gen == self.generation, index < self.albums.count else { return }
            let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                ?? CoverFlowView.placeholder
            self.imageCache[index] = cg
            if let layer = self.coverLayers[index] {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.2)
                self.apply(cg, to: layer)
                CATransaction.commit()
            }
        }
    }

    /// A drawn placeholder: a dark square with a faint disc, no bundled art.
    private static let placeholder: CGImage = {
        let side = 256
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.17, alpha: 1))!
            .draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -90)
        NSColor(white: 1, alpha: 0.10).setStroke()
        let c = CGFloat(side) / 2
        for k in [0.36, 0.26, 0.15] as [CGFloat] {
            let r = c * k * 2
            let p = NSBezierPath(ovalIn: NSRect(x: c - r / 2, y: c - r / 2, width: r, height: r))
            p.lineWidth = 2
            p.stroke()
        }
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(ovalIn: NSRect(x: c - 5, y: c - 5, width: 10, height: 10)).fill()
        img.unlockFocus()
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }()

    // MARK: Selection

    func select(_ index: Int, animated: Bool) {
        guard !albums.isEmpty else { return }
        let clamped = min(max(0, index), albums.count - 1)
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        relayout(animated: animated)
        notifySelection()
    }

    /// Jumps to the first album whose title or artist starts with the text.
    func jump(to text: String) {
        let needle = text.lowercased()
        guard !needle.isEmpty else { return }
        if let i = albums.firstIndex(where: {
            $0.title.lowercased().hasPrefix(needle) || $0.artistName.lowercased().hasPrefix(needle)
        }) {
            select(i, animated: true)
        }
    }

    private func notifySelection() {
        onSelectionChanged(selectedIndex)
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: select(selectedIndex - 1, animated: true)               // left
        case 124: select(selectedIndex + 1, animated: true)               // right
        case 115: select(0, animated: true)                               // home
        case 119: select(albums.count - 1, animated: true)                // end
        case 116: select(selectedIndex - 10, animated: true)              // page up
        case 121: select(selectedIndex + 10, animated: true)              // page down
        case 36, 76: onOpen(selectedIndex)                                // return / enter
        default:
            if let ch = event.charactersIgnoringModifiers, ch.count == 1,
               ch.rangeOfCharacter(from: .alphanumerics) != nil {
                jump(to: ch)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard stage.frame.contains(p) else { return }
        // Hit-test against the projected layers, front-most first.
        let stagePoint = CGPoint(x: p.x - stage.frame.minX, y: p.y - stage.frame.minY)
        let candidates = coverLayers.sorted { $0.value.zPosition > $1.value.zPosition }
        for (i, layer) in candidates {
            if let hit = stage.hitTest(stagePoint), hit === layer || hit.superlayer === layer {
                if i == selectedIndex {
                    if event.clickCount == 2 { onOpen(i) }
                } else {
                    select(i, animated: true)
                }
                return
            }
        }
        // Fell through: click left or right of centre steps one.
        select(p.x < bounds.midX ? selectedIndex - 1 : selectedIndex + 1, animated: true)
    }

    override func scrollWheel(with event: NSEvent) {
        // Horizontal swipe on the trackpad, or shift-scroll on a mouse.
        let dx = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollAccumulator += dx
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 40 : 3
        while scrollAccumulator >= threshold {
            scrollAccumulator -= threshold
            select(selectedIndex - 1, animated: true)
        }
        while scrollAccumulator <= -threshold {
            scrollAccumulator += threshold
            select(selectedIndex + 1, animated: true)
        }
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = 0 }
    }

    override func magnify(with event: NSEvent) {
        coverScale = min(1.4, max(0.6, coverScale * (1 + event.magnification)))
        relayout(animated: false)
    }
}

/// The thin scrubber under the stage: drag it to fly through the albums.
final class CoverFlowScrubber: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChange: (CGFloat) -> Void = { _ in }
    private let knobW: CGFloat = 34

    private var trackRect: NSRect { NSRect(x: 0, y: bounds.midY - 4, width: bounds.width, height: 8) }

    override func mouseDown(with event: NSEvent) {
        update(event)
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            update(e)
            if e.type == .leftMouseUp { break }
        }
    }

    private func update(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let usable = bounds.width - knobW
        let f = min(1, max(0, (p.x - knobW / 2) / max(1, usable)))
        fraction = f
        onChange(f)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = trackRect
        let groove = NSBezierPath(roundedRect: t, xRadius: 4, yRadius: 4)
        NSColor(white: 0.10, alpha: 1).setFill()
        groove.fill()
        NSColor(white: 0.30, alpha: 1).setStroke()
        NSBezierPath(roundedRect: t.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()

        let x = (bounds.width - knobW) * fraction
        let k = NSRect(x: x, y: t.minY - 1, width: knobW, height: t.height + 2)
        let knob = NSBezierPath(roundedRect: k.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSGradient(starting: NSColor(white: 0.62, alpha: 1), ending: NSColor(white: 0.38, alpha: 1))!
            .draw(in: knob, angle: -90)
        NSColor(white: 0.20, alpha: 1).setStroke()
        knob.stroke()
        // Grip lines
        NSColor(white: 0.25, alpha: 0.9).setFill()
        for dx in [-4, 0, 4] as [CGFloat] {
            NSRect(x: k.midX + dx - 0.5, y: k.minY + 3, width: 1, height: k.height - 6).fill()
        }
    }
}
