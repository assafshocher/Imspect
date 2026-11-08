import AppKit
import UniformTypeIdentifiers

struct WorkspaceBufferRecord: Codable {
    let width: Int
    let height: Int
}

struct WorkspaceImageRecord: Codable {
    let id: UUID
    let title: String
    let history: [String]
    let current: WorkspaceBufferRecord
    let original: WorkspaceBufferRecord
    // Optional so v1 workspaces decode without inventing a new baseline.
    var channelBase: WorkspaceBufferRecord? = nil
    var channelLevels: [Float]? = nil
}

struct WorkspaceManifest: Codable {
    var version = 2
    var application = "Imspect"
    var samples = "Float32 little-endian, encoded sRGB, straight RGBA, top-left rows"
    var images: [WorkspaceImageRecord]
    var activeIndex: Int
    var referenceIndex: Int
    var secondaryIndex: Int
    var pairIndex: Int?
    var mode: CompareMode
    var tool: CanvasTool
    var zoom: CGFloat
    var pan: CGPoint
    var selection: CGRect?
    var inspectionPoint: CGPoint?
    var wipePosition: CGFloat
    var annotations: [CanvasAnnotation]
    var annotateAll: Bool
    var allEdits: Bool
    var kernel: String
    var speed: Double
    var gain: Double
    var visualization: String
    var annotationColor: [CGFloat]? = nil
    var annotationWidth: CGFloat? = nil
    var textFontSize: CGFloat? = nil
    var playbackMode: Int? = nil
}

enum WorkspaceStore {
    // Limits are checked before any buffer allocation. Originals, edited copies, and channel bases all count.
    static let maximumTotalPixels = 64_000_000
    static let maximumManifestBytes = 8_388_608

