import AppKit

extension WorkspaceController {
    func refreshDisplayCache(force: Bool = false) {
        displayGeneration += 1; let generation = displayGeneration
        displayDebounce?.cancel(); displayRequest?.cancel()
        guard !entries.isEmpty else { return }
        let request = WorkCancellation(); displayRequest = request
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !request.isCancelled, generation == self.displayGeneration else { return }
            self.renderViewport(generation: generation, request: request)
        }
        displayDebounce = work
        if force { work.perform() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work) }
    }

    private func renderViewport(generation: Int, request: WorkCancellation) {
        let scale = canvas.zoom * (window?.backingScaleFactor ?? 2)
        lastDisplayScale = scale
        let source = entries.map { e in (e.id, e.title, analysisBuffers[e.id] ?? e.buffer, analysisImages[e.id] ?? e.cg) }
        if canvas.images.count != source.count || zip(canvas.images, source).contains(where: { item, s in item.id != s.0 || item.sourceWidth != s.2.width || item.sourceHeight != s.2.height }) {
            canvas.images = source.map { CanvasImage(id: $0.0, title: $0.1, image: $0.3) }
        }
        let footprints = canvas.visibleSourceRects(overscanPoints: 48)
        let kernel = selectedKernel
        canvas.interpolation = kernel == .nearest ? .none : .high
        displayQueue.async {
            var output: [CanvasImage] = []
            var failure: String?
            for (id, title, buffer, original) in source {
                guard !request.isCancelled else { return }
                let visible = footprints[id] ?? .zero
                if visible.isEmpty {
                    output.append(CanvasImage(id: id, title: title, image: original))
                    continue
                }
                // A bounded patch on a common source-coordinate sampling grid. Its
                // exact footprint retains the zoom even when pixel counts round.
                let x = floor(visible.minX * scale) / scale
                let y = floor(visible.minY * scale) / scale
                let width = max(1, Int(ceil(visible.maxX * scale) - floor(visible.minX * scale)))
                let height = max(1, Int(ceil(visible.maxY * scale) - floor(visible.minY * scale)))
                let rect = CGRect(x: x, y: y, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
                do {
                    let patch = try ImageEngine.resampleViewport(buffer, sourceRect: rect, width: width, height: height, kernel: kernel)
                    output.append(CanvasImage(id: id, title: title, image: patch.cgImage(), sourceWidth: buffer.width, sourceHeight: buffer.height, sourceRect: rect, fallbackImage: original))
                } catch {
                    failure = error.localizedDescription
                    output.append(CanvasImage(id: id, title: title, image: original))
                }
            }
            DispatchQueue.main.async {
                guard generation == self.displayGeneration, !request.isCancelled else { return }
                self.canvas.images = output; self.canvas.needsDisplay = true
                self.displayCompletedGeneration = generation
                if let failure = failure { self.statusLabel.stringValue = "Preview unavailable: " + failure }
            }
        }
    }
}
