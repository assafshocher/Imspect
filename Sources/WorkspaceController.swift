import AppKit
import UniformTypeIdentifiers

private let accent = NSColor(calibratedRed: 0.48, green: 0.89, blue: 0.74, alpha: 1)
private let panelColor = NSColor(calibratedWhite: 0.105, alpha: 1)

final class ImageEntry {
    let id: UUID
    var title: String
    var buffer: PixelBuffer
    var original: PixelBuffer
    var cg: CGImage
    var history: [String]
    var channelBase: PixelBuffer?
    var channelLevels: [Float]
    init(title: String, buffer: PixelBuffer, id: UUID = UUID(), original: PixelBuffer? = nil, history: [String] = [], channelBase: PixelBuffer? = nil, channelLevels: [Float] = [0, 0, 0]) {
        self.id = id; self.title = title; self.buffer = buffer; self.original = original ?? buffer
        self.cg = buffer.cgImage(); self.history = history
        self.channelBase = channelBase; self.channelLevels = channelLevels
    }
}

final class WorkspaceController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var entries: [ImageEntry] = []
    let canvas = ComparisonCanvas()
    let table = ImageListTableView()
    let inspectorScroll = NSScrollView()
    let modeControl = NSSegmentedControl(labels: ["Split", "Flicker", "Wipe"], trackingMode: .selectOne, target: nil, action: nil)
    let toolControl = NSPopUpButton()
    let kernelControl = NSPopUpButton()
    let gtControl = NSPopUpButton()
    let partnerControl = NSPopUpButton()
    let visualizationControl = NSPopUpButton()
    let filterControl = NSPopUpButton()
    let filterAmount = NSTextField(string: "1.0")
    let noiseSeed = NSTextField(string: "42")
    let resizeWidth = NSTextField(string: "512")
    let resizeHeight = NSTextField(string: "512")
    let speedSlider = NSSlider(value: 2, minValue: 0.25, maxValue: 12, target: nil, action: nil)
    let gainSlider = NSSlider(value: 4, minValue: 1, maxValue: 32, target: nil, action: nil)
    let playButton = NSButton(title: "▶ Play", target: nil, action: nil)
    let playbackControl = NSPopUpButton()
    let annotationColorControl = NSColorWell()
    let brushWidthControl = NSSlider(value: 3, minValue: 0.5, maxValue: 80, target: nil, action: nil)
    let brushWidthLabel = NSTextField(labelWithString: "3 px")
    let fontSizeControl = NSTextField(string: "24")
    let redChannel = ChannelSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let greenChannel = ChannelSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let blueChannel = ChannelSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let zoomLabel = NSTextField(labelWithString: "100%")
    let speedLabel = NSTextField(labelWithString: "2 switches/s")
    let statusLabel = NSTextField(labelWithString: "Drop images to begin · ⌘O open · ⌘V paste")
    let selectionLabel = NSTextField(wrappingLabelWithString: "Full image")
    let pixelLabel = NSTextField(wrappingLabelWithString: "Choose Inspect, then click a pixel.")
    let metricStack = NSStackView()
    let histogramView = RGBHistogramView()
    let histogramCaption = NSTextField(labelWithString: "Select an image")
    let histogramOverlay = NSButton(checkboxWithTitle: "Overlay reference", target: nil, action: nil)
    var histogramCache: [UUID: [[Int]]] = [:]
    var histogramErrors: [UUID: String] = [:]
    var histogramGeneration = 0
    var histogramRequest: WorkCancellation?
    let historyLabel = NSTextField(wrappingLabelWithString: "Original image")
    let allEdits = NSButton(checkboxWithTitle: "Apply edits to all images", target: nil, action: nil)
    let sharedAnnotations = NSButton(checkboxWithTitle: "Annotations on all images", target: nil, action: nil)
    let busy = NSProgressIndicator()
    var timer: Timer?
    var metricGeneration = 0
    var metricRequest: WorkCancellation?
    var displayGeneration = 0
    var displayCompletedGeneration = 0
    var analysisGeneration = 0
    var cachedMetrics: [(String, MetricResult? , String?)] = []
    var visualization = "Images"
    var analysisImages: [UUID: CGImage] = [:]
    var analysisBuffers: [UUID: PixelBuffer] = [:]
    var isProcessing = false
    var updatingTable = false
    var channelWorking = false
    var channelGestureInProgress = false
    var channelGeneration = 0
    var channelRequest: WorkCancellation?
    var displayRequest: WorkCancellation?
    var displayDebounce: DispatchWorkItem?
    var metricViewIDs: [UUID] = []
    var metricTitles: [NSTextField] = []
    var metricDescriptions: [NSTextField] = []
    var lastDisplayScale: CGFloat = -1
    var wipeDirection: CGFloat = 1
    var undoSnapshots: [Snapshot] = []
    var redoSnapshots: [Snapshot] = []
    let computeQueue = DispatchQueue(label: "imspect.compute", qos: .userInitiated)
    let displayQueue = DispatchQueue(label: "imspect.display", qos: .userInitiated)
    let channelQueue = DispatchQueue(label: "imspect.channels", qos: .userInitiated)
    let histogramQueue = DispatchQueue(label: "imspect.histograms", qos: .userInitiated)
    struct Snapshot {
        let buffers: [PixelBuffer]; let histories: [[String]]
        var channelBases: [PixelBuffer?] = []
        var channelLevels: [[Float]] = []
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 920), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Imspect"; window.minSize = NSSize(width: 1120, height: 740)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = panelColor; window.center()
        super.init(window: window)
        buildUI(); buildMenus(); connectCanvas()
    }
    required init?(coder: NSCoder) { fatalError() }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.2"
    }
    func brandImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "ImspectMark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = false
            return image
        }
        return NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Imspect")
    }

    func text(_ string: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor, bold: Bool = false) -> NSTextField {
        let v = NSTextField(labelWithString: string); v.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        v.textColor = color; return v
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; b.controlSize = .small; return b
    }
    func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat = 8, _ views: [NSView] = []) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = orientation; s.spacing = spacing; s.alignment = orientation == .vertical ? .leading : .centerY; return s
    }
    func section(_ title: String, in s: NSStackView) {
        let divider = NSBox(); divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false
        s.addArrangedSubview(divider); divider.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        let heading = text(title.uppercased(), size: 10, color: accent, bold: true); s.addArrangedSubview(heading)
    }
    func buildUI() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor
        let shell = stack(.vertical, spacing: 0); shell.translatesAutoresizingMaskIntoConstraints = false
        shell.distribution = .fill
        root.addSubview(shell)
        NSLayoutConstraint.activate([shell.leadingAnchor.constraint(equalTo: root.leadingAnchor), shell.trailingAnchor.constraint(equalTo: root.trailingAnchor), shell.topAnchor.constraint(equalTo: root.topAnchor), shell.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let logo = NSImageView()
        logo.image = brandImage(); logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("Imspect")
        logo.widthAnchor.constraint(equalToConstant: 42).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let brandTitle = stack(.horizontal, spacing: 8, [text("Imspect", size: 23, color: .labelColor, bold: true), text("v" + appVersion, size: 10)])
        let brandText = stack(.vertical, spacing: 2, [brandTitle, text("EVERY PIXEL. UNDER INSPECTION.", size: 9, color: accent)])
        let brand = stack(.horizontal, spacing: 10, [logo, brandText])
        let flexible = NSView()
        let header = stack(.horizontal, spacing: 12, [brand, flexible, button("Demo", #selector(demoAction)), button("Open images…", #selector(openImages)), button("Paste", #selector(pasteImages)), button("Copy", #selector(copyImage)), button("Export…", #selector(exportImage))])
        header.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        header.heightAnchor.constraint(equalToConstant: 78).isActive = true
        shell.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
        let divider = NSBox(); divider.boxType = .separator; shell.addArrangedSubview(divider); divider.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
        let content = stack(.horizontal, spacing: 0); content.alignment = .top
        // Gravity-area stacks may pack their arranged views at the leading edge
        // after intrinsic-size changes (for example Play becoming Pause).
        // The workspace columns must consume the full window on every layout pass.
        content.distribution = .fill
        shell.addArrangedSubview(content); content.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
        let sidebar = makeSidebar(); content.addArrangedSubview(sidebar)
        sidebar.widthAnchor.constraint(equalToConstant: 215).isActive = true
        sidebar.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        let middle = stack(.vertical, spacing: 0)
        middle.distribution = .fill
        content.addArrangedSubview(middle); middle.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        middle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        middle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeControl.selectedSegment = 0; modeControl.target = self; modeControl.action = #selector(modeChanged)
        modeControl.toolTip = "Tab cycles Split, Flicker, and Wipe"
        kernelControl.addItems(withTitles: ["Nearest", "Linear", "Cubic", "Lanczos 2", "Lanczos 3"]); kernelControl.selectItem(at: 2)
        kernelControl.target = self; kernelControl.action = #selector(kernelChanged); kernelControl.controlSize = .small
        kernelControl.toolTip = "ResizeRight-compatible resampling, symmetric boundary, antialiasing enabled"
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); zoomLabel.widthAnchor.constraint(equalToConstant: 51).isActive = true
        let tools = stack(.horizontal, spacing: 7, [modeControl, NSView(), button("−", #selector(zoomOut)), zoomLabel, button("+", #selector(zoomIn)), button("Fit", #selector(fitImages)), button("1:1", #selector(actualSize)), kernelControl])
        tools.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        middle.addArrangedSubview(tools); tools.widthAnchor.constraint(equalTo: middle.widthAnchor).isActive = true
        toolControl.addItems(withTitles: ["Pan", "Inspect pixel", "Select region", "Rectangle", "Circle", "Dot", "Line", "Brush", "Text"])
        toolControl.target = self; toolControl.action = #selector(toolChanged); toolControl.controlSize = .small
        playButton.target = self; playButton.action = #selector(togglePlay); playButton.bezelStyle = .rounded; playButton.controlSize = .small
        speedSlider.target = self; speedSlider.action = #selector(speedChanged); speedSlider.isContinuous = true
        speedSlider.widthAnchor.constraint(equalToConstant: 95).isActive = true
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let second = stack(.horizontal, spacing: 8, [toolControl, button("Clear region", #selector(clearSelection)), NSView(), button("Next ›", #selector(nextImageFromMenu)), playButton, speedSlider, speedLabel])
        second.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14)
        middle.addArrangedSubview(second); second.widthAnchor.constraint(equalTo: middle.widthAnchor).isActive = true
        middle.addArrangedSubview(canvas); canvas.widthAnchor.constraint(equalTo: middle.widthAnchor).isActive = true
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvas.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let hint = text("SPACE  flicker     1–9  image     ARROWS  pan     ⌘ SCROLL  zoom     TAB  mode", size: 10)
        let hints = stack(.horizontal, [hint]); hints.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        middle.addArrangedSubview(hints); hints.widthAnchor.constraint(equalTo: middle.widthAnchor).isActive = true
        let inspector = makeInspector(); content.addArrangedSubview(inspector)
        inspector.widthAnchor.constraint(equalToConstant: 284).isActive = true
        inspector.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            middle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            middle.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle; statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        busy.style = .spinning; busy.controlSize = .small; busy.isDisplayedWhenStopped = false
        let bottom = stack(.horizontal, spacing: 9, [busy, statusLabel, NSView(), text("LOCAL · sRGB", size: 9, color: accent)])
        bottom.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        shell.addArrangedSubview(bottom); bottom.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
    }
    func makeSidebar() -> NSView {
        let side = stack(.vertical, spacing: 10)
        side.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 12, right: 12)
        side.addArrangedSubview(text("COMPARISON SET", size: 10, color: accent, bold: true))
        let info = text("Add as many images as you need", size: 10); side.addArrangedSubview(info)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("image")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 72; table.delegate = self; table.dataSource = self
        table.style = .sourceList; table.backgroundColor = panelColor; table.allowsEmptySelection = false
        table.onDelete = { [weak self] row in self?.removeImageAtIndex(row) }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        side.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -24).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let actions = stack(.horizontal, spacing: 5, [button("+ Add", #selector(openImages)), button("− Remove", #selector(removeImage))]); side.addArrangedSubview(actions)
        side.addArrangedSubview(button("Set selected as reference", #selector(setGT)))
        side.addArrangedSubview(button("Duplicate selected", #selector(duplicateImage)))
        let separator = NSBox(); separator.boxType = .separator; side.addArrangedSubview(separator)
        side.addArrangedSubview(button("Save workspace…", #selector(saveWorkspace)))
        side.addArrangedSubview(button("Open workspace…", #selector(openWorkspace)))
        return side
    }
    func makeInspector() -> NSView {
        let scroll = inspectorScroll; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let s = stack(.vertical, spacing: 10); s.translatesAutoresizingMaskIntoConstraints = false
        s.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 24, right: 16); scroll.documentView = s
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), s.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), s.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        func full(_ v: NSView) { s.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -32).isActive = true }
        s.addArrangedSubview(text("INSPECTOR", size: 10, color: accent, bold: true))
        s.addArrangedSubview(text("Reference image", size: 11)); full(gtControl)
        gtControl.target = self; gtControl.action = #selector(gtChanged)
        s.addArrangedSubview(text("Flicker partner / wipe left", size: 11)); full(partnerControl)
        partnerControl.target = self; partnerControl.action = #selector(partnerChanged)
        playbackControl.addItems(withTitles: ["Play pair", "Play all images in order"])
        playbackControl.target = self; playbackControl.action = #selector(playbackChanged); full(playbackControl)
        section("View", in: s)
        visualizationControl.addItems(withTitles: ["Images", "Absolute difference", "MSE heatmap", "SSIM error map", "Centered FFT magnitude"])
        visualizationControl.target = self; visualizationControl.action = #selector(visualizationChanged); full(visualizationControl)
        gainSlider.target = self; gainSlider.action = #selector(gainChanged)
        s.addArrangedSubview(text("Difference gain / heatmap gain", size: 10)); full(gainSlider)
        section("Source RGB histogram", in: s)
        full(histogramView); histogramView.heightAnchor.constraint(equalToConstant: 120).isActive = true
        histogramCaption.font = .systemFont(ofSize: 10); histogramCaption.textColor = .secondaryLabelColor
        histogramCaption.lineBreakMode = .byTruncatingMiddle; full(histogramCaption)
        histogramOverlay.target = self; histogramOverlay.action = #selector(histogramOverlayChanged); full(histogramOverlay)
        section("Region & pixels", in: s)
        selectionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); full(selectionLabel)
        full(stack(.horizontal, spacing: 6, [button("Zoom to region", #selector(zoomToSelection)), button("Crop copy", #selector(cropCopy))]))
        pixelLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular); pixelLabel.textColor = .secondaryLabelColor; full(pixelLabel)
        section("Metrics · vs reference", in: s)
        let convention = NSTextField(wrappingLabelWithString: "RGB sRGB · range 0–1 · opaque inputs\nSSIM: 11×11 Gaussian, σ 1.5, valid\nNo automatic alignment or resizing")
        convention.font = .systemFont(ofSize: 10); convention.textColor = .secondaryLabelColor; full(convention)
        metricStack.orientation = .vertical; metricStack.spacing = 10; metricStack.alignment = .leading; full(metricStack)
        s.addArrangedSubview(button("Export metric report…", #selector(exportMetrics)))
        s.addArrangedSubview(button("Research models…", #selector(researchMetrics)))
        section("Annotations", in: s)
        sharedAnnotations.state = .on; sharedAnnotations.target = self; sharedAnnotations.action = #selector(annotationScopeChanged)
        full(sharedAnnotations)
        annotationColorControl.color = NSColor(calibratedRed: 0.18, green: 0.91, blue: 0.79, alpha: 1)
        annotationColorControl.target = self; annotationColorControl.action = #selector(annotationStyleChanged)
        annotationColorControl.widthAnchor.constraint(equalToConstant: 52).isActive = true
        annotationColorControl.heightAnchor.constraint(equalToConstant: 24).isActive = true
        full(stack(.horizontal, spacing: 8, [text("Drawing & text color"), annotationColorControl]))
        brushWidthControl.isContinuous = true; brushWidthControl.target = self; brushWidthControl.action = #selector(annotationStyleChanged)
        brushWidthLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        brushWidthLabel.widthAnchor.constraint(equalToConstant: 45).isActive = true
        full(stack(.horizontal, spacing: 8, [text("Width"), brushWidthControl, brushWidthLabel]))
        fontSizeControl.target = self; fontSizeControl.action = #selector(annotationStyleChanged); fontSizeControl.delegate = self
        full(stack(.horizontal, spacing: 8, [text("Text size (image px)"), fontSizeControl]))
        s.addArrangedSubview(button("Clear annotations", #selector(clearAnnotations)))
        section("Edit images", in: s)
        allEdits.state = .off; full(allEdits)
        s.addArrangedSubview(text("RGB channels · live", size: 11))
        for (name, slider, color) in [("R", redChannel, NSColor.systemRed), ("G", greenChannel, NSColor.systemGreen), ("B", blueChannel, NSColor.systemBlue)] {
            slider.isContinuous = true; slider.numberOfTickMarks = 3; slider.allowsTickMarkValuesOnly = false
            slider.target = self; slider.action = #selector(channelsChanged)
            slider.toolTip = "Left: channel off · center: original · right: maximum in every pixel"
            slider.onBeginDrag = { [weak self] in self?.beginChannelGesture() }
            slider.onEndDrag = { [weak self] in self?.channelGestureInProgress = false }
            let label = text(name, size: 11, color: color, bold: true); label.widthAnchor.constraint(equalToConstant: 14).isActive = true
            full(stack(.horizontal, spacing: 8, [label, slider]))
        }
        s.addArrangedSubview(text("Off  ←  original  →  maximum", size: 10))
        s.addArrangedSubview(button("Reset RGB channels", #selector(resetChannels)))
        filterControl.addItems(withTitles: ["Grayscale", "Gaussian blur", "Sharpen", "Gaussian noise", "Bilateral filter", "Match histogram to reference", "Clip RGB to 0–1", "Composite on white", "Composite on black"])
        full(filterControl); filterControl.target = self; filterControl.action = #selector(filterChoiceChanged)
        filterAmount.toolTip = "Blur σ in pixels; sharpen strength; noise σ in 0–255; bilateral range σ in 0–1 (spatial σ 2 px)"
        full(stack(.horizontal, spacing: 8, [text("Amount / σ"), filterAmount]))
        noiseSeed.toolTip = "Same seed produces the same noise in each image."
        full(stack(.horizontal, spacing: 8, [text("Noise seed"), noiseSeed]))
        full(stack(.horizontal, spacing: 8, [button("Apply edit", #selector(applyFilter)), button("Restore original", #selector(restoreOriginal))]))
        s.addArrangedSubview(text("ResizeRight-compatible resize", size: 11))
        full(stack(.horizontal, spacing: 6, [resizeWidth, text("×"), resizeHeight, button("Resize", #selector(resizeImages))]))
        historyLabel.font = .systemFont(ofSize: 10); historyLabel.textColor = .secondaryLabelColor; full(historyLabel)
        return scroll
    }
    func connectCanvas() {
        canvas.onInspect = { [weak self] p in self?.updatePixel(p) }
        canvas.onSelect = { [weak self] _ in self?.updateSelection(); self?.calculateMetrics(); self?.refreshHistograms() }
        canvas.onActiveImage = { [weak self] index in
            guard let self = self else { return }; self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); self.updateHistory()
        }
        canvas.onChange = { [weak self] in
            guard let self = self else { return }
            self.zoomLabel.stringValue = String(format: "%.0f%%", self.canvas.zoom * 100)
            self.modeControl.selectedSegment = [CompareMode.split, .flicker, .wipe].firstIndex(of: self.canvas.mode) ?? 0
            self.toolControl.selectItem(at: CanvasTool.allCases.firstIndex(of: self.canvas.tool) ?? 0)
        }
        canvas.onViewportChange = { [weak self] in self?.refreshDisplayCache() }
        canvas.onDropURLs = { [weak self] urls in self?.importURLs(urls) }
        canvas.onPaste = { [weak self] in self?.pasteImages() }
        canvas.onDropImageData = { [weak self] data in
            guard let self = self, !self.isProcessing, let ns = NSImage(data: data), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil), let buffer = try? PixelBuffer.from(cgImage: cg) else { return }
            let empty = self.entries.isEmpty
            self.entries.append(ImageEntry(title: "Dropped image", buffer: buffer)); self.undoSnapshots = []; self.redoSnapshots = []
            self.refreshEntries(fit: empty)
        }
        annotationStyleChanged()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let thumb = NSImageView(); thumb.image = NSImage(cgImage: e.cg, size: NSSize(width: e.buffer.width, height: e.buffer.height)); thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.widthAnchor.constraint(equalToConstant: 48).isActive = true; thumb.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = text("\(row + 1)  \(e.title)", size: 11, color: .labelColor, bold: true); name.lineBreakMode = .byTruncatingMiddle
        let detail = text("\(e.buffer.width) × \(e.buffer.height)", size: 10)
        let metadata = stack(.horizontal, spacing: 5, [detail])
        if row == canvas.referenceIndex {
            let badge = text(" REF ", size: 9, color: accent, bold: true)
            badge.wantsLayer = true; badge.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor; badge.layer?.cornerRadius = 3
            metadata.addArrangedSubview(badge)
        }
        let rowView = stack(.horizontal, spacing: 8, [thumb, stack(.vertical, spacing: 5, [name, metadata])]); rowView.edgeInsets = NSEdgeInsets(top: 6, left: 3, bottom: 6, right: 3)
        return rowView
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingTable, entries.indices.contains(table.selectedRow) else { return }
        canvas.activeIndex = table.selectedRow; canvas.needsDisplay = true; updateHistory()
    }
    func reloadSidebar() {
        updatingTable = true
        let selected = canvas.activeIndex
        table.reloadData()
        if entries.indices.contains(selected) { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        canvas.activeIndex = selected
        updatingTable = false
    }
    func updateHistory() {
        guard entries.indices.contains(canvas.activeIndex) else { return }
        let e = entries[canvas.activeIndex]
        historyLabel.stringValue = e.history.isEmpty ? "Original image · edits are undoable" : e.history.suffix(4).joined(separator: "\n")
        resizeWidth.stringValue = String(e.buffer.width); resizeHeight.stringValue = String(e.buffer.height)
        syncChannelControls()
        updateHistogramDisplay()
    }
    func refreshEntries(fit: Bool = false, preserveView: Bool = false) {
        let inspectorPosition = inspectorScroll.contentView.bounds.origin
        let savedView = visualization
        defer { restoreInspectorPosition(inspectorPosition) }
        analysisGeneration += 1; displayGeneration += 1; lastDisplayScale = -1
        analysisImages = [:]; analysisBuffers = [:]; visualization = "Images"; visualizationControl.selectItem(at: 0)
        if entries.isEmpty { canvas.activeIndex = 0; canvas.referenceIndex = 0; canvas.secondaryIndex = 0; canvas.pairIndex = 0 }
        else {
            canvas.activeIndex = min(canvas.activeIndex, entries.count - 1)
            canvas.referenceIndex = min(canvas.referenceIndex, entries.count - 1)
            canvas.secondaryIndex = min(canvas.secondaryIndex, entries.count - 1)
            canvas.pairIndex = min(canvas.pairIndex ?? 0, entries.count - 1)
        }
        canvas.images = entries.map { CanvasImage(id: $0.id, title: $0.title, image: $0.cg) }
        reloadSidebar()
        gtControl.removeAllItems(); partnerControl.removeAllItems()
        gtControl.addItems(withTitles: entries.enumerated().map { "\($0.offset + 1) · \($0.element.title)" })
        partnerControl.addItems(withTitles: entries.enumerated().map { "\($0.offset + 1) · \($0.element.title)" })
        if !entries.isEmpty {
            gtControl.selectItem(at: canvas.referenceIndex); partnerControl.selectItem(at: canvas.pairIndex ?? 0)
            table.selectRowIndexes(IndexSet(integer: canvas.activeIndex), byExtendingSelection: false)
        }
        if fit { canvas.fitImages() }
        updateHistory(); updateSelection(); calculateMetrics(); refreshHistograms(); refreshDisplayCache(force: true)
        if preserveView && savedView != "Images" { visualization = savedView; visualizationControl.selectItem(withTitle: savedView); updateAnalysis() }
    }
    @objc func openImages() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.image]; p.message = "Add images to the comparison set"
        if p.runModal() == .OK { importURLs(p.urls) }
    }
    func importURLs(_ urls: [URL]) {
        guard !isProcessing else { return }
        if let workspace = urls.first(where: { $0.pathExtension.lowercased() == "imspect" }) { loadWorkspace(from: workspace); return }
        let empty = entries.isEmpty; setBusy(true, "Loading images…")
        computeQueue.async {
            var loaded: [ImageEntry] = []; var errors: [String] = []
            for url in urls {
                do { loaded.append(ImageEntry(title: url.deletingPathExtension().lastPathComponent, buffer: try PixelBuffer.load(url: url))) }
                catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                self.entries.append(contentsOf: loaded); self.undoSnapshots = []; self.redoSnapshots = []
                if empty && self.entries.count > 1 { self.canvas.secondaryIndex = 1 }
                self.setBusy(false, "\(self.entries.count) images · original dimensions preserved")
                self.refreshEntries(fit: empty)
                if !errors.isEmpty { self.alert("Some images could not be loaded", errors.joined(separator: "\n")) }
            }
        }
    }
    @objc func pasteImages() {
        guard !isProcessing else { return }
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { importURLs(urls); return }
        if let image = NSImage(pasteboard: pb), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            do {
                let buffer = try PixelBuffer.from(cgImage: cg); let empty = entries.isEmpty
                entries.append(ImageEntry(title: "Pasted \(entries.count + 1)", buffer: buffer)); canvas.activeIndex = entries.count - 1
                if empty { canvas.secondaryIndex = 0 }; undoSnapshots = []; redoSnapshots = []
                refreshEntries(fit: empty); statusLabel.stringValue = "Image added from clipboard"
            } catch { alert("Cannot paste image", error.localizedDescription) }
        } else { statusLabel.stringValue = "The clipboard does not contain an image." }
    }
    @objc func demoAction() { loadDemo() }
    func loadDemo() {
        guard !isProcessing else { return }
        let w = 640, h = 480
        var p = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let fx = Float(x) / Float(w), fy = Float(y) / Float(h), i = (y * w + x) * 4
            p[i] = 0.08 + fx * 0.23; p[i+1] = 0.12 + fy * 0.27; p[i+2] = 0.18 + (1-fx) * 0.2
            let dx = Float(x - 340), dy = Float(y - 215), r = sqrt(dx*dx + dy*dy)
            if r < 155 { p[i] = 0.83 + 0.1 * sin(fy*20); p[i+1] = 0.25 + 0.5 * fx; p[i+2] = 0.1 + 0.2 * fy }
            if r < 109 && r > 68 { let v:Float = sin(r * 1.7) > 0 ? 0.86 : 0.14; p[i] = v; p[i+1] = v; p[i+2] = v }
            if x > 50 && x < 205 && y > 80 && y < 230 { let v:Float = ((x/5+y/5)%2 == 0) ? 0.2 : 0.85; p[i] = v*0.55; p[i+1] = v; p[i+2] = v*0.8 }
            if y > 365 && y < 410 && x > 50 && x < 585 { p[i] = fx; p[i+1] = 1-fx; p[i+2] = abs(sin(fx*6)) }
            if abs(x-y) < 2 { p[i] = 0.93; p[i+1] = 0.93; p[i+2] = 0.93 }
        } }
        let original = PixelBuffer(width: w, height: h, rgba: p)
        do {
            let noisy = try ImageEngine.filter(original, kind: "noise", amount: 0.04, seed: 42)
            let smooth = try ImageEngine.filter(noisy, kind: "gaussian", amount: 0.8, seed: 42)
            entries = [ImageEntry(title: "Resolution target · REF", buffer: original), ImageEntry(title: "Noise · σ 10.2", buffer: noisy), ImageEntry(title: "Gaussian · σ 0.8", buffer: smooth)]
            canvas.activeIndex = 1; canvas.referenceIndex = 0; canvas.secondaryIndex = 0
            canvas.selection = nil; canvas.clearAnnotations(); undoSnapshots = []; redoSnapshots = []
            refreshEntries(fit: true); statusLabel.stringValue = "Demo · synthetic resolution target, reproducible noise (seed 42)"
        } catch { alert("Demo failed", error.localizedDescription) }
    }
    @objc func removeImage() {
        removeImageAtIndex(canvas.activeIndex)
    }
    func removeImageAtIndex(_ index: Int) {
        guard !isProcessing, entries.indices.contains(index) else { return }
        pausePlayback()
        let gtID = entries[canvas.referenceIndex].id
        let partnerID = entries[min(canvas.pairIndex ?? 0, entries.count - 1)].id
        let activeID = entries[canvas.activeIndex].id
        let removedID = entries[index].id
        entries.remove(at: index)
        canvas.activeIndex = entries.firstIndex { $0.id == activeID } ?? min(index, max(0, entries.count - 1))
        canvas.referenceIndex = entries.firstIndex { $0.id == gtID } ?? 0
        canvas.pairIndex = entries.firstIndex { $0.id == partnerID } ?? 0
        canvas.annotations.removeAll { $0.imageID == removedID }
        undoSnapshots = []; redoSnapshots = []; refreshEntries()
    }
    @objc func duplicateImage() {
        guard !isProcessing, entries.indices.contains(canvas.activeIndex) else { return }
        let e = entries[canvas.activeIndex]; entries.append(ImageEntry(title: e.title + " copy", buffer: e.buffer, original: e.original, history: e.history, channelBase: e.channelBase, channelLevels: e.channelLevels))
        canvas.activeIndex = entries.count - 1; undoSnapshots = []; redoSnapshots = []; refreshEntries()
    }
    @objc func modeChanged() {
        canvas.mode = [CompareMode.split, .flicker, .wipe][modeControl.selectedSegment]; canvas.needsDisplay = true
        speedChanged(); window?.makeFirstResponder(canvas)
    }
    @objc func toolChanged() { canvas.tool = CanvasTool.allCases[toolControl.indexOfSelectedItem]; window?.makeFirstResponder(canvas) }
    @objc func zoomIn() { canvas.zoomBy(1.25) }
    @objc func zoomOut() { canvas.zoomBy(0.8) }
    @objc func fitImages() { canvas.fitImages() }
    @objc func actualSize() { canvas.zoomBy(1 / max(canvas.zoom, 0.001)) }
    @objc func clearSelection() { canvas.selection = nil; canvas.needsDisplay = true; updateSelection(); calculateMetrics(); refreshHistograms() }
    @objc func setGT() { canvas.referenceIndex = canvas.activeIndex; gtControl.selectItem(at: canvas.activeIndex); reloadSidebar(); calculateMetrics(); updateHistogramDisplay(); updateAnalysis() }
    @objc func gtChanged() { canvas.referenceIndex = max(0, gtControl.indexOfSelectedItem); reloadSidebar(); calculateMetrics(); updateHistogramDisplay(); updateAnalysis() }
    @objc func partnerChanged() { canvas.pairIndex = max(0, partnerControl.indexOfSelectedItem); canvas.needsDisplay = true }
    @objc func annotationScopeChanged() { canvas.annotateAll = sharedAnnotations.state == .on }
    @objc func clearAnnotations() { canvas.clearAnnotations() }
    @objc func togglePlay() {
        if timer != nil { pausePlayback() }
        else { if canvas.mode == .split { canvas.mode = .flicker; modeControl.selectedSegment = 1 }; playButton.title = "Ⅱ Pause"; restartTimer() }
    }
    func pausePlayback() { timer?.invalidate(); timer = nil; playButton.title = "▶ Play" }
    @objc func playbackChanged() { if timer != nil { restartTimer() } }
    @objc func speedChanged() {
        speedLabel.stringValue = canvas.mode == .wipe ? String(format: "%.2g s / sweep", 4 / speedSlider.doubleValue) : String(format: "%.2g switches/s", speedSlider.doubleValue)
        if timer != nil { restartTimer() }
    }
    func restartTimer() {
        timer?.invalidate()
        let interval = canvas.mode == .wipe ? 1.0 / 60 : 1 / speedSlider.doubleValue
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.advancePlaybackFrame()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func advancePlaybackFrame() {
        guard entries.count > 1 else { return }
        if canvas.mode == .wipe {
            canvas.wipePosition += wipeDirection * CGFloat(speedSlider.doubleValue / 60 / 4)
            var boundary = false
            if canvas.wipePosition >= 1 { canvas.wipePosition = 1; wipeDirection = -1; boundary = true }
            if canvas.wipePosition <= 0 { canvas.wipePosition = 0; wipeDirection = 1; boundary = true }
            if boundary && playbackControl.indexOfSelectedItem == 1 {
                canvas.nextImage()
                if canvas.activeIndex == (canvas.pairIndex ?? canvas.referenceIndex) { canvas.nextImage() }
            }
            canvas.needsDisplay = true
        } else if playbackControl.indexOfSelectedItem == 1 { canvas.nextImage() }
        else { canvas.togglePair() }
    }
    var selectedKernel: ResizeKernel { [.nearest, .linear, .cubic, .lanczos2, .lanczos3][max(0, kernelControl.indexOfSelectedItem)] }
    @objc func kernelChanged() { refreshDisplayCache(force: true) }
    func updatePixel(_ p: CGPoint) {
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        var lines = ["x \(x)  y \(y) · \(visualization == "Images" ? "source" : "display") RGB 0–255"]
        for (i,e) in entries.enumerated() {
            let sample = analysisBuffers[e.id] ?? e.buffer
            if let c = sample.pixel(x: x, y: y) { lines.append(String(format: "%d  %7.2f %7.2f %7.2f", i+1, c[0]*255, c[1]*255, c[2]*255)) }
            else { lines.append("\(i+1)  outside image") }
        }
        pixelLabel.stringValue = lines.joined(separator: "\n")
    }
    func updateSelection() {
        if let r = canvas.selection { selectionLabel.stringValue = "x \(Int(r.minX))  y \(Int(r.minY))\n\(Int(r.width)) × \(Int(r.height)) pixels" }
        else { selectionLabel.stringValue = "Full image · coordinates from top left" }
    }
    @objc func zoomToSelection() {
        guard let r = canvas.selection, r.width > 0, r.height > 0 else { return }
        // Canvas supplies a coordinate-aware selection fit when available.
        canvas.zoomToSelection()
    }
    @objc func visualizationChanged() {
        if visualization == "Centered FFT magnitude" { canvas.selection = nil; updateSelection() }
        visualization = visualizationControl.titleOfSelectedItem ?? "Images"; updateAnalysis(); refreshHistograms()
    }
    @objc func gainChanged() { updateAnalysis() }
    func updateAnalysis() {
        analysisGeneration += 1; let generation = analysisGeneration
        guard entries.indices.contains(canvas.referenceIndex) else { return }
        if visualization == "Images" { analysisImages = [:]; analysisBuffers = [:]; refreshDisplayCache(force: true); calculateMetrics(); return }
        if visualization == "Centered FFT magnitude" { canvas.selection = nil; updateSelection(); calculateMetrics() }
        let items = entries.map { ($0.id, $0.buffer) }; let gt = entries[canvas.referenceIndex].buffer
        let view = visualization; let gain = gainSlider.floatValue
        statusLabel.stringValue = "Computing \(view.lowercased())…"
        computeQueue.async {
            var images: [UUID:CGImage] = [:]; var buffers: [UUID:PixelBuffer] = [:]; var errors: [String] = []
            for (id,b) in items {
                do {
                    let result: PixelBuffer
                    if view == "Centered FFT magnitude" { result = ImageEngine.fft(b) }
                    else { result = try ImageEngine.heatmap(b, gt, kind: view == "Absolute difference" ? "absolute" : view == "MSE heatmap" ? "mse" : "ssim", gain: gain) }
                    images[id] = result.cgImage(); buffers[id] = result
                } catch { errors.append(error.localizedDescription) }
            }
            DispatchQueue.main.async {
                guard generation == self.analysisGeneration else { return }
                if !errors.isEmpty { self.visualization = "Images"; self.visualizationControl.selectItem(at: 0); self.analysisImages = [:]; self.analysisBuffers = [:]; self.alert("Analysis unavailable", errors[0]) }
                else { self.analysisImages = images; self.analysisBuffers = buffers }
                self.refreshDisplayCache(force: true)
                self.statusLabel.stringValue = view == "Centered FFT magnitude" ? "FFT · luminance · centered log magnitude · power-of-two padding · shared amplitude scale" : "\(view) · compared with reference · fixed gain \(String(format: "%.1f", gain))"
            }
        }
    }
    @objc func filterChoiceChanged() {
        filterAmount.stringValue = filterControl.indexOfSelectedItem == 3 ? "10" : filterControl.indexOfSelectedItem == 4 ? "0.1" : "1.0"
    }
    func snapshot() -> Snapshot { Snapshot(buffers: entries.map { $0.buffer }, histories: entries.map { $0.history }, channelBases: entries.map { $0.channelBase }, channelLevels: entries.map { $0.channelLevels }) }
    func applyOperation(_ description: String, operation: @escaping (PixelBuffer) throws -> PixelBuffer) {
        guard !isProcessing, !entries.isEmpty else { return }
        pausePlayback()
        let indices = allEdits.state == .on ? Array(entries.indices) : [canvas.activeIndex]
        let input = indices.map { entries[$0].buffer }; let before = snapshot()
        setBusy(true, description + "…")
        computeQueue.async {
            do {
                let results = try input.map(operation)
                DispatchQueue.main.async {
                    self.undoSnapshots.append(before); self.undoSnapshots = Array(self.undoSnapshots.suffix(10)); self.redoSnapshots = []
                    for (i,result) in zip(indices,results) {
                        self.entries[i].buffer = result; self.entries[i].cg = result.cgImage(); self.entries[i].history.append(description)
                        self.entries[i].channelBase = nil; self.entries[i].channelLevels = [0, 0, 0]
                    }
                    self.setBusy(false, description + " · ⌘Z to undo"); self.refreshEntries(preserveView: true)
                }
            } catch { DispatchQueue.main.async { self.setBusy(false, "Edit was not applied"); self.alert("Cannot apply edit", error.localizedDescription) } }
        }
    }
    @objc func applyFilter() {
        guard entries.indices.contains(canvas.referenceIndex), let amount = Float(filterAmount.stringValue), amount.isFinite, amount >= 0, amount <= 100 else { alert("Invalid amount", "Enter a number from 0 to 100."); return }
        let kinds = ["grayscale", "gaussian", "sharpen", "noise", "bilateral", "histogram", "clip", "opaque", "opaque"]
        let kind = kinds[filterControl.indexOfSelectedItem]
        guard let seed = UInt64(noiseSeed.stringValue) else { alert("Invalid noise seed", "Use a nonnegative whole number."); return }
        let gt = entries[canvas.referenceIndex].buffer
        let title = filterControl.titleOfSelectedItem ?? kind
        let effectiveAmount: Float = filterControl.indexOfSelectedItem == 7 ? 1 : filterControl.indexOfSelectedItem == 8 ? 0 : kind == "noise" ? amount / 255 : amount
        applyOperation("\(title) · amount \(amount)\(kind == "noise" ? " · seed \(seed)" : "")") { image in
            if kind == "histogram" { return ImageEngine.histogramMatch(image, reference: gt) }
            return try ImageEngine.filter(image, kind: kind, amount: effectiveAmount, seed: seed)
        }
    }
    @objc func resizeImages() {
        guard let w = Int(resizeWidth.stringValue), let h = Int(resizeHeight.stringValue), w > 0, h > 0, w <= 16384, h <= 16384, w*h <= 32_000_000 else { alert("Invalid dimensions", "Use positive dimensions with at most 32 million output pixels."); return }
        let kernel = selectedKernel
        applyOperation("Resize \(w)×\(h) · \(kernel.rawValue) · AA · symmetric boundary") { try ImageEngine.resize($0, width: w, height: h, kernel: kernel) }
    }
    @objc func restoreOriginal() {
        guard !isProcessing, !entries.isEmpty else { return }
        pausePlayback()
        undoSnapshots.append(snapshot()); redoSnapshots = []
        for i in (allEdits.state == .on ? Array(entries.indices) : [canvas.activeIndex]) { entries[i].buffer = entries[i].original; entries[i].cg = entries[i].buffer.cgImage(); entries[i].history = []; entries[i].channelBase = nil; entries[i].channelLevels = [0, 0, 0] }
        refreshEntries()
    }
    @objc func undoEdit() {
        guard !isProcessing, let s = undoSnapshots.popLast(), s.buffers.count == entries.count else { return }
        redoSnapshots.append(snapshot()); restore(s)
    }
    @objc func redoEdit() {
        guard !isProcessing, let s = redoSnapshots.popLast(), s.buffers.count == entries.count else { return }
        undoSnapshots.append(snapshot()); restore(s)
    }
    func restore(_ snapshot: Snapshot) {
        pausePlayback()
        for i in entries.indices {
            entries[i].buffer = snapshot.buffers[i]; entries[i].cg = entries[i].buffer.cgImage(); entries[i].history = snapshot.histories[i]
            entries[i].channelBase = snapshot.channelBases.indices.contains(i) ? snapshot.channelBases[i] : nil
            entries[i].channelLevels = snapshot.channelLevels.indices.contains(i) ? snapshot.channelLevels[i] : [0, 0, 0]
        }
        refreshEntries(preserveView: true); statusLabel.stringValue = "Edit history restored"
    }
    func renderedImage(crop: Bool = false) -> NSImage? {
        guard entries.indices.contains(canvas.activeIndex) else { return nil }
        let e = entries[canvas.activeIndex]
        // Export annotations at original image dimensions, independent of preview resampling.
        let old = canvas.images
        canvas.images = entries.map { CanvasImage(id: $0.id, title: $0.title, image: analysisImages[$0.id] ?? $0.cg) }
        let source = analysisImages[e.id] ?? e.cg
        let hasAnnotations = canvas.annotations.contains { $0.imageID == nil || $0.imageID == e.id }
        let image = hasAnnotations ? (canvas.exportAnnotated(index: canvas.activeIndex, originalImage: source) ?? source) : source
        canvas.images = old
        if crop, let roi = canvas.selection {
            do {
                let result = try PixelBuffer.from(cgImage: image).cropped(roi)
                return NSImage(cgImage: result.cgImage(), size: NSSize(width: result.width, height: result.height))
            } catch { alert("Cannot export this region", error.localizedDescription); return nil }
        }
        return NSImage(cgImage: image, size: NSSize(width: source.width, height: source.height))
    }
    @objc func copyImage() { copy(crop: false) }
    @objc func cropCopy() { copy(crop: true) }
    func copy(crop: Bool) {
        guard let image = renderedImage(crop: crop) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]); statusLabel.stringValue = crop ? "Selected region copied with annotations" : "Image copied with annotations"
    }
    @objc func exportImage() {
        guard let image = renderedImage(crop: canvas.selection != nil), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let b = try? PixelBuffer.from(cgImage: cg), let data = b.pngData() else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.png]; p.nameFieldStringValue = entries[canvas.activeIndex].title + ".png"
        p.message = canvas.selection == nil ? "Export selected image with annotations" : "Export selected region with annotations"
        if p.runModal() == .OK, let url = p.url { do { try data.write(to: url); statusLabel.stringValue = "Exported \(url.lastPathComponent)" } catch { alert("Export failed", error.localizedDescription) } }
    }
    @objc func exportMetrics() {
        guard !cachedMetrics.isEmpty else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.commaSeparatedText]; p.nameFieldStringValue = "Imspect-metrics.csv"
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["image,reference,mse_rgb_0_1,psnr_db,ssim_gaussian11_valid,histogram_cdf_distance,mean_delta_e76,roi,operations,note"]
        let gt = entries.indices.contains(canvas.referenceIndex) ? entries[canvas.referenceIndex].title : ""
        for (i,result) in cachedMetrics.enumerated() {
            let m = result.1; let fields = [quoted(result.0), quoted(gt), m.map { String($0.mse) } ?? "", m.map { String($0.psnr) } ?? "", m?.ssim.map { String($0) } ?? "", m.map { String($0.histogramDistance) } ?? "", m?.meanDeltaE.map { String($0) } ?? "", quoted(selectionLabel.stringValue), quoted(entries.indices.contains(i) ? entries[i].history.joined(separator: "; ") : ""), quoted(result.2 ?? m?.convention ?? "")]
            lines.append(fields.joined(separator: ","))
        }
        if p.runModal() == .OK, let url = p.url { do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { alert("Export failed", error.localizedDescription) } }
    }
    func setBusy(_ value: Bool, _ status: String) { isProcessing = value; statusLabel.stringValue = status; if value { busy.startAnimation(nil) } else { busy.stopAnimation(nil) } }
    func alert(_ title: String, _ detail: String) { let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.runModal() }
}