    static func validate(_ manifest: WorkspaceManifest) throws {
        func invalid(_ description: String) throws { throw ImageEngineError.message("Invalid workspace: " + description) }
        guard (1...2).contains(manifest.version) else { try invalid("unsupported format version."); return }
        guard manifest.samples == "Float32 little-endian, encoded sRGB, straight RGBA, top-left rows" else { try invalid("unrecognized pixel format."); return }
        guard manifest.images.count <= 512 else { try invalid("too many images."); return }
        var pixels = 0
        var ids = Set<UUID>()
        for image in manifest.images {
            guard ids.insert(image.id).inserted, image.title.utf8.count <= 4096,
                  image.history.count <= 10000, image.history.allSatisfy({ $0.utf8.count <= 8192 }) else { try invalid("duplicate image identifiers or oversized metadata."); return }
            let levels = image.channelLevels ?? [0, 0, 0]
            guard levels.count == 3, levels.allSatisfy({ $0.isFinite && (-1...1).contains($0) }),
                  image.channelBase != nil || levels.allSatisfy({ $0 == 0 }) else { try invalid("invalid channel adjustment or missing channel baseline."); return }
            if let base = image.channelBase {
                guard base.width == image.current.width, base.height == image.current.height else { try invalid("channel baseline dimensions differ from the current image."); return }
            }
            for buffer in [image.current, image.original] + (image.channelBase.map { [$0] } ?? []) {
                guard buffer.width > 0, buffer.height > 0, buffer.width <= 65536, buffer.height <= 65536,
                      buffer.width <= maximumTotalPixels / buffer.height else { try invalid("unsupported image dimensions."); return }
                pixels += buffer.width * buffer.height
                guard pixels <= maximumTotalPixels else { try invalid("the total of all current, original, and channel baseline images exceeds 64 million pixels."); return }
            }
        }
        let count = max(1, manifest.images.count)
        for index in [manifest.activeIndex, manifest.referenceIndex, manifest.secondaryIndex, manifest.pairIndex ?? 0] {
            guard index >= 0, index < count else { try invalid("an image selection is out of range."); return }
        }
        func pointOK(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite && abs(p.x) <= 100_000_000 && abs(p.y) <= 100_000_000 }
        guard manifest.zoom.isFinite, (0.01...128).contains(manifest.zoom), pointOK(manifest.pan),
              manifest.wipePosition.isFinite, (0...1).contains(manifest.wipePosition),
              manifest.speed.isFinite, (0.25...12).contains(manifest.speed),
              manifest.gain.isFinite, (1...32).contains(manifest.gain),
              ["nearest", "linear", "cubic", "lanczos2", "lanczos3"].contains(manifest.kernel),
              ["Images", "Absolute difference", "MSE heatmap", "SSIM error map", "Centered FFT magnitude"].contains(manifest.visualization) else { try invalid("a view setting is out of range."); return }
        if let color = manifest.annotationColor {
            guard color.count == 4, color.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { try invalid("invalid annotation color."); return }
        }
        if let width = manifest.annotationWidth {
            guard width.isFinite, (0.5...80).contains(width) else { try invalid("invalid annotation width."); return }
        }
        if let size = manifest.textFontSize {
            guard size.isFinite, (4...512).contains(size) else { try invalid("invalid text font size."); return }
        }
        if let playback = manifest.playbackMode, !(0...1).contains(playback) { try invalid("invalid playback mode."); return }
        if let p = manifest.inspectionPoint, !pointOK(p) { try invalid("invalid inspection coordinates.") }
        if let r = manifest.selection {
            guard pointOK(r.origin), r.width.isFinite, r.height.isFinite, r.minX >= 0, r.minY >= 0, r.width > 0, r.height > 0,
                  r.maxX <= 100_000_000, r.maxY <= 100_000_000 else { try invalid("invalid region coordinates."); return }
            // A previously selected region may extend outside a subsequently resized image.
            // Preserve its coordinates; the metric engine explicitly rejects invalid crops.
        }
        guard manifest.annotations.count <= 100000 else { try invalid("too many annotations."); return }
        var totalPoints = 0
        for a in manifest.annotations {
            guard [.rectangle, .circle, .dot, .line, .brush, .text].contains(a.tool), pointOK(a.start), pointOK(a.end),
                  a.width.isFinite, (0.01...1000).contains(a.width),
                  [a.red, a.green, a.blue, a.alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  a.imageID == nil || ids.contains(a.imageID!) else { try invalid("invalid annotation."); return }
            if let points = a.points {
                totalPoints += points.count
                guard points.count <= 100000, totalPoints <= 1_000_000, points.allSatisfy(pointOK) else { try invalid("invalid or oversized brush stroke."); return }
            }
            if a.tool == .brush, a.points?.isEmpty != false { try invalid("brush stroke has no points."); return }
            if a.tool == .text, a.text?.isEmpty != false { try invalid("text annotation is empty."); return }
            if let text = a.text, text.utf8.count > 65536 { try invalid("annotation text is too long."); return }
            if let fontSize = a.fontSize {
                guard fontSize.isFinite, (0.1...10000).contains(fontSize) else { try invalid("invalid annotation font size."); return }
            }
        }
    }

    private static func bufferURL(root: URL, id: UUID, kind: String) -> URL {
        root.appendingPathComponent("buffers", isDirectory: true).appendingPathComponent(id.uuidString + "-" + kind + ".rgba32f")
    }

    private static func writeBuffer(_ buffer: PixelBuffer, to url: URL) throws {
        guard buffer.rgba.allSatisfy({ $0.isFinite }) else { throw ImageEngineError.message("A buffer contains a non-finite sample and cannot be saved.") }
        #if _endian(little)
        try buffer.rgba.withUnsafeBytes { try Data($0).write(to: url, options: .atomic) }
        #else
        let words = buffer.rgba.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: url, options: .atomic) }
        #endif
    }

    static func save(manifest: WorkspaceManifest, buffers: [(PixelBuffer, PixelBuffer)], channelBases: [PixelBuffer?]? = nil, to url: URL) throws {
        try validate(manifest)
        guard buffers.count == manifest.images.count else { throw ImageEngineError.message("The workspace image count changed while saving.") }
        guard channelBases == nil || channelBases?.count == manifest.images.count else { throw ImageEngineError.message("The workspace channel baseline count changed while saving.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumManifestBytes else { throw ImageEngineError.message("The workspace metadata exceeds 8 MB.") }
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".imspect-save-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary.appendingPathComponent("buffers", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        for (index, pair) in buffers.enumerated() {
            let record = manifest.images[index]
            guard pair.0.width == record.current.width, pair.0.height == record.current.height,
                  pair.1.width == record.original.width, pair.1.height == record.original.height else { throw ImageEngineError.message("The workspace dimensions changed while saving.") }
            try writeBuffer(pair.0, to: bufferURL(root: temporary, id: record.id, kind: "current"))
            try writeBuffer(pair.1, to: bufferURL(root: temporary, id: record.id, kind: "original"))
            let baseline = channelBases?[index]
            if let dimensions = record.channelBase {
                guard let baseline, baseline.width == dimensions.width, baseline.height == dimensions.height else { throw ImageEngineError.message("A channel baseline is missing or its dimensions changed while saving.") }
                try writeBuffer(baseline, to: bufferURL(root: temporary, id: record.id, kind: "channels"))
            } else if baseline != nil { throw ImageEngineError.message("A channel baseline has no matching workspace metadata.") }
        }
        try data.write(to: temporary.appendingPathComponent("workspace.json"), options: .atomic)
        if fm.fileExists(atPath: url.path) {
            // NSSavePanel already obtained the user's replacement choice. Foundation replaces
            // on the same volume only after all new files have been written successfully.
            _ = try fm.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } else { try fm.moveItem(at: temporary, to: url) }
    }

    private static func regularFile(_ url: URL, root: URL, expectedBytes: Int? = nil) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath), let size = values.fileSize,
              expectedBytes == nil || size == expectedBytes else { throw ImageEngineError.message("A workspace file is missing, linked outside the workspace, or has the wrong size.") }
        return size
    }

    private static func readBuffer(_ record: WorkspaceBufferRecord, url: URL, root: URL) throws -> PixelBuffer {
        let count = record.width * record.height * 4
        _ = try regularFile(url, root: root, expectedBytes: count * 4)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == count * 4 else { throw ImageEngineError.message("A pixel buffer was truncated while opening the workspace.") }
        var samples = [Float](repeating: 0, count: count)
        #if _endian(little)
        _ = samples.withUnsafeMutableBytes { output in data.copyBytes(to: output) }
        #else
        data.withUnsafeBytes { source in
            for i in 0..<count { samples[i] = Float(bitPattern: UInt32(littleEndian: source.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))) }
        }
        #endif
        guard samples.allSatisfy({ $0.isFinite }) else { throw ImageEngineError.message("A workspace pixel buffer contains non-finite values.") }
        return PixelBuffer(width: record.width, height: record.height, rgba: samples)
    }

    static func load(from url: URL) throws -> (WorkspaceManifest, [ImageEntry]) {
        let manifestURL = url.appendingPathComponent("workspace.json")
        guard try regularFile(manifestURL, root: url) <= maximumManifestBytes else { throw ImageEngineError.message("The workspace metadata exceeds 8 MB.") }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= maximumManifestBytes else { throw ImageEngineError.message("The workspace metadata is too large.") }
        let manifest = try JSONDecoder().decode(WorkspaceManifest.self, from: data)
        try validate(manifest)
        let bufferFolder = url.appendingPathComponent("buffers", isDirectory: true)
        let folder = try bufferFolder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folder.isDirectory == true, folder.isSymbolicLink != true else { throw ImageEngineError.message("The workspace buffers folder is missing or is a symbolic link.") }
        var entries: [ImageEntry] = []
        for record in manifest.images {
            let current = try readBuffer(record.current, url: bufferURL(root: url, id: record.id, kind: "current"), root: url)
            let original = try readBuffer(record.original, url: bufferURL(root: url, id: record.id, kind: "original"), root: url)
            let baseline = try record.channelBase.map { try readBuffer($0, url: bufferURL(root: url, id: record.id, kind: "channels"), root: url) }
            entries.append(ImageEntry(title: record.title, buffer: current, id: record.id, original: original, history: record.history,
                                      channelBase: baseline, channelLevels: record.channelLevels ?? [0, 0, 0]))
        }
        return (manifest, entries)
    }
}

