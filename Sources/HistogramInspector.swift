import AppKit

extension WorkspaceController {
    @objc func histogramOverlayChanged() { updateHistogramDisplay() }
    func updateHistogramDisplay() {
        guard entries.indices.contains(canvas.activeIndex) else {
            histogramView.bins = []; histogramView.referenceBins = nil; histogramView.status = "Open an image to see its histogram"
            histogramCaption.stringValue = "Select an image"; return
        }
        let entry = entries[canvas.activeIndex]
        histogramView.bins = histogramCache[entry.id] ?? []
        histogramView.status = histogramErrors[entry.id] ?? "Calculating…"
        if histogramOverlay.state == .on, entries.indices.contains(canvas.referenceIndex) {
            histogramView.referenceBins = histogramCache[entries[canvas.referenceIndex].id]
        } else { histogramView.referenceBins = nil }
        histogramCaption.stringValue = "\(entry.title) · \(canvas.selection == nil || visualization == "Centered FFT magnitude" ? "full image" : "selected region")"
    }
    func refreshHistograms() {
        histogramGeneration += 1; let generation = histogramGeneration
        histogramRequest?.cancel(); let request = WorkCancellation(); histogramRequest = request
        histogramCache = [:]; histogramErrors = [:]; updateHistogramDisplay()
        let images = entries.map { ($0.id, $0.buffer) }
        let region = visualization == "Centered FFT magnitude" ? nil : canvas.selection
        histogramQueue.async {
            var results: [UUID: [[Int]]] = [:]; var errors: [UUID: String] = [:]
            for (id, buffer) in images {
                guard !request.isCancelled else { return }
                do {
                    let pixels = try region.map { try buffer.cropped($0) } ?? buffer
                    results[id] = ImageEngine.histogram(pixels)
                } catch { errors[id] = "Region outside this image" }
            }
            DispatchQueue.main.async {
                guard generation == self.histogramGeneration, !request.isCancelled else { return }
                self.histogramCache = results; self.histogramErrors = errors; self.updateHistogramDisplay()
            }
        }
    }
}
