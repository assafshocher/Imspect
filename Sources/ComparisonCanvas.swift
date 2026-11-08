import AppKit
import QuartzCore
import CoreText

enum CompareMode: String, CaseIterable, Codable { case split, flicker, wipe }
enum CanvasTool: String, CaseIterable, Codable { case pan, inspect, select, rectangle, circle, dot, line, brush, text }

/// An already decoded display image and its original coordinate-space dimensions.
/// Resampled display caches must keep sourceWidth/sourceHeight unchanged.
struct CanvasImage {
    let id: UUID
    let title: String
    let image: CGImage
    let sourceWidth: Int
    let sourceHeight: Int
    /// Exact top-left source-coordinate footprint of a viewport-resampled bitmap.
    let sourceRect: CGRect?
    /// Full-resolution source used only beneath an old patch while a new patch is computed.
    let fallbackImage: CGImage?

    init(id: UUID, title: String, image: CGImage, sourceWidth: Int? = nil, sourceHeight: Int? = nil, sourceRect: CGRect? = nil, fallbackImage: CGImage? = nil) {
        self.id = id; self.title = title; self.image = image
        self.sourceWidth = sourceWidth ?? image.width
        self.sourceHeight = sourceHeight ?? image.height
        self.sourceRect = sourceRect; self.fallbackImage = fallbackImage
    }
}

struct CanvasAnnotation: Codable {
    var id = UUID()
    var tool: CanvasTool
    var start: CGPoint
    var end: CGPoint
    var imageID: UUID?
    /// Width in image pixels, so exported annotations agree with the canvas.
    var width: CGFloat = 1.5
    var red: CGFloat = 0.18
    var green: CGFloat = 0.91
    var blue: CGFloat = 0.79
    var alpha: CGFloat = 1
    var points: [CGPoint]?
    var text: String?
    var fontSize: CGFloat?

    init(tool: CanvasTool, start: CGPoint, end: CGPoint, imageID: UUID? = nil, width: CGFloat = 1.5) {
        self.tool = tool; self.start = start; self.end = end; self.imageID = imageID; self.width = width
    }
}

