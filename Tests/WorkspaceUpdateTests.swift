import AppKit
import Foundation

/// Version 2 persistence and version 1 migration checks. Compile with all Sources except main.swift.
@main struct WorkspaceUpdateTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func mustThrow(_ message: String, _ body: () throws -> Void) {
        do { try body(); expect(false, message) } catch { expect(true, message) }
    }
    static func waitUntil(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(condition(), message)
    }
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let controller = WorkspaceController()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("Imspect-update-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory); controller.timer?.invalidate(); controller.window?.orderOut(nil) }
        let baseline = PixelBuffer(width: 3, height: 2, rgba: [
            -0.125,0.25,0.5,1, 0.1,0.2,0.3,1, 0.7,0.8,1.125,1,
            0.15,0.45,0.65,1, 0.2,0.4,0.6,1, 0.3,0.6,0.9,1])
        var current = baseline; current.rgba[0] = 0.2; current.rgba[1] = 0.1
        let image = ImageEntry(title: "Channel-adjusted image", buffer: current, original: baseline,
                               history: ["RGB adjustments"], channelBase: baseline, channelLevels: [0.4,-0.3,0.2])
        controller.entries = [image]
        controller.canvas.activeIndex = 0; controller.canvas.referenceIndex = 0
        controller.canvas.pairIndex = 0; controller.canvas.secondaryIndex = 0
        controller.canvas.annotationColor = NSColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 0.75)
        controller.canvas.annotationWidth = 7
        controller.canvas.textFontSize = 36
        controller.canvas.tool = .text
        controller.playbackControl.selectItem(at: 1)
        var stroke = CanvasAnnotation(tool: .brush, start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 2.5, y: 1.5), imageID: image.id, width: 7)
        stroke.points = [CGPoint(x:0.5,y:0.5), CGPoint(x:1.1,y:0.9), CGPoint(x:2.5,y:1.5)]
        var text = CanvasAnnotation(tool: .text, start: CGPoint(x: 1, y: 1), end: CGPoint(x: 1, y: 1), width: 2)
        text.text = "Frame α · detail\nSecond line"; text.fontSize = 36
        controller.canvas.annotations = [stroke, text]
        let manifest = controller.workspaceManifest()
        expect(manifest.version == 2, "New workspaces use version 2")
        expect(manifest.playbackMode == 1, "All-image playback choice is captured")
        expect(manifest.annotationWidth == 7 && manifest.textFontSize == 36, "Current drawing style is captured")
        expect(manifest.annotationColor?.count == 4 && abs((manifest.annotationColor?[3] ?? 0) - 0.75) < 0.00001, "RGBA annotation color is captured")
        expect(manifest.images[0].channelBase?.width == 3 && manifest.images[0].channelLevels == [0.4,-0.3,0.2], "Channel baseline and signed levels are captured")
        let url = directory.appendingPathComponent("v2.imspect", isDirectory:true)
        try WorkspaceStore.save(manifest:manifest, buffers:[(current,baseline)], channelBases:[baseline], to:url)
        let (loaded, entries) = try WorkspaceStore.load(from:url)
        expect(entries[0].buffer.rgba == current.rgba, "Current adjusted pixels survive exactly")
        expect(entries[0].original.rgba == baseline.rgba, "Original pixels survive exactly")
        expect(entries[0].channelBase?.rgba == baseline.rgba, "Channel baseline preserves overshoot and Float32 precision")
        expect(entries[0].channelLevels == [0.4,-0.3,0.2], "Channel slider levels survive exactly")
        expect(loaded.annotations[0].points == stroke.points, "Freehand point sequence survives exactly")
        expect(loaded.annotations[1].text == text.text && loaded.annotations[1].fontSize == 36, "Unicode multiline text and font size survive exactly")
        expect(loaded.annotations[0].imageID == image.id && loaded.annotations[1].imageID == nil, "Per-image and shared annotation scope survive")
        expect(loaded.annotationColor == manifest.annotationColor && loaded.playbackMode == 1, "New manifest fields survive disk round trip")
        expect(loaded.tool == .text, "The new text tool selection survives disk round trip")
        controller.loadWorkspace(from:url)
        waitUntil("Controller restores version 2 workspace") { !controller.isProcessing }
        expect(controller.canvas.annotationWidth == 7 && controller.canvas.textFontSize == 36, "Controller restores drawing controls and canvas style")
        expect(controller.playbackControl.indexOfSelectedItem == 1, "Controller restores all-image playback mode")
        expect(controller.entries[0].channelBase?.rgba == baseline.rgba, "Controller restores nondestructive channel baseline")
        expect(controller.timer == nil, "Loading playback settings does not unexpectedly start animation")

        func copyWorkspace(_ name: String) throws -> URL {
            let copy = directory.appendingPathComponent(name + ".imspect", isDirectory:true)
            try fm.copyItem(at:url, to:copy); return copy
        }
        let legacyURL = try copyWorkspace("legacy")
        var legacy = try JSONSerialization.jsonObject(with:Data(contentsOf:legacyURL.appendingPathComponent("workspace.json"))) as! [String:Any]
        legacy["version"] = 1
        legacy["tool"] = "pan"
        for key in ["annotationColor", "annotationWidth", "textFontSize", "playbackMode"] { legacy.removeValue(forKey:key) }
        var imageObjects = legacy["images"] as! [[String:Any]]
        imageObjects[0].removeValue(forKey:"channelBase"); imageObjects[0].removeValue(forKey:"channelLevels"); legacy["images"] = imageObjects
        var rectangle = CanvasAnnotation(tool:.rectangle,start:CGPoint(x:0,y:0),end:CGPoint(x:2,y:1),width:1.5)
        rectangle.imageID = image.id
        var rectangleJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(rectangle)) as! [String:Any]
        for key in ["points", "text", "fontSize"] { rectangleJSON.removeValue(forKey:key) }
        legacy["annotations"] = [rectangleJSON]
        try JSONSerialization.data(withJSONObject:legacy).write(to:legacyURL.appendingPathComponent("workspace.json"))
        let (oldManifest, oldEntries) = try WorkspaceStore.load(from:legacyURL)
        expect(oldManifest.version == 1 && oldManifest.annotationColor == nil && oldManifest.playbackMode == nil, "Version 1 decodes absent optional style fields")
        expect(oldEntries[0].channelBase == nil && oldEntries[0].channelLevels == [0,0,0], "Version 1 defaults to no live channel adjustment")
        expect(oldEntries[0].buffer.rgba == current.rgba, "Legacy current pixels are preserved without reinterpretation")
        expect(oldManifest.annotations[0].tool == .rectangle && oldManifest.annotations[0].points == nil, "Legacy annotation schema decodes")
        controller.loadWorkspace(from:legacyURL)
        waitUntil("Controller restores legacy workspace") { !controller.isProcessing }
        expect(controller.playbackControl.indexOfSelectedItem == 0 && controller.canvas.annotationWidth == 1.5 && controller.canvas.textFontSize == 24, "Legacy workspace restores prior drawing defaults and pair playback")

        var invalid = manifest; invalid.playbackMode = 2
        mustThrow("Unknown playback modes are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.annotationColor = [0.2, 0.3, 0.4]
        mustThrow("Malformed color vectors are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.annotationWidth = 0
        mustThrow("Invalid drawing widths are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.textFontSize = 513
        mustThrow("Unsupported drawing font sizes are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.images[0].channelLevels = [0,0]
        mustThrow("Channel levels must have three entries") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.images[0].channelLevels = [0,.infinity,0]
        mustThrow("Nonfinite channel levels are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.images[0].channelLevels = [0,1.01,0]
        mustThrow("Out-of-range channel levels are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.images[0].channelBase = nil
        mustThrow("Nonzero channel levels require a baseline") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.images[0].channelBase = WorkspaceBufferRecord(width:4,height:2)
        mustThrow("Channel baseline dimensions must match the current image") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.annotations[0].points = []
        mustThrow("Empty brush strokes are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.annotations[0].points = [CGPoint(x:CGFloat.nan,y:0)]
        mustThrow("Nonfinite stroke coordinates are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.annotations[0].points = Array(repeating:.zero,count:100001)
        mustThrow("Oversized brush strokes are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.annotations[1].text = ""
        mustThrow("Empty text annotations are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.annotations[1].text = String(repeating:"x",count:65537)
        mustThrow("Oversized text annotations are rejected") { try WorkspaceStore.validate(invalid) }
        invalid = manifest; invalid.annotations[1].fontSize = .nan
        mustThrow("Nonfinite text font sizes are rejected") { try WorkspaceStore.validate(invalid) }
        mustThrow("Missing channel payload cannot replace a valid workspace") { try WorkspaceStore.save(manifest:manifest,buffers:[(current,baseline)],to:url) }
        let (_, preserved) = try WorkspaceStore.load(from:url)
        expect(preserved[0].channelBase?.rgba == baseline.rgba, "Failed save preserves the prior channel baseline")
        let truncatedURL = try copyWorkspace("truncated-baseline")
        try Data([0,1]).write(to:truncatedURL.appendingPathComponent("buffers/"+image.id.uuidString+"-channels.rgba32f"))
        mustThrow("Truncated channel baselines are rejected") { _ = try WorkspaceStore.load(from:truncatedURL) }
        let linkedURL = try copyWorkspace("linked-baseline")
        let linkedFile = linkedURL.appendingPathComponent("buffers/"+image.id.uuidString+"-channels.rgba32f")
        try fm.removeItem(at:linkedFile)
        try fm.createSymbolicLink(at:linkedFile,withDestinationURL:url.appendingPathComponent("buffers/"+image.id.uuidString+"-channels.rgba32f"))
        mustThrow("Symlinked channel baseline payloads are rejected") { _ = try WorkspaceStore.load(from:linkedURL) }
        print("PASS: \(checks) version 2 workspace and backward-compatibility checks")
    }
}
