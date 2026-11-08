import AppKit

/// Compile with ComparisonCanvas.swift; exercises native pointer handling and export coordinates.
@main struct CanvasInteractionTests {
    static func main() throws {
        let _ = NSApplication.shared
        let canvas = ComparisonCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        let source = solidImage(width: 128, height: 128, red: 0, green: 0, blue: 0)
        let firstID = UUID(), secondID = UUID()
        canvas.images = [CanvasImage(id: firstID, title: "First", image: source), CanvasImage(id: secondID, title: "Second", image: source)]
        canvas.mode = .flicker; canvas.zoom = 1; canvas.pan = .zero; canvas.showPixelGrid = false

        var viewportChanges = 0
        canvas.onViewportChange = { viewportChanges += 1 }
        canvas.pan = CGPoint(x: 5, y: 4)
        precondition(viewportChanges == 1, "Direct pan did not request a viewport render")
        canvas.zoomBy(2)
        precondition(viewportChanges == 2, "Zoom/pan did not batch its viewport update")
        let patches = canvas.visibleSourceRects(overscanPoints: 48)
        precondition(patches.count == 2 && patches[firstID] == patches[secondID], "Hidden flicker candidates do not share a cache footprint")
        let zoom = canvas.zoom, pan = canvas.pan, oldChanges = viewportChanges
        canvas.togglePair()
        precondition(canvas.zoom == zoom && canvas.pan == pan && viewportChanges == oldChanges, "Flicker moved the shared view")
        let cache = canvas.images
        canvas.images = cache
        precondition(viewportChanges == oldChanges, "Display cache assignment triggered a render loop")
        canvas.pan = CGPoint(x: 10000, y: 10000)
        precondition(canvas.visibleSourceRects().values.allSatisfy(\.isEmpty), "Offscreen image was not reported empty")
        canvas.pan = .zero; canvas.zoom = 1

        func clickPoint(_ sourcePoint: CGPoint) -> CGPoint {
            // Shared envelope 128×128, single-panel viewport (13,46,274,201).
            CGPoint(x: 86 + sourcePoint.x, y: 82.5 + sourcePoint.y)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(clickPoint(point), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.tool = .brush; canvas.annotationWidth = 4
        canvas.annotationColor = NSColor(srgbRed: 1, green: 0.25, blue: 0.1, alpha: 1)
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 20)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 27, y: 22)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 34, y: 27)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 34, y: 27)))
        precondition(canvas.annotations.count == 1 && canvas.annotations[0].tool == .brush)
        precondition(canvas.annotations[0].points?.count == 3 && canvas.annotations[0].width == 4)
        precondition(canvas.annotations[0].red == 1 && abs(canvas.annotations[0].green - 0.25) < 0.001, "Brush lost the chosen color")

        canvas.tool = .text; canvas.textFontSize = 18
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 50)))
        let editor = canvas.subviews.compactMap { $0 as? NSTextField }.first!
        editor.stringValue = "Alpha"
        precondition(canvas.control(editor, textView: NSTextView(), doCommandBy: NSSelectorFromString("insertNewline:")))
        precondition(canvas.annotations.count == 2 && canvas.annotations[1].text == "Alpha" && canvas.annotations[1].fontSize == 18)
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 80)))
        let cancelEditor = canvas.subviews.compactMap { $0 as? NSTextField }.first!
        cancelEditor.stringValue = "Discard me"
        precondition(canvas.control(cancelEditor, textView: NSTextView(), doCommandBy: NSSelectorFromString("cancelOperation:")))
        precondition(canvas.annotations.count == 2, "Escape committed text")

        let exported = canvas.exportAnnotated(index: 0)!
        precondition(exported.bitsPerComponent == 32, "Annotation export quantized the image")
        let rendered = bytes(exported)
        var textPixels = 0
        for y in 48..<82 { for x in 8..<90 where rendered[(y * 128 + x) * 4] > 100 { textPixels += 1 } }
        precondition(textPixels > 40, "Text was missing or vertically flipped in export")
        precondition(bytes(canvas.exportAnnotated(index: 1)!) == rendered, "Shared annotations exported differently on matching images")

        let encoded = try JSONEncoder().encode(canvas.annotations)
        let decoded = try JSONDecoder().decode([CanvasAnnotation].self, from: encoded)
        precondition(decoded[0].points?.count == 3 && decoded[1].text == "Alpha")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CanvasAnnotation(tool: .line, start: .zero, end: CGPoint(x: 4, y: 5)))) as! [String: Any]
        legacy.removeValue(forKey: "points"); legacy.removeValue(forKey: "text"); legacy.removeValue(forKey: "fontSize")
        let old = try JSONDecoder().decode(CanvasAnnotation.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.points == nil && old.text == nil && old.fontSize == nil, "Old workspace annotations no longer decode")

        canvas.annotations = []; canvas.selection = nil; canvas.inspectionPoint = nil
        let patch = solidImage(width: 16, height: 16, red: 255, green: 0, blue: 0)
        canvas.images = [CanvasImage(id: firstID, title: "Patch", image: patch, sourceWidth: 128, sourceHeight: 128,
                                    sourceRect: CGRect(x: 20, y: 30, width: 8, height: 8), fallbackImage: source)]
        canvas.zoom = 2; canvas.pan = .zero
        let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        let display = representation.cgImage!, displayBytes = bytes(display)
        let scale = Double(display.width) / Double(canvas.bounds.width)
        let sampleX = Int(70 * scale), sampleY = Int(86.5 * scale)
        precondition(displayBytes[(sampleY * display.width + sampleX) * 4] > 220, "Viewport patch was drawn in the wrong source location")
        precondition(bytes(canvas.exportAnnotated(index: 0)!) == bytes(source), "Export used the cropped display patch instead of the full source")
        let translucent = solidImage(width: 128, height: 128, red: 255, green: 0, blue: 0, alpha: 128)
        let translucentPatch = solidImage(width: 16, height: 16, red: 255, green: 0, blue: 0, alpha: 128)
        canvas.images = [CanvasImage(id: firstID, title: "Transparency", image: translucent)]
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        let normalAlpha = bytes(representation.cgImage!)[(sampleY * display.width + sampleX) * 4]
        canvas.images = [CanvasImage(id: firstID, title: "Transparency", image: translucentPatch, sourceWidth: 128, sourceHeight: 128,
                                    sourceRect: CGRect(x: 20, y: 30, width: 8, height: 8), fallbackImage: translucent)]
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        let patchedAlpha = bytes(representation.cgImage!)[(sampleY * display.width + sampleX) * 4]
        precondition(abs(Int(normalAlpha) - Int(patchedAlpha)) <= 1, "Fallback and patch composited transparency twice")
        print("Canvas interaction tests passed: viewport callbacks/cache geometry, brush width/color, native text commit/cancel, shared Float32 exports, legacy annotation decoding, patch mapping")
    }

    static func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) -> CGImage {
        var data = [UInt8](repeating: alpha, count: width * height * 4)
        for index in stride(from: 0, to: data.count, by: 4) { data[index] = red; data[index + 1] = green; data[index + 2] = blue }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