final class ComparisonCanvas: NSView, NSTextFieldDelegate {
    var images: [CanvasImage] = [] { didSet {
        if images.map(\.id) != oldValue.map(\.id) { cancelTextEntry() }
        needsDisplay = true; resetCursorRects()
    } }
    var activeIndex: Int = 0 { didSet { needsDisplay = true } }
    var referenceIndex: Int = 0 { didSet { needsDisplay = true } }
    /// Optional visual partner, independent of the ground-truth image used by metrics.
    var pairIndex: Int? = 0 { didSet { needsDisplay = true } }
    var secondaryIndex: Int = 1 { didSet { needsDisplay = true } }
    var mode: CompareMode = .split { didSet { needsDisplay = true; if mode != oldValue { viewportDidChange() } } }
    var tool: CanvasTool = .pan { didSet { if tool != oldValue { commitTextEntry() }; window?.invalidateCursorRects(for: self); needsDisplay = true } }
    var zoom: CGFloat = 1 { didSet { needsDisplay = true; if zoom != oldValue { viewportDidChange() } } }
    var pan: CGPoint = .zero { didSet { needsDisplay = true; if pan != oldValue { viewportDidChange() } } }
    var selection: CGRect? { didSet { needsDisplay = true } }
    var inspectionPoint: CGPoint? { didSet { needsDisplay = true } }
    var wipePosition: CGFloat = 0.5 { didSet { needsDisplay = true } }
    var interpolation: CGInterpolationQuality = .none { didSet { needsDisplay = true } }
    var annotations: [CanvasAnnotation] = [] { didSet { needsDisplay = true } }
    var annotateAll = true
    var annotationWidth: CGFloat = 1.5
    var annotationColor = NSColor(srgbRed: 0.18, green: 0.91, blue: 0.79, alpha: 1)
    var textFontSize: CGFloat = 24
    var showPixelGrid = true { didSet { needsDisplay = true } }
    var onChange: (() -> Void)?
    var onViewportChange: (() -> Void)?
    var onInspect: ((CGPoint) -> Void)?
    var onSelect: ((CGRect?) -> Void)?
    var onActiveImage: ((Int) -> Void)?
    var onDropURLs: (([URL]) -> Void)?
    var onPaste: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private let accent = NSColor(calibratedRed: 0.25, green: 0.89, blue: 0.77, alpha: 1)
    private let background = NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.077, alpha: 1)
    private let panelColor = NSColor(calibratedRed: 0.075, green: 0.087, blue: 0.103, alpha: 1)
    private var tracking: NSTrackingArea?
    private var dragStart: CGPoint?
    private var imageDragStart: CGPoint?
    private var dragOriginalPan: CGPoint = .zero
    private var draggedImageIndex = 0
    private var draggingWipe = false
    private var didDrag = false
    private var draftAnnotation: CanvasAnnotation?
    private var textEditor: NSTextField?
    private var pendingTextAnnotation: CanvasAnnotation?
    private var textImageID: UUID?
    private var viewportBatchDepth = 0
    private var viewportChangePending = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        layer?.drawsAsynchronously = false
        registerForDraggedTypes([.fileURL, .tiff, .png])
        setAccessibilityLabel("Synchronized image comparison canvas")
        toolTip = "Space or click: flicker pair · 1–9: select image · Tab: switch mode · arrows: pan · Option-arrows: one source pixel · ⌘-wheel / pinch / + −: zoom · F: fit · 0: 100% · V: pan · I: inspect · S: crop selection · R/C/D/L/B/T: rectangle/circle/dot/line/brush/text · Enter: place text · Escape: cancel text / clear selection · Delete: remove last annotation"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        needsDisplay = true
        if changed { viewportDidChange() }
    }

    private func viewportDidChange() {
        if viewportBatchDepth > 0 { viewportChangePending = true; return }
        updateTextEditorFrame()
        onViewportChange?()
    }

    private func withViewportUpdate(_ changes: () -> Void) {
        viewportBatchDepth += 1; changes(); viewportBatchDepth -= 1
        if viewportBatchDepth == 0, viewportChangePending {
            viewportChangePending = false; viewportDidChange()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: tool == .pan ? .openHand : .crosshair)
    }

    private var selectedIndex: Int { min(max(0, activeIndex), max(0, images.count - 1)) }
    private var leftIndex: Int { min(max(0, pairIndex ?? referenceIndex), max(0, images.count - 1)) }
    private var rightIndex: Int {
        if selectedIndex != leftIndex { return selectedIndex }
        let candidate = min(max(0, secondaryIndex), max(0, images.count - 1))
        return candidate == leftIndex && images.count > 1 ? (leftIndex + 1) % images.count : candidate
    }
    private var imageEnvelope: CGSize {
        CGSize(width: images.map(\.sourceWidth).max() ?? 1, height: images.map(\.sourceHeight).max() ?? 1)
    }

    private func panels() -> [CGRect] {
        let inset = bounds.insetBy(dx: 12, dy: 12)
        guard mode == .split, images.count > 1 else { return [inset] }
        let columns: Int
        if images.count == 2 { columns = bounds.width < 520 ? 1 : 2 }
        else { columns = max(1, Int(ceil(sqrt(Double(images.count) * max(0.8, Double(bounds.width / max(1, bounds.height))))))) }
        let actualColumns = min(images.count, columns)
        let rows = Int(ceil(Double(images.count) / Double(actualColumns)))
        let gap: CGFloat = 10
        let width = max(1, (inset.width - CGFloat(actualColumns - 1) * gap) / CGFloat(actualColumns))
        let height = max(1, (inset.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
        return (0..<images.count).map { index in
            CGRect(x: inset.minX + CGFloat(index % actualColumns) * (width + gap),
                   y: inset.minY + CGFloat(index / actualColumns) * (height + gap), width: width, height: height)
        }
    }

    private func viewport(_ panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + 1, y: panel.minY + 34, width: max(1, panel.width - 2), height: max(1, panel.height - 35))
    }
    private func imageOrigin(in viewport: CGRect) -> CGPoint {
        CGPoint(x: viewport.midX - imageEnvelope.width * zoom / 2 + pan.x,
                y: viewport.midY - imageEnvelope.height * zoom / 2 + pan.y)
    }
    private func imageRect(index: Int, in viewport: CGRect) -> CGRect {
        let origin = imageOrigin(in: viewport)
        return CGRect(origin: origin, size: CGSize(width: CGFloat(images[index].sourceWidth) * zoom, height: CGFloat(images[index].sourceHeight) * zoom))
    }
    private func panelIndex(at point: CGPoint) -> Int {
        let found = panels().firstIndex(where: { $0.contains(point) }) ?? 0
        return mode == .split ? found : selectedIndex
    }
    private func eventViewport(at point: CGPoint) -> CGRect {
        let all = panels()
        return viewport(all.first(where: { $0.contains(point) }) ?? all[0])
    }
    private func imagePoint(at point: CGPoint, viewport: CGRect) -> CGPoint {
        let origin = imageOrigin(in: viewport)
        return CGPoint(x: (point.x - origin.x) / zoom, y: (point.y - origin.y) / zoom)
    }
    private func clamped(_ p: CGPoint, for index: Int) -> CGPoint {
        guard images.indices.contains(index) else { return .zero }
        return CGPoint(x: min(max(0, p.x), CGFloat(images[index].sourceWidth)), y: min(max(0, p.y), CGFloat(images[index].sourceHeight)))
    }

    /// Source footprints for every candidate, including images hidden by flicker or wipe.
    /// Zero rectangles mean the image is fully outside the viewport. Overscan is in screen
    /// points, not source pixels, so a cache can cover a small pan without another render.
    func visibleSourceRects(overscanPoints: CGFloat = 0) -> [UUID: CGRect] {
        guard !images.isEmpty, zoom.isFinite, zoom > 0 else { return [:] }
        let allPanels = panels()
        var result: [UUID: CGRect] = [:]
        for (index, image) in images.enumerated() {
            let v = viewport(allPanels[mode == .split ? min(index, allPanels.count - 1) : 0])
            let origin = imageOrigin(in: v)
            let visible = v.insetBy(dx: -max(0, overscanPoints), dy: -max(0, overscanPoints))
            let source = CGRect(x: (visible.minX - origin.x) / zoom, y: (visible.minY - origin.y) / zoom,
                                width: visible.width / zoom, height: visible.height / zoom)
            let clipped = source.intersection(CGRect(x: 0, y: 0, width: image.sourceWidth, height: image.sourceHeight))
            result[image.id] = clipped.isNull || clipped.isEmpty ? .zero : clipped
        }
        return result
    }

    func fitImages() {
        guard !images.isEmpty else { return }
        let v = viewport(panels()[0]).insetBy(dx: 28, dy: 28)
        withViewportUpdate {
            zoom = max(0.01, min(v.width / imageEnvelope.width, v.height / imageEnvelope.height))
            pan = .zero
        }
        onChange?()
    }

    func zoomToSelection() {
        guard let selection, selection.width > 0, selection.height > 0, !images.isEmpty else { return }
        let v = viewport(panels()[0]).insetBy(dx: 24, dy: 24)
        withViewportUpdate {
            zoom = min(128, max(0.01, min(v.width / selection.width, v.height / selection.height)))
            pan = CGPoint(x: (imageEnvelope.width / 2 - selection.midX) * zoom,
                          y: (imageEnvelope.height / 2 - selection.midY) * zoom)
        }
        onChange?()
    }

    func zoomBy(_ factor: CGFloat) { zoomBy(factor, anchor: nil) }

    private func zoomBy(_ factor: CGFloat, anchor: CGPoint?) {
        guard factor.isFinite, factor > 0 else { return }
        let oldZoom = zoom
        let newZoom = min(128, max(0.01, zoom * factor))
        guard newZoom != oldZoom else { return }
        withViewportUpdate {
            if let anchor {
                let v = eventViewport(at: anchor)
                let p = imagePoint(at: anchor, viewport: v)
                zoom = newZoom
                pan = CGPoint(x: anchor.x - v.midX + (imageEnvelope.width / 2 - p.x) * zoom,
                              y: anchor.y - v.midY + (imageEnvelope.height / 2 - p.y) * zoom)
            } else {
                zoom = newZoom
                pan = CGPoint(x: pan.x * newZoom / oldZoom, y: pan.y * newZoom / oldZoom)
            }
        }
        onChange?()
    }

    func nextImage() {
        guard !images.isEmpty else { return }
        setActive((selectedIndex + 1) % images.count)
    }

    func togglePair() {
        guard images.count > 1 else { return }
        let target = selectedIndex == leftIndex ? rightIndex : leftIndex
        if selectedIndex != leftIndex { secondaryIndex = selectedIndex }
        setActive(target)
    }

    private func setActive(_ index: Int) {
        guard images.indices.contains(index) else { return }
        activeIndex = index
        if index != leftIndex { secondaryIndex = index }
        onActiveImage?(index); onChange?()
    }

    func clearAnnotations() { cancelTextEntry(); annotations.removeAll(); draftAnnotation = nil; onChange?() }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard !images.isEmpty else { drawEmpty(); return }
        context.interpolationQuality = interpolation
        let allPanels = panels()
        for (panelIndex, panel) in allPanels.enumerated() {
            let index = mode == .split ? panelIndex : selectedIndex
            let v = viewport(panel)
            panelColor.setFill(); NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).fill()
            context.saveGState()
            context.addRect(v); context.clip()
            drawChecker(in: v, context: context)
            if mode == .wipe && images.count > 1 {
                let boundary = v.minX + min(1, max(0, wipePosition)) * v.width
                context.saveGState(); context.clip(to: CGRect(x: v.minX, y: v.minY, width: max(0, boundary - v.minX), height: v.height))
                drawImage(at: leftIndex, viewport: v, context: context)
                drawOverlays(index: leftIndex, viewport: v, context: context)
                context.restoreGState()
                context.saveGState(); context.clip(to: CGRect(x: boundary, y: v.minY, width: max(0, v.maxX - boundary), height: v.height))
                drawImage(at: rightIndex, viewport: v, context: context)
                drawOverlays(index: rightIndex, viewport: v, context: context)
                context.restoreGState()
                drawWipeBoundary(x: boundary, viewport: v, context: context)
            } else {
                drawImage(at: index, viewport: v, context: context)
                drawOverlays(index: index, viewport: v, context: context)
            }
            context.restoreGState()
            drawHeader(index: index, panel: panel)
            let active = mode != .split || index == selectedIndex
            (active ? accent.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.08)).setStroke()
            let border = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            border.lineWidth = active ? 1.2 : 1; border.stroke()
        }
    }

    private func drawChecker(in viewport: CGRect, context: CGContext) {
        context.setFillColor(NSColor(calibratedWhite: 0.095, alpha: 1).cgColor); context.fill(viewport)
        let tile: CGFloat = 12
        context.setFillColor(NSColor(calibratedWhite: 0.115, alpha: 1).cgColor)
        let columns = Int(ceil(viewport.width / tile)), rows = Int(ceil(viewport.height / tile))
        for y in 0..<rows { for x in 0..<columns where (x + y).isMultiple(of: 2) {
            context.fill(CGRect(x: viewport.minX + CGFloat(x) * tile, y: viewport.minY + CGFloat(y) * tile, width: tile, height: tile))
        } }
    }

    private func drawImage(at index: Int, viewport: CGRect, context: CGContext) {
        guard images.indices.contains(index) else { return }
        let item = images[index]
        let fullRect = imageRect(index: index, in: viewport)
        context.saveGState()
        context.clip(to: fullRect)
        func bitmap(_ image: CGImage, in rect: CGRect, interpolation quality: CGInterpolationQuality) {
            guard rect.width > 0, rect.height > 0 else { return }
            context.saveGState(); context.interpolationQuality = quality
            context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        if let footprint = item.sourceRect {
            let origin = imageOrigin(in: viewport)
            let rect = CGRect(x: origin.x + footprint.minX * zoom, y: origin.y + footprint.minY * zoom,
                              width: footprint.width * zoom, height: footprint.height * zoom)
            if let fallback = item.fallbackImage {
                context.saveGState()
                // Do not draw the same translucent pixels twice under the current patch.
                let outside = CGMutablePath(); outside.addRect(fullRect)
                let covered = rect.intersection(fullRect)
                if !covered.isNull && !covered.isEmpty { outside.addRect(covered) }
                context.addPath(outside); context.clip(using: .evenOdd)
                bitmap(fallback, in: fullRect, interpolation: interpolation)
                context.restoreGState()
            }
            // This patch already has the selected kernel applied at backing-pixel density.
            bitmap(item.image, in: rect, interpolation: .none)
        } else { bitmap(item.image, in: fullRect, interpolation: interpolation) }
        context.restoreGState()
        if showPixelGrid && zoom >= 12 { drawGrid(index: index, viewport: viewport, context: context) }
    }

    private func drawGrid(index: Int, viewport: CGRect, context: CGContext) {
        let origin = imageOrigin(in: viewport)
        let x0 = max(0, Int(floor((viewport.minX - origin.x) / zoom)))
        let y0 = max(0, Int(floor((viewport.minY - origin.y) / zoom)))
        let x1 = min(images[index].sourceWidth, Int(ceil((viewport.maxX - origin.x) / zoom)))
        let y1 = min(images[index].sourceHeight, Int(ceil((viewport.maxY - origin.y) / zoom)))
        guard x0 <= x1, y0 <= y1 else { return }
        context.saveGState(); context.clip(to: imageRect(index: index, in: viewport))
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.26).cgColor)
        context.setLineWidth(0.5)
        for x in x0...x1 { let sx = origin.x + CGFloat(x) * zoom; context.move(to: CGPoint(x: sx, y: max(origin.y, viewport.minY))); context.addLine(to: CGPoint(x: sx, y: min(viewport.maxY, origin.y + CGFloat(images[index].sourceHeight) * zoom))) }
        for y in y0...y1 { let sy = origin.y + CGFloat(y) * zoom; context.move(to: CGPoint(x: max(origin.x, viewport.minX), y: sy)); context.addLine(to: CGPoint(x: min(viewport.maxX, origin.x + CGFloat(images[index].sourceWidth) * zoom), y: sy)) }
        context.strokePath(); context.restoreGState()
    }

    private func drawOverlays(index: Int, viewport: CGRect, context: CGContext) {
        let origin = imageOrigin(in: viewport)
        if let selection {
            let rect = CGRect(x: origin.x + selection.minX * zoom, y: origin.y + selection.minY * zoom, width: selection.width * zoom, height: selection.height * zoom)
            context.saveGState()
            let path = CGMutablePath(); path.addRect(viewport); path.addRect(rect)
            context.addPath(path); context.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor); context.drawPath(using: .eoFill)
            context.setStrokeColor(accent.cgColor); context.setLineWidth(1.3); context.setLineDash(phase: 0, lengths: [5, 3]); context.stroke(rect)
            context.restoreGState()
            let label = "\(Int(selection.width)) × \(Int(selection.height))  ·  (\(Int(selection.minX)), \(Int(selection.minY)))"
            drawText(label, at: CGPoint(x: rect.minX + 7, y: max(viewport.minY + 5, rect.minY - 22)), size: 10, color: accent, mono: true)
        }
        context.saveGState(); context.clip(to: imageRect(index: index, in: viewport))
        context.translateBy(x: origin.x, y: origin.y); context.scaleBy(x: zoom, y: zoom)
        for annotation in annotations where annotation.imageID == nil || annotation.imageID == images[index].id { drawAnnotation(annotation, context: context) }
        if let draftAnnotation, draftAnnotation.imageID == nil || draftAnnotation.imageID == images[index].id { drawAnnotation(draftAnnotation, context: context) }
        context.restoreGState()
        if let p = inspectionPoint, p.x >= 0, p.y >= 0, p.x < CGFloat(images[index].sourceWidth), p.y < CGFloat(images[index].sourceHeight) {
            let cx = origin.x + (floor(p.x) + 0.5) * zoom
            let cy = origin.y + (floor(p.y) + 0.5) * zoom
            context.saveGState()
            context.setLineWidth(3); context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
            crosshair(x: cx, y: cy, context: context)
            context.setLineWidth(1); context.setStrokeColor(NSColor.white.cgColor)
            crosshair(x: cx, y: cy, context: context)
            if zoom >= 6 { context.setStrokeColor(accent.cgColor); context.stroke(CGRect(x: origin.x + floor(p.x) * zoom, y: origin.y + floor(p.y) * zoom, width: zoom, height: zoom)) }
            context.restoreGState()
        }
    }

    private func crosshair(x: CGFloat, y: CGFloat, context: CGContext) {
        context.move(to: CGPoint(x: x - 12, y: y)); context.addLine(to: CGPoint(x: x - 4, y: y))
        context.move(to: CGPoint(x: x + 4, y: y)); context.addLine(to: CGPoint(x: x + 12, y: y))
        context.move(to: CGPoint(x: x, y: y - 12)); context.addLine(to: CGPoint(x: x, y: y - 4))
        context.move(to: CGPoint(x: x, y: y + 4)); context.addLine(to: CGPoint(x: x, y: y + 12)); context.strokePath()
    }

    private func drawAnnotation(_ annotation: CanvasAnnotation, context: CGContext) {
        context.saveGState()
        let color = NSColor(calibratedRed: annotation.red, green: annotation.green, blue: annotation.blue, alpha: annotation.alpha).cgColor
        context.setStrokeColor(color); context.setFillColor(color); context.setLineWidth(annotation.width); context.setLineCap(.round); context.setLineJoin(.round)
        let rect = CGRect(x: min(annotation.start.x, annotation.end.x), y: min(annotation.start.y, annotation.end.y), width: abs(annotation.end.x - annotation.start.x), height: abs(annotation.end.y - annotation.start.y))
        switch annotation.tool {
        case .rectangle: context.stroke(rect)
        case .circle: context.strokeEllipse(in: rect)
        case .line: context.move(to: annotation.start); context.addLine(to: annotation.end); context.strokePath()
        case .brush:
            let points = annotation.points ?? [annotation.start, annotation.end]
            if points.count <= 1 {
                let p = points.first ?? annotation.start, radius = annotation.width / 2
                context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            } else {
                context.move(to: points[0]); context.addLines(between: points); context.strokePath()
            }
        case .text:
            if let text = annotation.text, !text.isEmpty {
                let size = annotation.fontSize ?? 24
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + max(CTFontGetLeading(font), size * 0.15)
                context.translateBy(x: annotation.start.x, y: annotation.start.y); context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let string = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
                    context.textPosition = CGPoint(x: 0, y: -CTFontGetAscent(font) - CGFloat(index) * lineHeight)
                    CTLineDraw(CTLineCreateWithAttributedString(string), context)
                }
            }
        case .dot:
            let r = max(0.5, annotation.width)
            context.fillEllipse(in: CGRect(x: annotation.start.x - r, y: annotation.start.y - r, width: r * 2, height: r * 2))
        default: break
        }
        context.restoreGState()
    }

    private func drawWipeBoundary(x: CGFloat, viewport: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor); context.setLineWidth(4)
        context.move(to: CGPoint(x: x, y: viewport.minY)); context.addLine(to: CGPoint(x: x, y: viewport.maxY)); context.strokePath()
        context.setStrokeColor(accent.cgColor); context.setLineWidth(1.5)
        context.move(to: CGPoint(x: x, y: viewport.minY)); context.addLine(to: CGPoint(x: x, y: viewport.maxY)); context.strokePath()
        let handle = CGRect(x: x - 13, y: viewport.midY - 20, width: 26, height: 40)
        context.setFillColor(panelColor.cgColor); context.addPath(CGPath(roundedRect: handle, cornerWidth: 10, cornerHeight: 10, transform: nil)); context.fillPath()
        context.setStrokeColor(accent.cgColor); context.setLineWidth(1.5)
        for offset: CGFloat in [-3, 3] { context.move(to: CGPoint(x: x + offset, y: viewport.midY - 7)); context.addLine(to: CGPoint(x: x + offset, y: viewport.midY + 7)) }; context.strokePath()
        context.restoreGState()
    }

    private func drawHeader(index: Int, panel: CGRect) {
        let title: String
        if mode == .wipe && images.count > 1 { title = "\(leftIndex + 1)  \(images[leftIndex].title)    ↔    \(rightIndex + 1)  \(images[rightIndex].title)" }
        else { title = "\(index + 1)  \(images[index].title)" }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1)]
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
        var attrs = attributes; attrs[.paragraphStyle] = style
        (title as NSString).draw(in: CGRect(x: panel.minX + 12, y: panel.minY + 9, width: max(5, panel.width - 110), height: 18), withAttributes: attrs)
        let info = index == referenceIndex && mode != .wipe ? "REFERENCE" : "\(images[index].sourceWidth) × \(images[index].sourceHeight)"
        let size = (info as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)])
        drawText(info, at: CGPoint(x: panel.maxX - size.width - 12, y: panel.minY + 11), size: 9, color: index == referenceIndex ? accent : .secondaryLabelColor, mono: true)
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, mono: Bool = false) {
        (text as NSString).draw(at: point, withAttributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium) : NSFont.systemFont(ofSize: size, weight: .regular), .foregroundColor: color])
    }

    private func drawEmpty() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY - 45)
        for (offset, alpha) in [(CGFloat(-10), CGFloat(0.25)), (CGFloat(10), CGFloat(0.8))] {
            accent.withAlphaComponent(alpha).setStroke()
            let rect = NSBezierPath(roundedRect: CGRect(x: center.x - 37 + offset, y: center.y - 45 + offset, width: 74, height: 62), xRadius: 9, yRadius: 9)
            rect.lineWidth = 1.5; rect.stroke()
        }
        let title = "A closer look, together."
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        (title as NSString).draw(at: CGPoint(x: center.x - titleSize.width / 2, y: center.y + 45), withAttributes: titleAttrs)
        for (row, text) in ["Drop images here, open files, or paste from your clipboard.", "Every pixel, crop, and movement stays in sync."].enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: row == 0 ? 0.6 : 0.42, alpha: 1)]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y + 84 + CGFloat(row) * 24), withAttributes: attrs)
        }
    }

    private func styledAnnotation(tool: CanvasTool, start: CGPoint, end: CGPoint, index: Int) -> CanvasAnnotation {
        var annotation = CanvasAnnotation(tool: tool, start: start, end: end, imageID: annotateAll ? nil : images[index].id, width: annotationWidth)
        let color = annotationColor.usingColorSpace(.sRGB) ?? annotationColor
        annotation.red = color.redComponent; annotation.green = color.greenComponent
        annotation.blue = color.blueComponent; annotation.alpha = color.alphaComponent
        return annotation
    }

    private func beginTextEntry(at point: CGPoint, index: Int) {
        cancelTextEntry()
        var annotation = styledAnnotation(tool: .text, start: point, end: point, index: index)
        annotation.fontSize = min(10000, max(0.1, textFontSize))
        pendingTextAnnotation = annotation; textImageID = images[index].id
        let field = NSTextField(string: "")
        field.placeholderString = "Type text, then press Enter"
        field.font = .systemFont(ofSize: min(96, max(12, (annotation.fontSize ?? 24) * zoom)))
        field.textColor = annotationColor; field.drawsBackground = true; field.backgroundColor = background.withAlphaComponent(0.96)
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.delegate = self; field.target = self; field.action = #selector(commitTextField(_:))
        field.focusRingType = .none; field.setAccessibilityLabel("Annotation text. Enter to place, Escape to cancel.")
        textEditor = field; addSubview(field); updateTextEditorFrame()
        window?.makeFirstResponder(field)
    }

    private func updateTextEditorFrame() {
        guard let field = textEditor, let annotation = pendingTextAnnotation, let id = textImageID,
              let index = images.firstIndex(where: { $0.id == id }) else { return }
        let allPanels = panels(), v = viewport(allPanels[mode == .split ? min(index, allPanels.count - 1) : 0])
        let origin = imageOrigin(in: v)
        let x = min(max(v.minX + 5, origin.x + annotation.start.x * zoom), max(v.minX + 5, v.maxX - 180))
        let y = min(max(v.minY + 5, origin.y + annotation.start.y * zoom), max(v.minY + 5, v.maxY - 40))
        field.font = .systemFont(ofSize: min(96, max(12, (annotation.fontSize ?? 24) * zoom)))
        let height = min(max(30, (field.font?.pointSize ?? 24) * 1.3 + 8), max(30, v.maxY - y - 4))
        field.frame = CGRect(x: x, y: y, width: min(480, max(120, v.maxX - x - 6)), height: height)
    }

    @objc private func commitTextField(_ sender: NSTextField) { commitTextEntry() }

    func commitTextEntry() {
        guard let field = textEditor, var annotation = pendingTextAnnotation else { return }
        let value = String(field.stringValue.prefix(4096))
        cancelTextEntry()
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotation.text = value; annotations.append(annotation); onChange?()
        }
    }

    func cancelTextEntry() {
        let field = textEditor
        textEditor = nil; pendingTextAnnotation = nil; textImageID = nil
        field?.delegate = nil; field?.abortEditing(); field?.removeFromSuperview()
        if field != nil { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == NSSelectorFromString("insertNewline:") { commitTextEntry(); return true }
        if commandSelector == NSSelectorFromString("cancelOperation:") { cancelTextEntry(); return true }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) { commitTextEntry() }

    override func mouseDown(with event: NSEvent) {
        commitTextEntry()
        window?.makeFirstResponder(self)
        guard !images.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let v = eventViewport(at: point)
        let index = panelIndex(at: point)
        draggedImageIndex = index
        if mode == .split { setActive(index) }
        dragStart = point; dragOriginalPan = pan; didDrag = false
        imageDragStart = clamped(imagePoint(at: point, viewport: v), for: index)
        if mode == .wipe && images.count > 1 && abs(point.x - (v.minX + wipePosition * v.width)) <= 15 {
            draggingWipe = true; return
        }
        guard v.contains(point) else { dragStart = nil; return }
        switch tool {
        case .inspect: inspect(at: point)
        case .select: selection = nil
        case .rectangle, .circle, .line, .dot, .brush:
            guard let p = imageDragStart else { break }
            let start = tool == .dot ? CGPoint(x: floor(p.x) + 0.5, y: floor(p.y) + 0.5) : p
            draftAnnotation = styledAnnotation(tool: tool, start: start, end: start, index: index)
            if tool == .brush { draftAnnotation?.points = [start] }
        case .text:
            if let p = imageDragStart { beginTextEntry(at: p, index: index) }
        case .pan: NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, !images.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let all = panels()
        let v = viewport(all[mode == .split ? min(draggedImageIndex, all.count - 1) : 0])
        if hypot(point.x - start.x, point.y - start.y) > 2 { didDrag = true }
        if draggingWipe {
            wipePosition = min(1, max(0, (point.x - v.minX) / v.width)); onChange?(); return
        }
        switch tool {
        case .pan:
            pan = CGPoint(x: dragOriginalPan.x + point.x - start.x, y: dragOriginalPan.y + point.y - start.y)
            onChange?()
        case .inspect: inspect(at: point)
        case .select:
            if let p0 = imageDragStart {
                let p1 = clamped(imagePoint(at: point, viewport: v), for: draggedImageIndex)
                selection = CGRect(x: floor(min(p0.x, p1.x)), y: floor(min(p0.y, p1.y)), width: ceil(max(p0.x, p1.x)) - floor(min(p0.x, p1.x)), height: ceil(max(p0.y, p1.y)) - floor(min(p0.y, p1.y)))
            }
        case .rectangle, .circle, .line:
            draftAnnotation?.end = clamped(imagePoint(at: point, viewport: v), for: draggedImageIndex); needsDisplay = true
        case .brush:
            let p = clamped(imagePoint(at: point, viewport: v), for: draggedImageIndex)
            if let last = draftAnnotation?.points?.last, hypot(p.x - last.x, p.y - last.y) >= 0.5 / max(zoom, 0.01), (draftAnnotation?.points?.count ?? 0) < 100000 {
                draftAnnotation?.points?.append(p); draftAnnotation?.end = p; needsDisplay = true
            }
        case .dot, .text: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; imageDragStart = nil; draggingWipe = false; didDrag = false; window?.invalidateCursorRects(for: self) }
        guard dragStart != nil, !images.isEmpty else { return }
        if draggingWipe { onChange?(); return }
        if tool == .brush, let last = draftAnnotation?.points?.last, (draftAnnotation?.points?.count ?? 0) < 100000 {
            let allPanels = panels(), v = viewport(allPanels[mode == .split ? min(draggedImageIndex, allPanels.count - 1) : 0])
            let p = clamped(imagePoint(at: convert(event.locationInWindow, from: nil), viewport: v), for: draggedImageIndex)
            if hypot(p.x - last.x, p.y - last.y) > 0.01 / max(zoom, 0.01) { draftAnnotation?.points?.append(p); draftAnnotation?.end = p }
        }
        if let draftAnnotation {
            if draftAnnotation.tool == .dot || draftAnnotation.tool == .brush || didDrag { annotations.append(draftAnnotation) }
            self.draftAnnotation = nil; needsDisplay = true; onChange?()
        }
        if tool == .select {
            if selection?.width ?? 0 < 1 || selection?.height ?? 0 < 1 { selection = nil }
            onSelect?(selection); onChange?()
        }
        if tool == .pan, !didDrag, mode == .flicker { togglePair() }
    }

    private func inspect(at point: CGPoint) {
        let p = imagePoint(at: point, viewport: eventViewport(at: point))
        let rounded = CGPoint(x: floor(p.x), y: floor(p.y))
        if inspectionPoint != rounded { inspectionPoint = rounded; onInspect?(rounded); onChange?() }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !images.isEmpty else { return }
        if tool == .inspect { inspect(at: convert(event.locationInWindow, from: nil)) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            zoomBy(exp(event.scrollingDeltaY * 0.015), anchor: convert(event.locationInWindow, from: nil))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            withViewportUpdate {
                pan.x += event.scrollingDeltaX * multiplier; pan.y += event.scrollingDeltaY * multiplier
            }
            onChange?()
        }
    }

    override func magnify(with event: NSEvent) { zoomBy(max(0.1, 1 + event.magnification), anchor: convert(event.locationInWindow, from: nil)) }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            if key == "v" { onPaste?(); return }
            super.keyDown(with: event); return
        }
        if let number = Int(key), number > 0, number <= min(images.count, 9) { setActive(number - 1); return }
        let step: CGFloat = event.modifierFlags.contains(.option) ? zoom : (event.modifierFlags.contains(.shift) ? 100 : 24)
        switch event.keyCode {
        case 123: pan.x += step
        case 124: pan.x -= step
        case 125: pan.y -= step
        case 126: pan.y += step
        case 49: togglePair(); return
        case 48:
            let modes = CompareMode.allCases
            mode = modes[((modes.firstIndex(of: mode) ?? 0) + 1) % modes.count]
        case 53: cancelTextEntry(); selection = nil; inspectionPoint = nil; draftAnnotation = nil; onSelect?(nil)
        case 51, 117:
            if !annotations.isEmpty { annotations.removeLast() }
        default:
            switch key {
            case "+", "=": zoomBy(1.25); return
            case "-", "_": zoomBy(0.8); return
            case "f": fitImages(); return
            case "n", "]": nextImage(); return
            case "[": if !images.isEmpty { setActive((selectedIndex + images.count - 1) % images.count) }; return
            case "v": tool = .pan
            case "i": tool = .inspect
            case "s": tool = .select
            case "r": tool = .rectangle
            case "c": tool = .circle
            case "d": tool = .dot
            case "l": tool = .line
            case "b": tool = .brush
            case "t": tool = .text
            case "0": withViewportUpdate { zoom = 1; pan = .zero }
            default: super.keyDown(with: event); return
            }
        }
        onChange?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropURLs?(urls); return true
        }
        // Image-only drops are exposed separately, so the app need not overwrite the clipboard.
        if let data = sender.draggingPasteboard.data(forType: .png) ?? sender.draggingPasteboard.data(forType: .tiff) {
            onDropImageData?(data); return true
        }
        return false
    }

    var onDropImageData: ((Data) -> Void)?

    /// Original source-resolution image plus annotations. Selection and inspection guides are not baked in.
    /// A caller using display caches should supply originalImage to avoid exporting the display resample.
    func exportAnnotated(index: Int) -> CGImage? { exportAnnotated(index: index, originalImage: nil) }

    func exportAnnotated(index: Int, originalImage: CGImage?) -> CGImage? {
        guard images.indices.contains(index) else { return nil }
        let item = images[index]
        guard item.sourceRect == nil || originalImage != nil || item.fallbackImage != nil else { return nil }
        let source = originalImage ?? item.fallbackImage ?? item.image
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: item.sourceWidth, height: item.sourceHeight, bitsPerComponent: 32, bytesPerRow: item.sourceWidth * 16, space: space, bitmapInfo: info) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: item.sourceWidth, height: item.sourceHeight))
        context.translateBy(x: 0, y: CGFloat(item.sourceHeight)); context.scaleBy(x: 1, y: -1)
        for annotation in annotations where annotation.imageID == nil || annotation.imageID == item.id { drawAnnotation(annotation, context: context) }
        return context.makeImage()
    }
}
