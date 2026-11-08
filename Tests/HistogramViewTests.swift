import AppKit

@main struct HistogramViewTests {
    static func main() throws {
        let _ = NSApplication.shared
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        bins[0][0] = 1; bins[0][255] = 1
        bins[1][128] = 100
        bins[2] = [Int](repeating: Int.max, count: 256)
        let normalized = RGBHistogramView.normalized(bins)!
        precondition(normalized[0][0] == 0.5 && normalized[1][128] == 1)
        for channel in normalized { precondition(abs(channel.reduce(0, +) - 1) < 1e-12) }
        precondition(RGBHistogramView.normalized([]) == nil)
        precondition(RGBHistogramView.normalized([[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)) == nil)
        var negative = bins; negative[1][0] = -1
        precondition(RGBHistogramView.normalized(negative) == nil)

        let view = RGBHistogramView(frame: CGRect(x: 0, y: 0, width: 250, height: 120))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        for channel in 0..<3 {
            bins[channel] = (0..<256).map { bin in
                let distance = Double(bin - 55 - channel * 65)
                return max(0, Int(200 * exp(-distance * distance / 800)))
            }
        }
        view.bins = bins
        view.referenceBins = bins.map { channel in Array(channel.suffix(20)) + Array(channel.dropLast(20)) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Could not create native histogram representation") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), !png.isEmpty else { fatalError("Histogram did not render") }
        if CommandLine.arguments.count > 1 { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        view.bins = []; view.status = "No pixels in the selected region."
        view.cacheDisplay(in: view.bounds, to: rep)
        precondition(view.accessibilityLabel()?.contains("No pixels") == true)
        print("Histogram tests passed: channel normalization, large-count safety, malformed/empty rejection, native RGB/reference rendering, empty-state accessibility")
    }
}
