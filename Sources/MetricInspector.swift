import AppKit

extension WorkspaceController {
    private func ensureMetricViews() {
        let ids = entries.map { $0.id }
        guard ids != metricViewIDs else { return }
        preserveInspectorPosition {
            clearMetricViews(); metricViewIDs = ids
            for (i, entry) in entries.enumerated() {
                let title = text("\(i + 1) · \(entry.title)", size: 11, color: .labelColor, bold: true)
                title.lineBreakMode = .byTruncatingMiddle
                let values = NSTextField(wrappingLabelWithString: "Calculating…")
                values.font = .monospacedSystemFont(ofSize: 10, weight: .regular); values.textColor = .secondaryLabelColor
                let row = stack(.vertical, spacing: 5, [title, values])
                metricStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: metricStack.widthAnchor).isActive = true
                title.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
                values.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
                values.heightAnchor.constraint(equalToConstant: 68).isActive = true
                metricTitles.append(title); metricDescriptions.append(values)
            }
        }
    }
    func calculateMetrics() {
        metricGeneration += 1; let generation = metricGeneration; cachedMetrics = []
        metricRequest?.cancel(); let request = WorkCancellation(); metricRequest = request
        ensureMetricViews()
        guard entries.indices.contains(canvas.referenceIndex) else { return }
        if visualization == "Centered FFT magnitude" {
            for label in metricDescriptions { label.stringValue = "Return to Images for source metrics." }
            return
        }
        let reference = entries[canvas.referenceIndex].buffer; let referenceIndex = canvas.referenceIndex; let roi = canvas.selection
        let items = entries.enumerated().map { ($0.offset, $0.element.title, $0.element.buffer) }
        for (i, label) in metricDescriptions.enumerated() { label.stringValue = i == referenceIndex ? "Reference" : "Calculating…" }
        computeQueue.async {
            var results: [(String, MetricResult?, String?)] = []
            for (i, title, buffer) in items {
                guard !request.isCancelled else { return }
                if i == referenceIndex { results.append((title, nil, "Reference")); continue }
                do { results.append((title, try ImageEngine.metrics(buffer, reference, roi: roi), nil)) }
                catch { results.append((title, nil, error.localizedDescription)) }
            }
            DispatchQueue.main.async {
                guard generation == self.metricGeneration, !request.isCancelled else { return }
                self.cachedMetrics = results
                self.preserveInspectorPosition {
                    for (i, result) in results.enumerated() where self.metricDescriptions.indices.contains(i) {
                        self.metricTitles[i].stringValue = "\(i + 1) · \(result.0)"
                        if let m = result.1 {
                            let psnr = m.psnr.isInfinite ? "∞" : String(format: "%.3f", m.psnr)
                            let ssim = m.ssim.map { String(format: "%.5f", $0) } ?? "N/A (< 11 px)"
                            let delta = m.meanDeltaE.map { String(format: "%.3f", $0) } ?? "N/A"
                            self.metricDescriptions[i].stringValue = "PSNR  \(psnr) dB\nSSIM  \(ssim)\nMSE   \(String(format: "%.7f", m.mse))\nHist  \(String(format: "%.5f", m.histogramDistance))\nΔE76  \(delta)"
                        } else { self.metricDescriptions[i].stringValue = result.2 ?? "Unavailable" }
                    }
                }
            }
        }
    }
    func clearMetricViews() {
        for view in metricStack.arrangedSubviews { metricStack.removeArrangedSubview(view); view.removeFromSuperview() }
        metricViewIDs = []; metricTitles = []; metricDescriptions = []
    }
}
