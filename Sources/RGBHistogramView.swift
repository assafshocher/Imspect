import AppKit

/// A probability histogram of encoded sRGB samples. Every RGB channel has unit mass;
/// current and optional reference curves share the same vertical scale.
final class RGBHistogramView: NSView {
    var bins: [[Int]] = [] { didSet { needsDisplay = true; updateAccessibilitySummary() } }
    var referenceBins: [[Int]]? { didSet { needsDisplay = true; updateAccessibilitySummary() } }
    var status = "Choose an image to see its histogram." { didSet { needsDisplay = true; updateAccessibilitySummary() } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 120) }

    private let colors = [NSColor(srgbRed: 1, green: 0.38, blue: 0.38, alpha: 1),
                          NSColor(srgbRed: 0.35, green: 0.85, blue: 0.57, alpha: 1),
                          NSColor(srgbRed: 0.35, green: 0.63, blue: 1, alpha: 1)]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        toolTip = "Encoded sRGB histogram. Each channel sums to 100%; the shared vertical scale is the fraction of pixels in each bin. X: 0–255. Dashed curves, when present, show the reference image."
        updateAccessibilitySummary()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Kept independent of drawing so counts and shared scaling can be checked numerically.
    static func normalized(_ bins: [[Int]]) -> [[Double]]? {
        guard bins.count == 3, bins.allSatisfy({ $0.count == 256 && $0.allSatisfy({ $0 >= 0 }) }) else { return nil }
        var result: [[Double]] = []
        for channel in bins {
            let total = channel.reduce(0.0) { $0 + Double($1) }
            guard total > 0, total.isFinite else { return nil }
            result.append(channel.map { Double($0) / total })
        }
        return result
    }

    private func updateAccessibilitySummary() {
        guard let normalized = Self.normalized(bins) else { setAccessibilityLabel("RGB histogram. " + status); return }
        let peak = normalized.flatMap { $0 }.max() ?? 0
        let reference = referenceBins.flatMap(Self.normalized) != nil ? " Dashed reference curves are included." : ""
        setAccessibilityLabel(String(format: "Encoded sRGB histogram. X axis 0 to 255. Each channel sums to 100 percent. Current peak %.2f percent per bin.", peak * 100) + reference)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: 0.075, alpha: 1).setFill(); background.fill()
        NSColor.white.withAlphaComponent(0.08).setStroke(); background.lineWidth = 1; background.stroke()
        guard bounds.width >= 100, bounds.height >= 65 else { return }

        guard let current = Self.normalized(bins) else {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (status as NSString).draw(in: bounds.insetBy(dx: 14, dy: max(12, bounds.height / 2 - 16)), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 1), .paragraphStyle: paragraph
            ])
            return
        }
        let reference = referenceBins.flatMap(Self.normalized)
        let maximum = max(current.flatMap { $0 }.max() ?? 0, reference?.flatMap { $0 }.max() ?? 0)
        guard maximum > 0 else { return }
        let plot = CGRect(x: 12, y: 30, width: bounds.width - 24, height: bounds.height - 52)
        for (index, name) in ["R", "G", "B"].enumerated() {
            text(name, point: CGPoint(x: 12 + CGFloat(index) * 22, y: 9), color: colors[index], size: 9, weight: .semibold)
        }
        if reference != nil { text("REF ┄", point: CGPoint(x: 82, y: 9), color: NSColor(calibratedWhite: 0.58, alpha: 1), size: 9) }
        let peak = String(format: "peak %.2g%% / bin", maximum * 100)
        let peakWidth = (peak as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)]).width
        text(peak, point: CGPoint(x: bounds.maxX - 12 - peakWidth, y: 10), color: NSColor(calibratedWhite: 0.58, alpha: 1), size: 8, monospaced: true)

        NSColor.white.withAlphaComponent(0.07).setStroke()
        for fraction: CGFloat in [0, 0.5, 1] {
            let y = plot.maxY - plot.height * fraction
            let grid = NSBezierPath(); grid.lineWidth = 0.6
            grid.move(to: CGPoint(x: plot.minX, y: y)); grid.line(to: CGPoint(x: plot.maxX, y: y)); grid.stroke()
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.clip(to: plot.insetBy(dx: -1, dy: -1))
        for channel in 0..<3 {
            let path = pathFor(current[channel], maximum: maximum, plot: plot)
            let fill = path.copy() as! NSBezierPath
            fill.line(to: CGPoint(x: plot.maxX, y: plot.maxY)); fill.line(to: CGPoint(x: plot.minX, y: plot.maxY)); fill.close()
            colors[channel].withAlphaComponent(0.08).setFill(); fill.fill()
            colors[channel].withAlphaComponent(0.95).setStroke(); path.lineWidth = 1.15; path.stroke()
        }
        if let reference {
            for channel in 0..<3 {
                let path = pathFor(reference[channel], maximum: maximum, plot: plot)
                path.lineWidth = 1; path.setLineDash([3, 3], count: 2, phase: 0)
                colors[channel].withAlphaComponent(0.6).setStroke(); path.stroke()
            }
        }
        context.restoreGState()

        for value in [0, 128, 255] {
            let label = String(value), font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            let center = plot.minX + CGFloat(value) / 255 * plot.width
            let x = value == 0 ? plot.minX : value == 255 ? plot.maxX - width : center - width / 2
            text(label, point: CGPoint(x: x, y: plot.maxY + 6), color: NSColor(calibratedWhite: 0.58, alpha: 1), size: 8, monospaced: true)
        }
    }

    private func pathFor(_ values: [Double], maximum: Double, plot: CGRect) -> NSBezierPath {
        let path = NSBezierPath(); path.lineJoinStyle = .round; path.lineCapStyle = .round
        for (bin, frequency) in values.enumerated() {
            let point = CGPoint(x: plot.minX + CGFloat(bin) / 255 * plot.width, y: plot.maxY - CGFloat(frequency / maximum) * plot.height)
            if bin == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        return path
    }

    private func text(_ string: String, point: CGPoint, color: NSColor, size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) {
        (string as NSString).draw(at: point, withAttributes: [
            .font: monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ])
    }
}
