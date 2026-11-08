import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

private enum ResearchBridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

private struct ResearchJobResult {
    let response: [String: Any]
    let directory: URL
    let map: PixelBuffer?
}

private enum ResearchBridge {
    static var resourceDirectory: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Research", isDirectory: true)) }
        // #filePath supports a directly compiled development build; bundled resources take precedence.
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research", isDirectory: true))
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates += [cwd.appendingPathComponent("Research"), cwd.appendingPathComponent("outputs/Imspect/Research"), cwd.appendingPathComponent("outputs/PixelBench/Research")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("backend.py").path) }
    }

    static var python: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Imspect/research/bin/python3")
    }

    /// The optional model bridge deliberately evaluates a declared 8-bit sRGB snapshot.
    static func writeSnapshot(_ image: PixelBuffer, to url: URL) throws -> Int {
        guard image.width * image.height <= 32_000_000 else { throw ResearchBridgeError.message("Research models currently accept images up to 32 megapixels.") }
        var bytes = [UInt8](repeating: 255, count: image.rgba.count)
        var clipped = 0
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            guard image.rgba[i + 3].isFinite, image.rgba[i + 3] >= 0.99999 else {
                throw ResearchBridgeError.message("Research model metrics require opaque images. Composite transparency against your chosen background before evaluating them.")
            }
            for channel in 0..<3 {
                let value = image.rgba[i + channel]
                guard value.isFinite else { throw ResearchBridgeError.message("A source image contains nonfinite pixel values.") }
                if value < 0 || value > 1 { clipped += 1 }
                bytes[i + channel] = UInt8((max(0, min(1, value)) * 255).rounded())
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .relativeColorimetric),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ResearchBridgeError.message("Could not create the 8-bit sRGB research snapshot.")
        }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw ResearchBridgeError.message("Could not write the research snapshot.") }
        return clipped
    }

    static func run(operation: String, spatial: Bool, source: PixelBuffer, reference: PixelBuffer?, roi: CGRect?,
                    title: String, referenceTitle: String?, history: [String], script: URL, python: URL) throws -> ResearchJobResult {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("Imspect-research-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: directory) } }
        let imageURL = directory.appendingPathComponent("image.png")
        let clipped = try writeSnapshot(source, to: imageURL)
        var request: [String: Any] = ["protocol": 1, "operation": operation, "image": imageURL.path,
                                      "allow_downloads": true, "device": "cpu"]
        var sourceMetadata: [String: Any] = ["image_title": title, "operations": history,
                                           "snapshot_conversion": "Float32 encoded sRGB → clipped [0,1] → rounded RGBA8 PNG",
                                           "clipped_rgb_samples": clipped]
        if let reference = reference {
            let referenceURL = directory.appendingPathComponent("reference.png")
            let refClipped = try writeSnapshot(reference, to: referenceURL)
            request["reference"] = referenceURL.path
            sourceMetadata["reference_title"] = referenceTitle ?? "Reference"
            sourceMetadata["reference_clipped_rgb_samples"] = refClipped
        }
        if let roi = roi { request["roi"] = [Int(roi.minX), Int(roi.minY), Int(roi.width), Int(roi.height)] }
        if spatial { request["heatmap"] = directory.appendingPathComponent("lpips-map.png").path; request["heatmap_max"] = 1.0 }
        let requestURL = directory.appendingPathComponent("request.json"), responseURL = directory.appendingPathComponent("response.json")
        try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys]).write(to: requestURL)
        let logURL = directory.appendingPathComponent("worker.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--request", requestURL.path, "--response", responseURL.path]
        process.standardOutput = log; process.standardError = log
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"; environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 600) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 3) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 3)
            }
            throw ResearchBridgeError.message("Research computation exceeded 10 minutes and was stopped. Model downloads may be incomplete. Retry after checking your connection, or select a smaller region.")
        }
        guard let data = try? Data(contentsOf: responseURL),
              var response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let detail = ((try? String(contentsOf: logURL)) ?? "The worker did not return a result.").suffix(3000)
            throw ResearchBridgeError.message("The research worker could not complete.\n\n\(detail)")
        }
        guard response["ok"] as? Bool == true else {
            let error = response["error"] as? [String: Any]
            throw ResearchBridgeError.message(error?["message"] as? String ?? "The research worker reported an error.")
        }
        guard process.terminationStatus == 0 else { throw ResearchBridgeError.message("The research worker stopped unexpectedly after writing its response.") }
        response["imspect_source"] = sourceMetadata
        response["request"] = request
        response["computed_at"] = ISO8601DateFormatter().string(from: Date())
        var map: PixelBuffer?
        if spatial, let path = response["heatmap"] as? String { map = try PixelBuffer.load(url: URL(fileURLWithPath: path)) }
        succeeded = true
        return ResearchJobResult(response: response, directory: directory, map: map)
    }

    static func export(_ result: ResearchJobResult, to reportURL: URL) throws {
        let fm = FileManager.default
        let folder = reportURL.deletingLastPathComponent().appendingPathComponent(reportURL.deletingPathExtension().lastPathComponent + "-artifacts-" + UUID().uuidString.prefix(8), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var pathMap: [String: String] = [:]
        do {
            for name in ["image.png", "reference.png", "lpips-map.png", "lpips-map.npy"] {
                let source = result.directory.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    let destination = folder.appendingPathComponent(name)
                    try fm.copyItem(at: source, to: destination); pathMap[source.path] = destination.path
                }
            }
            func rewrite(_ item: Any) -> Any {
                if let string = item as? String { return pathMap[string] ?? string }
                if let array = item as? [Any] { return array.map(rewrite) }
                if let object = item as? [String: Any] { return object.mapValues(rewrite) }
                return item
            }
            let data = try JSONSerialization.data(withJSONObject: rewrite(result.response), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}

extension WorkspaceController {
    @objc func researchMetrics() {
        guard visualization != "Centered FFT magnitude" else { alert("Return to Images first", "Research metrics evaluate spatial source images. A region drawn on an FFT spectrum uses frequency coordinates."); return }
        guard !isProcessing else { return }
        guard entries.indices.contains(canvas.activeIndex) else { alert("Add an image first", "Open or paste an image before running research models."); return }
        guard let resourceDirectory = ResearchBridge.resourceDirectory else { alert("Research tools unavailable", "The Research folder is missing from this app bundle. Rebuild the application with its bundled research tools."); return }
        guard FileManager.default.isExecutableFile(atPath: ResearchBridge.python.path) else {
            let dialog = NSAlert(); dialog.messageText = "Install optional research tools"
            dialog.informativeText = "LPIPS, NIQE, MUSIQ, and TOPIQ-NR use a local Python environment. The installer requires Python 3.10–3.12 and downloads several GB of packages. Model weights download when you first compute a score."
            dialog.addButton(withTitle: "Open installer"); dialog.addButton(withTitle: "Cancel")
            if dialog.runModal() == .alertFirstButtonReturn {
                let setup = resourceDirectory.appendingPathComponent("Setup.command")
                if !NSWorkspace.shared.open(setup) { alert("Cannot open installer", "Open Research/Setup.command from the app files to install the optional research tools.") }
            }
            return
        }
        let selection = canvas.selection?.standardized.integral
        let selected = entries[canvas.activeIndex]
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        picker.addItems(withTitles: ["LPIPS · against reference", "LPIPS · score + spatial map", "NIQE · individual quality", "MUSIQ · individual quality", "TOPIQ-NR · individual quality"])
        let dialog = NSAlert(); dialog.messageText = "Research model"
        let region = selection.map { "ROI x \(Int($0.minX)), y \(Int($0.minY)), \(Int($0.width)) × \(Int($0.height))" } ?? "Full image"
        dialog.informativeText = "\(selected.title)\n\(region)\n\nMeasurements use 8-bit sRGB snapshots; values outside 0–1 are clipped in those snapshots. Model weights may download on first use. Images are processed locally on CPU. No-reference scores estimate perceived quality, not fidelity to reference."
        dialog.accessoryView = picker
        dialog.addButton(withTitle: "Compute"); dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let choice = picker.indexOfSelectedItem
        let operation = ["lpips", "lpips", "niqe", "musiq", "topiq_nr"][choice]
        let needsReference = operation == "lpips"
        guard !needsReference || entries.indices.contains(canvas.referenceIndex) else { alert("Select a reference", "LPIPS compares the selected image with the reference image."); return }
        let source = selected.buffer, sourceTitle = selected.title, history = selected.history
        let reference = needsReference ? entries[canvas.referenceIndex].buffer : nil
        let referenceTitle = needsReference ? entries[canvas.referenceIndex].title : nil
        if let reference = reference, source.width != reference.width || source.height != reference.height {
            alert("Image sizes differ", "LPIPS requires aligned images with identical dimensions. Resize or register them explicitly first."); return
        }
        if let selection = selection {
            guard selection.width > 0, selection.height > 0, selection.minX >= 0, selection.minY >= 0,
                  selection.maxX <= CGFloat(source.width), selection.maxY <= CGFloat(source.height) else {
                alert("Region outside image", "Select a region contained completely within the image."); return
            }
        }
        let evaluatedWidth = Int(selection?.width ?? CGFloat(source.width)), evaluatedHeight = Int(selection?.height ?? CGFloat(source.height))
        let minimum = operation == "niqe" ? 192 : needsReference ? 64 : 1
        guard min(evaluatedWidth, evaluatedHeight) >= minimum else {
            alert("Region too small", "\(operation.uppercased()) requires a region of at least \(minimum) × \(minimum) pixels in Imspect."); return
        }
        setBusy(true, "Computing \(operation.uppercased()) · first use may download weights…")
        computeQueue.async {
            do {
                let result = try ResearchBridge.run(operation: operation, spatial: choice == 1, source: source, reference: reference,
                                                   roi: selection, title: sourceTitle, referenceTitle: referenceTitle, history: history,
                                                   script: resourceDirectory.appendingPathComponent("backend.py"), python: ResearchBridge.python)
                DispatchQueue.main.async {
                    defer { try? FileManager.default.removeItem(at: result.directory) }
                    self.setBusy(false, "\(operation.uppercased()) complete · 8-bit sRGB snapshot")
                    if let map = result.map {
                        let crop = selection.map { " · crop x\(Int($0.minX)) y\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? ""
                        let title = "LPIPS map · \(sourceTitle)\(crop)"
                        self.entries.append(ImageEntry(title: title, buffer: map, history: ["LPIPS AlexNet v0.1 vs \(referenceTitle ?? "GT")", "Feature contributions · fixed display scale 0–1", "\(region) · map origin is crop origin"]))
                        self.canvas.activeIndex = self.entries.count - 1
                        self.canvas.selection = nil; self.undoSnapshots = []; self.redoSnapshots = []
                        self.refreshEntries(fit: true)
                    }
                    let score = (result.response["score"] as? NSNumber)?.doubleValue ?? .nan
                    let lowerBetter = result.response["lower_better"] as? Bool ?? true
                    let report = NSAlert(); report.messageText = "\(operation.uppercased()): \(String(format: "%.6f", score))"
                    var detail = "\(sourceTitle)\n\(region)\n\(lowerBetter ? "Lower" : "Higher") scores are better within this metric.\n8-bit sRGB snapshot · CPU"
                    if let referenceTitle = referenceTitle { detail += "\nReference: \(referenceTitle)" }
                    if choice == 1 { detail += "\n\nThe map shows upsampled feature contributions with nonlocal receptive fields. Its displayed average does not define the scalar score." }
                    report.informativeText = detail
                    report.addButton(withTitle: "Done"); report.addButton(withTitle: "Save report…")
                    if report.runModal() == .alertSecondButtonReturn {
                        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
                        panel.nameFieldStringValue = "Imspect-\(operation)-report.json"
                        panel.message = "Saves the score and conventions, plus an artifacts folder containing the evaluated snapshots and any maps."
                        if panel.runModal() == .OK, let url = panel.url {
                            do { try ResearchBridge.export(result, to: url); self.statusLabel.stringValue = "Research report and input snapshots exported" }
                            catch { self.alert("Report export failed", error.localizedDescription) }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.setBusy(false, "Research metric unavailable"); self.alert("Research metric unavailable", error.localizedDescription) }
            }
        }
    }
}
