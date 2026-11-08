import AppKit

extension WorkspaceController {
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === fontSizeControl { annotationStyleChanged() }
    }
    @objc func annotationStyleChanged() {
        canvas.annotationColor = annotationColorControl.color
        canvas.annotationWidth = CGFloat(brushWidthControl.doubleValue)
        brushWidthLabel.stringValue = String(format: "%.1f px", brushWidthControl.doubleValue)
        let size = Double(fontSizeControl.stringValue) ?? 24
        canvas.textFontSize = CGFloat(min(512, max(4, size.isFinite ? size : 24)))
        fontSizeControl.stringValue = String(format: "%.0f", canvas.textFontSize)
    }
    func syncChannelControls() {
        guard entries.indices.contains(canvas.activeIndex) else { return }
        let values = entries[canvas.activeIndex].channelLevels
        redChannel.floatValue = values[0]; greenChannel.floatValue = values[1]; blueChannel.floatValue = values[2]
    }
    func beginChannelGesture() {
        guard !entries.isEmpty, !isProcessing || channelWorking else { return }
        pausePlayback()
        undoSnapshots.append(snapshot()); undoSnapshots = Array(undoSnapshots.suffix(10)); redoSnapshots = []
        channelGestureInProgress = true
    }
    @objc func resetChannels() {
        guard !isProcessing || channelWorking else { return }
        redChannel.floatValue = 0; greenChannel.floatValue = 0; blueChannel.floatValue = 0
        channelsChanged()
    }
    @objc func channelsChanged() {
        guard entries.indices.contains(canvas.activeIndex), !isProcessing || channelWorking else { return }
        pausePlayback()
        if !channelGestureInProgress {
            undoSnapshots.append(snapshot()); undoSnapshots = Array(undoSnapshots.suffix(10)); redoSnapshots = []
        }
        let levels = [redChannel.floatValue, greenChannel.floatValue, blueChannel.floatValue]
        let indices = allEdits.state == .on ? Array(entries.indices) : [canvas.activeIndex]
        for i in indices { if entries[i].channelBase == nil { entries[i].channelBase = entries[i].buffer } }
        let sources = indices.map { (entries[$0].id, entries[$0].channelBase!) }
        channelGeneration += 1; let generation = channelGeneration
        channelRequest?.cancel(); let request = WorkCancellation(); channelRequest = request
        channelWorking = true; setBusy(true, "Updating RGB channels…")
        channelQueue.async {
            do {
                var results: [(UUID, PixelBuffer, CGImage)] = []
                for (id, source) in sources {
                    guard !request.isCancelled else { return }
                    let result = try ImageEngine.adjustChannels(source, red: levels[0], green: levels[1], blue: levels[2])
                    results.append((id, result, result.cgImage()))
                }
                DispatchQueue.main.async {
                    guard generation == self.channelGeneration, !request.isCancelled else { return }
                    let history = String(format: "RGB channels: R %+.3f, G %+.3f, B %+.3f", levels[0], levels[1], levels[2])
                    for (id, buffer, cg) in results {
                        guard let e = self.entries.first(where: { $0.id == id }) else { continue }
                        e.buffer = buffer; e.cg = cg; e.channelLevels = levels
                        if e.history.last?.hasPrefix("RGB channels:") == true { e.history[e.history.count - 1] = history }
                        else { e.history.append(history) }
                    }
                    self.channelWorking = false; self.setBusy(false, "RGB channels updated · center restores the channel baseline")
                    let currentValues = [self.redChannel.floatValue, self.greenChannel.floatValue, self.blueChannel.floatValue]
                    self.refreshEntries(preserveView: true)
                    if self.channelGestureInProgress {
                        self.redChannel.floatValue = currentValues[0]; self.greenChannel.floatValue = currentValues[1]; self.blueChannel.floatValue = currentValues[2]
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.channelGeneration else { return }
                    self.channelWorking = false; self.setBusy(false, "RGB adjustment was not applied")
                    self.alert("Cannot adjust channels", error.localizedDescription)
                }
            }
        }
    }
    func restoreInspectorPosition(_ position: CGPoint) {
        inspectorScroll.documentView?.layoutSubtreeIfNeeded()
        inspectorScroll.layoutSubtreeIfNeeded()
        inspectorScroll.contentView.scroll(to: position)
        inspectorScroll.reflectScrolledClipView(inspectorScroll.contentView)
    }
    func preserveInspectorPosition(_ action: () -> Void) {
        let position = inspectorScroll.contentView.bounds.origin
        action()
        restoreInspectorPosition(position)
    }
}