extension WorkspaceController {
    func workspaceManifest() -> WorkspaceManifest {
        let records = entries.map { WorkspaceImageRecord(id: $0.id, title: $0.title, history: $0.history,
                                                         current: WorkspaceBufferRecord(width: $0.buffer.width, height: $0.buffer.height),
                                                         original: WorkspaceBufferRecord(width: $0.original.width, height: $0.original.height),
                                                         channelBase: $0.channelBase.map { WorkspaceBufferRecord(width: $0.width, height: $0.height) },
                                                         channelLevels: $0.channelLevels) }
        let color = canvas.annotationColor.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.18, green: 0.91, blue: 0.79, alpha: 1)
        return WorkspaceManifest(images: records, activeIndex: canvas.activeIndex, referenceIndex: canvas.referenceIndex,
                                 secondaryIndex: canvas.secondaryIndex, pairIndex: canvas.pairIndex, mode: canvas.mode, tool: canvas.tool,
                                 zoom: canvas.zoom, pan: canvas.pan, selection: canvas.selection, inspectionPoint: canvas.inspectionPoint,
                                 wipePosition: canvas.wipePosition, annotations: canvas.annotations, annotateAll: canvas.annotateAll,
                                 allEdits: allEdits.state == .on, kernel: selectedKernel.rawValue, speed: speedSlider.doubleValue,
                                 gain: gainSlider.doubleValue, visualization: visualization,
                                 annotationColor: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent],
                                 annotationWidth: canvas.annotationWidth, textFontSize: canvas.textFontSize,
                                 playbackMode: max(0, playbackControl.indexOfSelectedItem))
    }

    @objc func saveWorkspace() {
        guard !isProcessing else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Comparison.imspect"
        panel.allowedContentTypes = [UTType(filenameExtension: "imspect") ?? .package]
        panel.canCreateDirectories = true; panel.message = "Save images, originals, annotations, and comparison settings together."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let manifest = workspaceManifest(), buffers = entries.map { ($0.buffer, $0.original) }, channelBases = entries.map { $0.channelBase }
        setBusy(true, "Saving workspace…")
        computeQueue.async {
            do {
                try WorkspaceStore.save(manifest: manifest, buffers: buffers, channelBases: channelBases, to: url)
                DispatchQueue.main.async { self.setBusy(false, "Workspace saved · " + url.lastPathComponent) }
            } catch { DispatchQueue.main.async { self.setBusy(false, "Workspace was not saved"); self.alert("Could not save workspace", error.localizedDescription) } }
        }
    }

    @objc func openWorkspace() {
        guard !isProcessing else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an Imspect workspace (.imspect). Your current comparison is replaced only after the workspace loads successfully."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadWorkspace(from: url)
    }

    func loadWorkspace(from url: URL) {
        guard !isProcessing else { return }
        timer?.invalidate(); timer = nil; playButton.title = "▶ Play"
        setBusy(true, "Opening workspace…")
        computeQueue.async {
            do {
                let (manifest, loaded) = try WorkspaceStore.load(from: url)
                DispatchQueue.main.async {
                    let viewportCallback = self.canvas.onViewportChange; self.canvas.onViewportChange = nil
                    self.entries = loaded; self.undoSnapshots = []; self.redoSnapshots = []
                    self.canvas.activeIndex = manifest.activeIndex; self.canvas.referenceIndex = manifest.referenceIndex
                    self.canvas.secondaryIndex = manifest.secondaryIndex; self.canvas.pairIndex = manifest.pairIndex
                    self.canvas.mode = manifest.mode; self.canvas.tool = manifest.tool
                    self.canvas.zoom = manifest.zoom; self.canvas.pan = manifest.pan; self.canvas.selection = manifest.selection
                    self.canvas.inspectionPoint = manifest.inspectionPoint; self.canvas.wipePosition = manifest.wipePosition
                    self.canvas.annotations = manifest.annotations; self.canvas.annotateAll = manifest.annotateAll
                    let color = manifest.annotationColor ?? [0.18, 0.91, 0.79, 1]
                    self.annotationColorControl.color = NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3])
                    self.brushWidthControl.doubleValue = Double(manifest.annotationWidth ?? 1.5)
                    self.fontSizeControl.stringValue = String(format: "%g", Double(manifest.textFontSize ?? 24))
                    self.annotationStyleChanged()
                    self.playbackControl.selectItem(at: manifest.playbackMode ?? 0); self.playbackChanged()
                    self.sharedAnnotations.state = manifest.annotateAll ? .on : .off; self.allEdits.state = manifest.allEdits ? .on : .off
                    self.kernelControl.selectItem(at: ["nearest", "linear", "cubic", "lanczos2", "lanczos3"].firstIndex(of: manifest.kernel) ?? 2)
                    self.speedSlider.doubleValue = manifest.speed; self.gainSlider.doubleValue = manifest.gain; self.speedChanged()
                    self.modeControl.selectedSegment = CompareMode.allCases.firstIndex(of: manifest.mode) ?? 0
                    self.toolControl.selectItem(at: CanvasTool.allCases.firstIndex(of: manifest.tool) ?? 0)
                    self.zoomLabel.stringValue = String(format: "%.0f%%", manifest.zoom * 100)
                    self.canvas.onViewportChange = viewportCallback
                    self.setBusy(false, "Opened " + url.lastPathComponent); self.refreshEntries()
                    if let point = manifest.inspectionPoint { self.updatePixel(point) }
                    if manifest.visualization != "Images" {
                        self.visualization = manifest.visualization; self.visualizationControl.selectItem(withTitle: manifest.visualization); self.updateAnalysis()
                    }
                    self.window?.makeFirstResponder(self.canvas)
                }
            } catch { DispatchQueue.main.async { self.setBusy(false, "Current comparison preserved"); self.alert("Could not open workspace", error.localizedDescription) } }
        }
    }

    func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title); item.submenu = submenu; main.addItem(item); return submenu
        }
        @discardableResult func add(_ title: String, _ selector: Selector, to menu: NSMenu, key: String = "", modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target ?? self; item.tag = tag; menu.addItem(item); return item
        }
        let app = menu("Imspect")
        add("About Imspect", #selector(showAbout), to: app)
        app.addItem(.separator())
        add("Hide Imspect", #selector(NSApplication.hide(_:)), to: app, key: "h", target: NSApp)
        add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), to: app, key: "h", modifiers: [.command, .option], target: NSApp)
        add("Show All", #selector(NSApplication.unhideAllApplications(_:)), to: app, target: NSApp)
        app.addItem(.separator()); add("Quit Imspect", #selector(NSApplication.terminate(_:)), to: app, key: "q", target: NSApp)
        let file = menu("File")
        add("Open Images…", #selector(openImages), to: file, key: "o")
        add("Open Workspace…", #selector(openWorkspace), to: file, key: "o", modifiers: [.command, .shift])
        add("Save Workspace…", #selector(saveWorkspace), to: file, key: "s")
        file.addItem(.separator())
        add("Export Image or Region…", #selector(exportImage), to: file, key: "e", modifiers: [.command, .shift])
        add("Export Metric Report…", #selector(exportMetrics), to: file)
        file.addItem(.separator()); add("Load Demonstration", #selector(demoAction), to: file)
        file.addItem(.separator()); add("Close Window", #selector(NSWindow.performClose(_:)), to: file, key: "w", target: window)
        let edit = menu("Edit")
        add("Undo", #selector(undoFromMenu), to: edit, key: "z")
        add("Redo", #selector(redoFromMenu), to: edit, key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        let cutItem = add("Cut", NSSelectorFromString("cut:"), to: edit, key: "x"); cutItem.target = nil
        add("Copy Image with Annotations", #selector(copyFromMenu), to: edit, key: "c")
        add("Copy Selected Region", #selector(cropCopy), to: edit, key: "c", modifiers: [.command, .shift])
        add("Copy Comparison View", #selector(copyComparisonView), to: edit, key: "c", modifiers: [.command, .option])
        add("Paste Image", #selector(pasteFromMenu), to: edit, key: "v")
        let selectItem = add("Select All Text", NSSelectorFromString("selectAll:"), to: edit, key: "a"); selectItem.target = nil
        edit.addItem(.separator())
        add("Duplicate Selected Image", #selector(duplicateImage), to: edit, key: "d")
        add("Remove Selected Image", NSSelectorFromString("removeImage"), to: edit)
        add("Set Selected as Reference", #selector(setGT), to: edit)
        edit.addItem(.separator()); add("Apply Selected Filter", #selector(applyFilter), to: edit)
        add("Resize Images", #selector(resizeImages), to: edit)
        add("Restore Original", #selector(restoreOriginal), to: edit)
        let view = menu("View")
        add("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), to: view, key: "f", modifiers: [.command, .control], target: window)
        view.addItem(.separator())
        add("Split", #selector(selectModeFromMenu(_:)), to: view, key: "1", tag: 0)
        add("Flicker", #selector(selectModeFromMenu(_:)), to: view, key: "2", tag: 1)
        add("Boundary Wipe", #selector(selectModeFromMenu(_:)), to: view, key: "3", tag: 2)
        view.addItem(.separator())
        add("Toggle Comparison Pair", #selector(togglePairFromMenu), to: view)
        add("Next Image", #selector(nextImageFromMenu), to: view, key: "]")
        add("Previous Image", #selector(previousImageFromMenu), to: view, key: "[")
        add("Play / Pause", #selector(togglePlay), to: view, key: "p")
        view.addItem(.separator())
        add("Zoom In", #selector(zoomIn), to: view, key: "=")
        add("Zoom Out", #selector(zoomOut), to: view, key: "-")
        add("Fit Images", #selector(fitImages), to: view, key: "f")
        add("Actual Size (100%)", #selector(actualSize), to: view, key: "0")
        add("Zoom to Selected Region", #selector(zoomToSelection), to: view)
        add("Clear Selected Region", #selector(clearSelection), to: view)
        let tools = menu("Tools")
        for (index, name) in ["Pan", "Inspect Pixel", "Select Region", "Rectangle", "Circle", "Dot", "Line", "Brush", "Text"].enumerated() { add(name, #selector(selectToolFromMenu(_:)), to: tools, tag: index) }
        tools.addItem(.separator()); add("Clear Annotations", #selector(clearAnnotations), to: tools)
        tools.addItem(.separator()); add("Research Models…", NSSelectorFromString("researchMetrics"), to: tools)
        let windowMenu = menu("Window")
        add("Minimize", #selector(NSWindow.performMiniaturize(_:)), to: windowMenu, key: "m", target: window)
        add("Zoom", #selector(NSWindow.performZoom(_:)), to: windowMenu, target: window)
        NSApp.windowsMenu = windowMenu
        let help = menu("Help")
        add("Keyboard & Comparison Guide", #selector(showKeyboardHelp), to: help, key: "?", modifiers: [.command])
        add("Research Models Setup", NSSelectorFromString("researchMetrics"), to: help)
        add("About Imspect", #selector(showAbout), to: help)
        NSApp.helpMenu = help; NSApp.mainMenu = main
    }

    @objc func selectModeFromMenu(_ item: NSMenuItem) { modeControl.selectedSegment = item.tag; modeChanged() }
    @objc func selectToolFromMenu(_ item: NSMenuItem) { toolControl.selectItem(at: item.tag); toolChanged() }
    @objc func copyFromMenu() {
        if let editor = window?.firstResponder as? NSTextView { editor.copy(nil) }
        else { copyImage() }
    }
    @objc func pasteFromMenu() {
        if let editor = window?.firstResponder as? NSTextView { editor.paste(nil) }
        else { pasteImages() }
    }
    @objc func undoFromMenu() {
        if let editor = window?.firstResponder as? NSTextView { editor.undoManager?.undo() }
        else { undoEdit() }
    }
    @objc func redoFromMenu() {
        if let editor = window?.firstResponder as? NSTextView { editor.undoManager?.redo() }
        else { redoEdit() }
    }
    @objc func togglePairFromMenu() { canvas.togglePair() }
    @objc func nextImageFromMenu() { canvas.nextImage() }
    @objc func previousImageFromMenu() {
        guard !entries.isEmpty else { return }
        canvas.activeIndex = (canvas.activeIndex + entries.count - 1) % entries.count
        canvas.onActiveImage?(canvas.activeIndex); canvas.onChange?()
    }
    @objc func copyComparisonView() {
        guard !entries.isEmpty, let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        let image = NSImage(size: canvas.bounds.size); image.addRepresentation(representation)
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        statusLabel.stringValue = "Comparison view copied · includes visible labels and guides at display resolution"
    }

    @objc func showAbout() {
        alert("Imspect · Research Preview", "A native, local image comparison workspace.\n\nSynchronized split, flicker, and boundary wipe; shared region and pixel inspection; reproducible image transforms and explicit metric conventions.\n\nWorking pixels: Float32 encoded sRGB, straight RGBA. Workspaces preserve current images and originals without PNG quantization. Native image exports use 16-bit PNG.\n\nResizeRight-compatible resampling is implemented in Swift. Optional learned quality models run through the separate research engine.\n\nResearch preview: verify conventions against your benchmark before reporting results.")
    }

    @objc func showKeyboardHelp() {
        alert("Keyboard & comparison guide", "When the canvas has focus:\nSpace or click in Flicker: switch pair\n1–9: select an image · N or ]: next image\nTab: Split → Flicker → Wipe\nArrows: pan all images · Option-arrows: one source pixel\n⌘-wheel or pinch: zoom around the pointer\n+ / −: zoom · F: fit · 0: 100%\nV: pan · I: inspect · S: select region\nR: rectangle · C: circle · D: dot · L: line\nB: brush · T: text\nDelete: remove last annotation · Escape: clear region\n\n⌘O: add images · ⌘V: paste an image\n⌘C: copy selected image with annotations\n⌘⇧C: copy region · ⌘⌥C: copy visible comparison\n⌘Z / ⌘⇧Z: undo / redo image edits\n⌘S: save workspace · ⌘⇧O: open workspace\n\nCoordinates start at the top-left. 100% is one source pixel per screen point; Retina displays use multiple display pixels per point. Crops, markers, and pan/zoom are shared. Different dimensions are never silently aligned or resized for metrics. The reference image and visual comparison partner can be selected independently. Metrics require opaque inputs; transparency is preserved for viewing and editing.")
    }
}
