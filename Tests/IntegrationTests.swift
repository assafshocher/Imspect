import AppKit
import Foundation

/// Runs the actual controller and persistence layer without opening dialogs or network connections.
/// Compile every Sources/*.swift except main.swift together with this file.
@main struct IntegrationTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func close(_ a: Double, _ b: Double, tolerance: Double = 1e-6) -> Bool { abs(a-b) <= tolerance }
    static func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(condition(),message)
    }
    static func mustThrow(_ message: String, _ body: () throws -> Void) {
        do { try body(); expect(false,message) } catch { expect(true,message) }
    }
    static func buffer(width: Int = 19, height: Int = 17, offset: Float = 0) -> PixelBuffer {
        var rgba = [Float](repeating: 1, count: width*height*4)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            rgba[(y*width+x)*4+c] = 0.15 + Float((x*7+y*13+c*19)%101)/180 + offset
        } } }
        return PixelBuffer(width:width,height:height,rgba:rgba)
    }
    static func renderedBuffer(_ controller: WorkspaceController, crop: Bool = false) throws -> PixelBuffer {
        guard let image = controller.renderedImage(crop:crop), let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else {
            throw ImageEngineError.message("The controller returned no rendered image.")
        }
        return try PixelBuffer.from(cgImage:cg)
    }
    static func maximumError(_ a: PixelBuffer, _ b: PixelBuffer) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        return zip(a.rgba,b.rgba).reduce(0) { max($0,abs(Double($1.0)-Double($1.1))) }
    }
    static func install(_ controller: WorkspaceController, buffers: [PixelBuffer]) {
        controller.entries = buffers.enumerated().map { ImageEntry(title:"Image \($0.offset+1)",buffer:$0.element) }
        controller.canvas.activeIndex = min(1,buffers.count-1)
        controller.canvas.referenceIndex = 0; controller.canvas.secondaryIndex = min(1,buffers.count-1)
        controller.canvas.pairIndex = 0; controller.canvas.selection = nil; controller.canvas.annotations = []
        controller.undoSnapshots = []; controller.redoSnapshots = []; controller.canvas.zoom = 1
        controller.refreshEntries()
        waitUntil("Initial comparison metrics finish") { controller.cachedMetrics.count == buffers.count }
    }
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let controller = WorkspaceController()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        expect(controller.window != nil && controller.modeControl.segmentCount == 3,"Native window and three comparison modes instantiate")
        controller.loadDemo()
        waitUntil("Demo metrics finish") { controller.cachedMetrics.count == 3 }
        if let option = CommandLine.arguments.firstIndex(of:"--snapshot"), CommandLine.arguments.count > option+1 {
            let view = controller.window!.contentView!
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ImageEngineError.message("Could not allocate a view rendering.") }
            controller.window?.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in:view.bounds,to:bitmap)
            }
            guard let png = bitmap.representation(using:.png,properties:[:]) else { throw ImageEngineError.message("Could not encode the rendered view.") }
            try png.write(to:URL(fileURLWithPath:CommandLine.arguments[option+1]))
            print("Rendered native content view: \(Int(view.bounds.width))×\(Int(view.bounds.height)) points")
            return
        }
        expect(controller.entries.count == 3 && controller.entries[0].buffer.width == 640,"Demo populates three full-resolution images")
        expect(controller.cachedMetrics[1].1 != nil && controller.cachedMetrics[2].1 != nil,"Demo metrics are computed for both candidates")
        let demoNoise = try ImageEngine.filter(controller.entries[0].buffer,kind:"noise",amount:0.04,seed:42)
        expect(demoNoise.rgba == controller.entries[1].buffer.rgba,"Demo noise exactly reproduces declared seed and sigma")

        let original = buffer(), candidate = buffer(offset:0.025)
        install(controller,buffers:[original,candidate])
        waitUntil("Initial RGB histograms finish") { controller.histogramCache.count == 2 }
        expect(controller.histogramView.bins.count == 3 && controller.histogramView.bins.allSatisfy { $0.reduce(0,+) == 19*17 },"Histogram contains every source pixel in each RGB channel")
        let histogramGenerationBeforeSelection = controller.histogramGeneration
        controller.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        expect(controller.histogramView.bins == controller.histogramCache[controller.entries[0].id],"Selecting an image updates its histogram immediately")
        expect(controller.histogramGeneration == histogramGenerationBeforeSelection,"Selecting an image reuses cached histogram counts")
        controller.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        controller.histogramOverlay.state = .on; controller.histogramOverlayChanged()
        expect(controller.histogramView.referenceBins == controller.histogramCache[controller.entries[0].id],"Reference histogram overlay uses the selected ground truth")
        if let normalized = RGBHistogramView.normalized(controller.histogramView.bins) {
            expect(normalized.allSatisfy { close($0.reduce(0,+),1,tolerance:1e-12) },"Each RGB histogram curve has unit probability mass")
        } else { expect(false,"Histogram probabilities are valid") }
        let known = controller.cachedMetrics[1].1!
        expect(close(known.mse,0.000625,tolerance:1e-8),"Controller's ground-truth comparison reports known RGB MSE")
        controller.canvas.selection = CGRect(x:3,y:2,width:11,height:12)
        controller.canvas.onSelect?(controller.canvas.selection)
        expect(controller.cachedMetrics.isEmpty,"Metric cache is immediately invalidated when ROI changes")
        waitUntil("ROI metrics finish") { controller.cachedMetrics.count == 2 }
        waitUntil("Region RGB histograms finish") { controller.histogramCache.count == 2 }
        expect(controller.histogramView.bins.allSatisfy { $0.reduce(0,+) == 132 },"Histogram uses the matched selected region")
        expect(controller.cachedMetrics[1].1?.pixelCount == 132,"Controller measures the selected crop only")
        expect(controller.cachedMetrics[1].1?.ssim != nil,"An 11×12 ROI retains valid Gaussian SSIM")
        let crop = try renderedBuffer(controller,crop:true)
        expect(crop.width == 11 && crop.height == 12,"Crop copy has exact selected dimensions")
        let expectedCrop = try candidate.cropped(controller.canvas.selection!)
        expect(maximumError(crop,expectedCrop) < 1e-6,"Crop copy retains source coordinates and values: error=\(maximumError(crop,expectedCrop)), active=\(controller.canvas.activeIndex), first=\(crop.rgba.prefix(4)), expected=\(expectedCrop.rgba.prefix(4))")
        controller.clearSelection()
        waitUntil("Full-image metrics restored") { controller.cachedMetrics.count == 2 }

        let rendered = try renderedBuffer(controller)
        expect(maximumError(rendered,candidate) < 1e-6,"Unannotated render preserves Float sample precision")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("imspect-integration-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:scratch) }
        let pngURL = scratch.appendingPathComponent("precise.png")
        try rendered.pngData()!.write(to:pngURL)
        let exported = try PixelBuffer.load(url:pngURL)
        expect(maximumError(exported,candidate) < 0.00002,"Controller source export retains 16-bit PNG precision")
        // The chosen fractional value is far from an 8-bit grid: this catches accidental 8-bit rasterization.
        expect(abs(Double(exported.rgba[0])*255-(Double(exported.rgba[0])*255).rounded()) > 0.1,"PNG export did not quantize the image to 8 bits")

        let zoomBefore = controller.canvas.zoom, panBefore = controller.canvas.pan
        controller.canvas.togglePair(); controller.canvas.togglePair()
        expect(controller.canvas.activeIndex == 1,"Flicker returns to the selected candidate")
        expect(controller.canvas.zoom == zoomBefore && controller.canvas.pan == panBefore,"Pair flicker does not change viewport registration")
        controller.kernelControl.selectItem(at:2)
        let histogramGenerationBeforeZoom = controller.histogramGeneration
        let beforeFractionalPreview = controller.canvas.images[1].image
        controller.canvas.zoom = 1.37; controller.refreshDisplayCache(force:true)
        let scale = controller.canvas.zoom * (controller.window?.backingScaleFactor ?? 2)
        waitUntil("Fractional-scale viewport preview finishes") { controller.displayCompletedGeneration == controller.displayGeneration && controller.canvas.images.count == 2 && controller.canvas.images[1].sourceRect != nil && controller.canvas.images[1].image !== beforeFractionalPreview }
        let fractionalPatch = controller.canvas.images[1]
        let displayed = try PixelBuffer.from(cgImage:fractionalPatch.image)
        let footprint = fractionalPatch.sourceRect!
        let expectedPreview = try ImageEngine.resampleViewport(candidate,sourceRect:footprint,width:fractionalPatch.image.width,height:fractionalPatch.image.height,kernel:.cubic)
        let displayExpected = try PixelBuffer.from(cgImage:expectedPreview.cgImage())
        expect(maximumError(displayed,displayExpected) < 3e-6,"Preview samples the declared fractional source footprint")
        expect(close(Double(fractionalPatch.image.width)/Double(footprint.width),Double(scale),tolerance:1e-6),"Viewport output retains requested zoom without dimension-rounding drift")
        expect(fractionalPatch.sourceWidth == candidate.width,"Resampled preview preserves source pixel coordinates")
        expect(controller.histogramGeneration == histogramGenerationBeforeZoom,"Zooming does not recompute source histograms")

        controller.canvas.zoom = 64; controller.canvas.pan = .zero
        controller.kernelControl.selectItem(at:0)
        let priorPatch = controller.canvas.images[1].image
        controller.refreshDisplayCache(force:true)
        waitUntil("Nearest preview finishes at high zoom") { controller.displayCompletedGeneration == controller.displayGeneration && controller.canvas.images[1].sourceRect != nil && controller.canvas.images[1].image !== priorPatch }
        let nearestAtHighZoom = controller.canvas.images[1]
        expect(nearestAtHighZoom.sourceRect!.width < CGFloat(candidate.width),"High-zoom reconstruction is limited to the visible patch")
        controller.kernelControl.selectItem(at:2); controller.kernelChanged()
        waitUntil("Cubic preview finishes at high zoom") { controller.displayCompletedGeneration == controller.displayGeneration && controller.canvas.images[1].sourceRect != nil && controller.canvas.images[1].image !== nearestAtHighZoom.image }
        let cubicAtHighZoom = controller.canvas.images[1]
        let nearestPixels = try PixelBuffer.from(cgImage:nearestAtHighZoom.image), cubicPixels = try PixelBuffer.from(cgImage:cubicAtHighZoom.image)
        expect(nearestPixels.width == cubicPixels.width && nearestPixels.height == cubicPixels.height,"Changing interpolation preserves viewport bitmap dimensions")
        expect(maximumError(nearestPixels,cubicPixels) > 0.01,"Changing nearest to cubic visibly changes the image at high zoom")
        let highZoomExpected = try ImageEngine.resampleViewport(candidate,sourceRect:cubicAtHighZoom.sourceRect!,width:cubicAtHighZoom.image.width,height:cubicAtHighZoom.image.height,kernel:.cubic)
        let clippedHighZoomExpected = try PixelBuffer.from(cgImage:highZoomExpected.cgImage())
        expect(maximumError(cubicPixels,clippedHighZoomExpected) < 3e-6,"High-zoom display uses the selected cubic kernel without a nearest fallback")

        controller.canvas.zoom = 1
        controller.visualization = "Centered FFT magnitude"; controller.updateAnalysis()
        expect(controller.cachedMetrics.isEmpty,"Source metric cache is unavailable in the FFT coordinate space")
        waitUntil("FFT analysis finishes") { controller.analysisImages.count == 2 }
        waitUntil("FFT preview uses padded geometry") { controller.canvas.images.count == 2 && controller.canvas.images[1].sourceWidth == 32 && controller.canvas.images[1].sourceHeight == 32 }
        expect(controller.analysisImages[controller.entries[1].id]?.width == 32,"FFT output retains its power-of-two dimensions")
        let spectrumExport = try renderedBuffer(controller)
        expect(spectrumExport.width == 32 && spectrumExport.height == 32,"FFT export preserves spectrum dimensions")
        controller.visualization = "Images"; controller.updateAnalysis()
        waitUntil("Source metrics return from FFT") { controller.cachedMetrics.count == 2 }
        waitUntil("Source geometry returns from FFT") { controller.canvas.images[1].sourceWidth == candidate.width && controller.canvas.images[1].sourceHeight == candidate.height }

        controller.allEdits.state = .off; controller.canvas.activeIndex = 1
        controller.filterControl.selectItem(at:0); controller.filterAmount.stringValue = "1"; controller.noiseSeed.stringValue = "42"
        let selectedBeforeEdit = controller.entries[controller.canvas.activeIndex].id
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.inspectorScroll.contentView.scroll(to:CGPoint(x:0,y:150))
        controller.inspectorScroll.reflectScrolledClipView(controller.inspectorScroll.contentView)
        let scrollBeforeEdit = controller.inspectorScroll.contentView.bounds.origin
        controller.applyFilter()
        expect(controller.isProcessing,"An edit enters the processing state")
        waitUntil("Grayscale edit finishes") { !controller.isProcessing }
        expect(controller.entries[controller.canvas.activeIndex].id == selectedBeforeEdit,"Editing retains the selected image identifier")
        expect(abs(controller.inspectorScroll.contentView.bounds.origin.y-scrollBeforeEdit.y)<0.5,"Editing preserves inspector scroll position")
        let grayscale = try ImageEngine.filter(candidate,kind:"grayscale",amount:1)
        expect(controller.entries[0].buffer.rgba == original.rgba,"Selected-only editing preserves the reference")
        expect(controller.entries[1].buffer.rgba == grayscale.rgba,"UI filter applies the declared transform")
        expect(controller.entries[1].original.rgba == candidate.rgba,"Editing preserves the original for restore")
        controller.undoEdit()
        expect(controller.entries[1].buffer.rgba == candidate.rgba,"Undo restores exact Float pixels")
        controller.redoEdit()
        expect(controller.entries[1].buffer.rgba == grayscale.rgba,"Redo restores the transformed pixels")
        controller.restoreOriginal()
        expect(controller.entries[1].buffer.rgba == candidate.rgba,"Restore original discards transformed current pixels")
        controller.undoEdit()
        expect(controller.entries[1].buffer.rgba == grayscale.rgba,"Restore original itself is undoable")
        waitUntil("Edit metrics settle") { controller.cachedMetrics.count == 2 }

        install(controller,buffers:[original,original])
        controller.allEdits.state = .on; controller.filterControl.selectItem(at:3)
        controller.filterAmount.stringValue = "12.75"; controller.noiseSeed.stringValue = "87"
        controller.applyFilter(); waitUntil("All-image noise finishes") { !controller.isProcessing }
        let noise = try ImageEngine.filter(original,kind:"noise",amount:0.05,seed:87)
        expect(controller.entries.allSatisfy { $0.buffer.rgba == noise.rgba },"Noise UI converts 0–255 sigma and applies the same seed to every image")
        controller.undoEdit()
        expect(controller.entries.allSatisfy { $0.buffer.rgba == original.rgba },"One undo restores all images in a synchronized edit")
        controller.allEdits.state = .off
        waitUntil("Noise metric queue settles") { controller.cachedMetrics.count == 2 }

        // Playback distinguishes a chosen pair from the complete comparison set.
        install(controller,buffers:[original,candidate,buffer(offset:0.05)])
        controller.canvas.mode = .flicker; controller.canvas.activeIndex = 0
        controller.playbackControl.selectItem(at:1)
        var sequence: [Int] = []
        for _ in 0..<4 { controller.advancePlaybackFrame(); sequence.append(controller.canvas.activeIndex) }
        expect(sequence == [1,2,0,1],"All-image playback visits every image in order and wraps")
        controller.playbackControl.selectItem(at:0)
        controller.canvas.pairIndex = 0; controller.canvas.secondaryIndex = 2; controller.canvas.activeIndex = 2
        controller.advancePlaybackFrame(); let pairFirst = controller.canvas.activeIndex
        controller.advancePlaybackFrame(); let pairSecond = controller.canvas.activeIndex
        expect(pairFirst == 0 && pairSecond == 2,"Pair playback toggles exactly the selected pair")
        let toRemove = controller.entries[1].id, retainedReference = controller.entries[2].id
        controller.canvas.referenceIndex = 2; controller.canvas.activeIndex = 1
        controller.reloadSidebar(); controller.window?.makeFirstResponder(controller.table)
        controller.canvas.annotations = [CanvasAnnotation(tool:.dot,start:CGPoint(x:2,y:3),end:CGPoint(x:2,y:3))]
        let deleteKey = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
                                       windowNumber:controller.window!.windowNumber,context:nil,
                                       characters: "\u{7f}",charactersIgnoringModifiers:"\u{7f}",isARepeat:false,keyCode:51)!
        controller.table.keyDown(with:deleteKey)
        expect(controller.entries.count == 2 && !controller.entries.contains { $0.id == toRemove },"Delete with image-list focus removes the selected image")
        expect(controller.entries[controller.canvas.referenceIndex].id == retainedReference,"Deleting another image preserves the ground-truth identity")
        expect(controller.canvas.annotations.count == 1,"Image-list Delete does not remove a canvas annotation")

        // Live channel sliders reconstruct from a fixed baseline throughout a gesture.
        install(controller,buffers:[original,candidate]); controller.allEdits.state = .off
        controller.beginChannelGesture()
        controller.redChannel.floatValue = -0.5; controller.greenChannel.floatValue = 0; controller.blueChannel.floatValue = 0
        controller.channelsChanged()
        waitUntil("Live red-channel update finishes") { !controller.channelWorking && controller.entries[1].channelLevels == [-0.5,0,0] }
        let halfRed = try ImageEngine.adjustChannels(candidate,red:-0.5,green:0,blue:0)
        expect(controller.entries[1].buffer.rgba == halfRed.rgba,"Live channel slider applies its exact level")
        controller.redChannel.floatValue = -0.25; controller.channelsChanged()
        waitUntil("Second red-channel update finishes") { !controller.channelWorking && controller.entries[1].channelLevels == [-0.25,0,0] }
        let quarterRed = try ImageEngine.adjustChannels(candidate,red:-0.25,green:0,blue:0)
        expect(controller.entries[1].buffer.rgba == quarterRed.rgba,"Continuous slider updates are not cumulative")
        expect(controller.entries[0].buffer.rgba == original.rgba,"Selected-image channel adjustment preserves other images")
        controller.channelGestureInProgress = false
        controller.undoEdit()
        expect(controller.entries[1].buffer.rgba == candidate.rgba,"One undo restores the complete channel gesture")
        controller.redoEdit()
        expect(controller.entries[1].buffer.rgba == quarterRed.rgba,"Redo restores channel levels and exact adjusted pixels")
        controller.resetChannels()
        waitUntil("Channel reset finishes") { !controller.channelWorking && controller.entries[1].channelLevels == [0,0,0] }
        expect(controller.entries[1].buffer.rgba == candidate.rgba,"Reset channels restores the pre-slider baseline exactly")

        controller.beginChannelGesture(); controller.redChannel.floatValue = -0.25; controller.channelsChanged()
        waitUntil("Pre-filter channel update finishes") { !controller.channelWorking && controller.entries[1].channelLevels == [-0.25,0,0] }
        controller.channelGestureInProgress = false
        controller.filterControl.selectItem(at:0); controller.filterAmount.stringValue = "1"; controller.applyFilter()
        waitUntil("Filter after channel adjustment finishes") { !controller.isProcessing }
        let adjustedGray = try ImageEngine.filter(quarterRed,kind:"grayscale",amount:1)
        expect(controller.entries[1].buffer.rgba == adjustedGray.rgba,"A later filter operates on the current channel-adjusted image")
        expect(controller.entries[1].channelLevels == [0,0,0],"A new filter resets channel controls to a neutral baseline")
        controller.beginChannelGesture(); controller.greenChannel.floatValue = -0.5; controller.channelsChanged()
        waitUntil("Channel update on filtered baseline finishes") { !controller.channelWorking && controller.entries[1].channelLevels == [0,-0.5,0] }
        let filteredHalfGreen = try ImageEngine.adjustChannels(adjustedGray,red:0,green:-0.5,blue:0)
        expect(controller.entries[1].buffer.rgba == filteredHalfGreen.rgba,"New channel edits use the filtered baseline")
        controller.channelGestureInProgress = false
        controller.resetChannels(); waitUntil("Filtered channel reset finishes") { !controller.channelWorking && controller.entries[1].channelLevels == [0,0,0] }
        expect(controller.entries[1].buffer.rgba == adjustedGray.rgba,"Channel reset retains filters applied before the current slider session")
        install(controller,buffers:[original,candidate]); controller.allEdits.state = .on
        controller.beginChannelGesture(); controller.redChannel.floatValue = 1; controller.greenChannel.floatValue = 0; controller.blueChannel.floatValue = -1; controller.channelsChanged()
        waitUntil("All-image channels finish") { !controller.channelWorking && controller.entries.allSatisfy { $0.channelLevels == [1,0,-1] } }
        expect(controller.entries.allSatisfy { item in stride(from:0,to:item.buffer.rgba.count,by:4).allSatisfy { item.buffer.rgba[$0] == 1 && item.buffer.rgba[$0+2] == 0 } },"All-image channel endpoints set every affected channel exactly")
        controller.channelGestureInProgress = false; controller.allEdits.state = .off
        controller.undoEdit()
        expect(controller.entries[0].buffer.rgba == original.rgba && controller.entries[1].buffer.rgba == candidate.rgba,"Synchronized channel edits undo as one operation")

        // Persist a sample outside display range: PNG would clip this, a research workspace must not.
        var overshoot = original; overshoot.rgba[0] = -0.125; overshoot.rgba[1] = 1.125
        controller.entries[1] = ImageEntry(title:"Candidate / ../ stays metadata",buffer:overshoot,original:original,history:["Cubic reconstruction", "Unclipped samples"])
        controller.canvas.activeIndex = 1; controller.canvas.referenceIndex = 0; controller.canvas.pairIndex = 0; controller.canvas.secondaryIndex = 1
        controller.canvas.selection = CGRect(x:1,y:2,width:13,height:12)
        controller.canvas.zoom = 2.75; controller.canvas.pan = CGPoint(x:13.25,y:-8.5)
        controller.canvas.mode = .wipe; controller.canvas.wipePosition = 0.37
        controller.canvas.annotations = [CanvasAnnotation(tool:.rectangle,start:CGPoint(x:2,y:3),end:CGPoint(x:8,y:9),imageID:nil,width:1.25)]
        let manifest = controller.workspaceManifest(), pairs = controller.entries.map { ($0.buffer,$0.original) }
        let workspaceURL = scratch.appendingPathComponent("test.imspect",isDirectory:true)
        try WorkspaceStore.save(manifest:manifest,buffers:pairs,to:workspaceURL)
        let (restoredManifest, restoredEntries) = try WorkspaceStore.load(from:workspaceURL)
        expect(restoredEntries[1].buffer.rgba == overshoot.rgba,"Workspace preserves out-of-range Float32 samples exactly")
        expect(restoredEntries[1].original.rgba == original.rgba,"Workspace preserves original and current independently")
        expect(restoredEntries[1].id == controller.entries[1].id && restoredEntries[1].history == controller.entries[1].history,"Workspace preserves identifiers and operation provenance")
        expect(restoredManifest.zoom == 2.75 && restoredManifest.pan == CGPoint(x:13.25,y:-8.5) && restoredManifest.selection == manifest.selection,"Workspace preserves matched view and crop")
        expect(restoredManifest.mode == .wipe && restoredManifest.wipePosition == 0.37 && restoredManifest.annotations.count == 1,"Workspace preserves comparison mode and annotations")
        expect(!FileManager.default.fileExists(atPath:scratch.appendingPathComponent("stays metadata").path),"Image titles cannot become storage paths")
        // Exercise the actual asynchronous controller restoration too.
        controller.loadWorkspace(from:workspaceURL)
        waitUntil("Controller reopens the saved workspace") { !controller.isProcessing }
        expect(controller.entries[1].buffer.rgba == overshoot.rgba && controller.canvas.zoom == 2.75,"Controller restores saved exact pixels and navigation")
        expect(controller.canvas.annotations.count == 1 && controller.canvas.mode == .wipe,"Controller restores saved annotations and mode")

        // Replacement must be atomic and preserve a prior good workspace if a new buffer is invalid.
        try WorkspaceStore.save(manifest:manifest,buffers:pairs,to:workspaceURL)
        let replaced = try WorkspaceStore.load(from:workspaceURL)
        expect(replaced.1[1].buffer.rgba == overshoot.rgba,"Replacing an existing workspace succeeds")
        var nonfinite = original; nonfinite.rgba[0] = .nan
        mustThrow("Non-finite samples are rejected before replacement") { try WorkspaceStore.save(manifest:manifest,buffers:[(original,original),(nonfinite,original)],to:workspaceURL) }
        let preserved = try WorkspaceStore.load(from:workspaceURL)
        expect(preserved.1[1].buffer.rgba == overshoot.rgba,"Failed save preserves the previous workspace")

        func clone(_ name: String) throws -> URL {
            let dest = scratch.appendingPathComponent(name+".imspect",isDirectory:true)
            try FileManager.default.copyItem(at:workspaceURL,to:dest); return dest
        }
        let id = manifest.images[1].id.uuidString
        let truncated = try clone("truncated")
        try Data([0,1,2]).write(to:truncated.appendingPathComponent("buffers/"+id+"-current.rgba32f"))
        mustThrow("Truncated pixel buffers are rejected") { _ = try WorkspaceStore.load(from:truncated) }
        let corrupt = try clone("corrupt")
        try Data("{broken".utf8).write(to:corrupt.appendingPathComponent("workspace.json"))
        mustThrow("Corrupt JSON is rejected") { _ = try WorkspaceStore.load(from:corrupt) }
        let invalidVersion = try clone("version")
        var wrongVersion = manifest; wrongVersion.version = 999
        try JSONEncoder().encode(wrongVersion).write(to:invalidVersion.appendingPathComponent("workspace.json"))
        mustThrow("Unknown workspace versions are rejected") { _ = try WorkspaceStore.load(from:invalidVersion) }
        let badIndex = try clone("bad-index")
        var wrongIndex = manifest; wrongIndex.referenceIndex = 500
        try JSONEncoder().encode(wrongIndex).write(to:badIndex.appendingPathComponent("workspace.json"))
        mustThrow("Out-of-range image references are rejected") { _ = try WorkspaceStore.load(from:badIndex) }
        let traversal = try clone("traversal")
        var object = try JSONSerialization.jsonObject(with:Data(contentsOf:traversal.appendingPathComponent("workspace.json"))) as! [String:Any]
        var imageObjects = object["images"] as! [[String:Any]]; imageObjects[0]["id"] = "../../outside"; object["images"] = imageObjects
        try JSONSerialization.data(withJSONObject:object).write(to:traversal.appendingPathComponent("workspace.json"))
        mustThrow("Traversal-shaped identifiers are rejected") { _ = try WorkspaceStore.load(from:traversal) }
        let symlinked = try clone("symlink")
        let linkedBuffer = symlinked.appendingPathComponent("buffers/"+id+"-current.rgba32f")
        try FileManager.default.removeItem(at:linkedBuffer)
        try FileManager.default.createSymbolicLink(at:linkedBuffer,withDestinationURL:workspaceURL.appendingPathComponent("buffers/"+id+"-current.rgba32f"))
        mustThrow("Buffer symlinks outside the workspace are rejected") { _ = try WorkspaceStore.load(from:symlinked) }
        let linkedFolder = try clone("linked-folder")
        try FileManager.default.removeItem(at:linkedFolder.appendingPathComponent("buffers"))
        try FileManager.default.createSymbolicLink(at:linkedFolder.appendingPathComponent("buffers"),withDestinationURL:workspaceURL.appendingPathComponent("buffers"))
        mustThrow("A symlinked buffers directory is rejected") { _ = try WorkspaceStore.load(from:linkedFolder) }
        let nanBuffer = try clone("nan")
        var words = overshoot.rgba; words[0] = .nan
        try words.withUnsafeBytes { try Data($0).write(to:nanBuffer.appendingPathComponent("buffers/"+id+"-current.rgba32f")) }
        mustThrow("Non-finite samples are rejected on load") { _ = try WorkspaceStore.load(from:nanBuffer) }
        let oversized = try clone("oversized")
        var oversizedObject = try JSONSerialization.jsonObject(with:Data(contentsOf:oversized.appendingPathComponent("workspace.json"))) as! [String:Any]
        var oversizedImages = oversizedObject["images"] as! [[String:Any]]
        oversizedImages[0]["current"] = ["width":65536,"height":65536]; oversizedObject["images"] = oversizedImages
        try JSONSerialization.data(withJSONObject:oversizedObject).write(to:oversized.appendingPathComponent("workspace.json"))
        mustThrow("Oversized dimensions are rejected before allocation") { _ = try WorkspaceStore.load(from:oversized) }

        // Canvas export must anchor annotations to top-left source coordinates.
        let canvas = ComparisonCanvas(frame:CGRect(x:0,y:0,width:900,height:600))
        canvas.images = [CanvasImage(id:UUID(),title:"Source",image:original.cgImage())]
        canvas.annotations = [CanvasAnnotation(tool:.dot,start:CGPoint(x:0.5,y:0.5),end:CGPoint(x:0.5,y:0.5),width:0.5)]
        let annotated = try PixelBuffer.from(cgImage:canvas.exportAnnotated(index:0)!)
        expect(maximumError(annotated,original) > 0.01,"Annotation changes exported pixels")
        let topBefore = original.pixel(x:0,y:0)!, topAfter = annotated.pixel(x:0,y:0)!
        expect(abs(topBefore[1]-topAfter[1]) > 0.01,"Top-left annotation lands at the top-left")
        let bottomBefore = original.pixel(x:0,y:original.height-1)!, bottomAfter = annotated.pixel(x:0,y:original.height-1)!
        expect(zip(bottomBefore,bottomAfter).allSatisfy { abs($0-$1)<1e-6 },"Top-left annotation does not move to the bottom row")
        let encodedAnnotations = try JSONEncoder().encode(canvas.annotations)
        let decodedAnnotations = try JSONDecoder().decode([CanvasAnnotation].self,from:encodedAnnotations)
        expect(decodedAnnotations[0].start == CGPoint(x:0.5,y:0.5),"Annotation coordinates serialize exactly")
        controller.timer?.invalidate(); controller.window?.orderOut(nil)
        print("PASS: \(checks) native controller, comparison, export and persistence integration checks")
    }
}
