import AppKit
import Foundation

/// Structural layout regression for the native comparison workspace.
/// Compile with all Sources/*.swift except main.swift. No window is shown.
/// Optional: --snapshot-dir <directory> saves the first failing and final native view renderings.
@main struct LayoutTests {
    static var checks = 0
    static var states = 0
    static var failures: [String] = []
    static var heightBaselines: [String: CGFloat] = [:]
    static var snapshotDirectory: URL?
    static var savedFailure = false

    static func check(_ value: @autoclosure () -> Bool, _ detail: String) {
        checks += 1
        if !value() { failures.append(detail) }
    }
    static func near(_ left: CGFloat, _ right: CGFloat, tolerance: CGFloat = 1) -> Bool { abs(left-right) <= tolerance }
    static func settle(_ controller: WorkspaceController, duration: TimeInterval = 0.04) {
        let until = Date().addingTimeInterval(duration)
        repeat {
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < until
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }
    static func wait(_ controller: WorkspaceController, _ label: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { settle(controller,duration:0.01) }
        check(condition(),"\(label): background work did not finish")
    }
    static func snapshot(_ controller: WorkspaceController, name: String) {
        guard let directory = snapshotDirectory, let view = controller.window?.contentView else { return }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            if let png = bitmap.representation(using:.png,properties:[:]) { try png.write(to:directory.appendingPathComponent(name+".png")) }
        } catch { fputs("Snapshot could not be written: \(error.localizedDescription)\n",stderr) }
    }
    static func workspaceStack(_ root: NSView, inspector: NSView) -> NSStackView? {
        if let stack = root as? NSStackView, stack.orientation == .horizontal, stack.arrangedSubviews.contains(where: { $0 === inspector }) { return stack }
        for child in root.subviews { if let found = workspaceStack(child,inspector:inspector) { return found } }
        return nil
    }
    static func verify(_ controller: WorkspaceController, state: String) {
        settle(controller)
        states += 1
        let oldFailures = failures.count
        guard let root = controller.window?.contentView,
              let body = workspaceStack(root,inspector:controller.inspectorScroll), body.arrangedSubviews.count == 3 else {
            check(false,"\(state): comparison body is not a three-panel workspace"); return
        }
        let sidebar = body.arrangedSubviews[0], middle = body.arrangedSubviews[1]
        func bounds(_ view: NSView) -> CGRect { view.convert(view.bounds,to:root) }
        let outer = root.bounds, bodyRect = bounds(body), left = bounds(sidebar), center = bounds(middle)
        let image = bounds(controller.canvas), right = bounds(controller.inspectorScroll)
        func require(_ condition: Bool, _ label: String, actual: CGFloat, expected: CGFloat) {
            check(condition,String(format:"%@ — %@: actual %.2f, expected %.2f",state,label,Double(actual),Double(expected)))
        }
        require(near(bodyRect.minX,outer.minX),"body left",actual:bodyRect.minX,expected:outer.minX)
        require(near(bodyRect.width,outer.width),"body fills window width",actual:bodyRect.width,expected:outer.width)
        require(near(left.minX,outer.minX),"sidebar left",actual:left.minX,expected:outer.minX)
        require(near(left.width,215),"sidebar width",actual:left.width,expected:215)
        require(near(right.width,284),"inspector width",actual:right.width,expected:284)
        require(near(right.maxX,outer.maxX),"inspector reaches right edge",actual:right.maxX,expected:outer.maxX)
        require(near(center.minX,left.maxX),"middle follows sidebar",actual:center.minX,expected:left.maxX)
        require(near(center.maxX,right.minX),"middle meets inspector",actual:center.maxX,expected:right.minX)
        require(near(image.minX,outer.minX+215),"canvas left",actual:image.minX,expected:outer.minX+215)
        require(near(image.width,outer.width-499),"canvas fills remaining width",actual:image.width,expected:outer.width-499)
        require(near(left.height,bodyRect.height),"sidebar body height",actual:left.height,expected:bodyRect.height)
        require(near(right.height,bodyRect.height),"inspector body height",actual:right.height,expected:bodyRect.height)
        check(image.height >= outer.height*0.5,"\(state): usable canvas height collapsed to \(image.height) of \(outer.height)")
        let sizeKey = "\(Int(outer.width.rounded()))x\(Int(outer.height.rounded()))"
        if let baseline = heightBaselines[sizeKey] {
            require(near(image.height,baseline,tolerance:1),"canvas height is stable at unchanged window size",actual:image.height,expected:baseline)
        } else { heightBaselines[sizeKey] = image.height }
        if failures.count > oldFailures {
            fputs("LAYOUT \(state): root=\(outer), sidebar=\(left), canvas=\(image), inspector=\(right)\n",stderr)
            if !savedFailure { snapshot(controller,name:"first-failure"); savedFailure = true }
        }
    }
    static func main() throws {
        if let index = CommandLine.arguments.firstIndex(of:"--snapshot-dir"), CommandLine.arguments.count > index+1 {
            snapshotDirectory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = WorkspaceController()
        guard let window = controller.window else { fatalError("The native window did not initialize") }
        window.setContentSize(NSSize(width:2048,height:1152))
        verify(controller,state:"fullscreen-sized empty workspace")
        if let root = window.contentView, let body = workspaceStack(root,inspector:controller.inspectorScroll) {
            let middle = body.arrangedSubviews[1]
            print("Structural ambiguity: body=\(body.hasAmbiguousLayout), middle=\(middle.hasAmbiguousLayout)")
            for attempt in 0..<3 {
                body.exerciseAmbiguityInLayout(); middle.exerciseAmbiguityInLayout()
                verify(controller,state:"structural ambiguity probe \(attempt)")
            }
        }
        controller.loadDemo()
        verify(controller,state:"demo while metrics are pending")
        wait(controller,"demo metrics",until:{ controller.cachedMetrics.count == 3 })
        wait(controller,"demo viewport",until:{ controller.displayCompletedGeneration == controller.displayGeneration })
        verify(controller,state:"demo metrics ready")

        controller.modeControl.selectedSegment = 0; controller.modeChanged()
        verify(controller,state:"split before automatic playback")
        controller.playbackControl.selectItem(at:1); controller.togglePlay()
        settle(controller,duration:0.6)
        check(controller.canvas.mode == .flicker && controller.timer != nil,"Split playback switches into active flicker mode")
        verify(controller,state:"automatic all-image flicker playback")
        for index in 0..<4 { controller.advancePlaybackFrame(); verify(controller,state:"all-image playback frame \(index)") }
        controller.modeControl.selectedSegment = 2; controller.modeChanged()
        settle(controller,duration:0.12)
        verify(controller,state:"animated boundary wipe")
        controller.pausePlayback()
        verify(controller,state:"paused boundary wipe")
        for mode in [0,1,2,0] {
            controller.modeControl.selectedSegment = mode; controller.modeChanged()
            verify(controller,state:"manual mode \(mode)")
        }
        for row in 0..<3 {
            controller.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            verify(controller,state:"select sidebar row \(row)")
        }
        controller.entries[2].title = "Long candidate title · " + String(repeating:"reconstruction evaluation ",count:15)
        controller.entries[2].history = ["Gaussian denoising", String(repeating:"Extended operation provenance. ",count:15), "Bicubic reconstruction", "σ 0.08 · deterministic seed 42"]
        controller.reloadSidebar(); controller.updateHistory()
        verify(controller,state:"long candidate metadata")
        controller.entries[2].title = "Candidate"; controller.entries[2].history = []
        controller.reloadSidebar(); controller.updateHistory()
        verify(controller,state:"short candidate metadata")

        for (index,status) in ["Done",String(repeating:"A long analysis and export status message. ",count:50),"","Images ready · synchronized view"].enumerated() {
            controller.statusLabel.stringValue = status
            verify(controller,state:"status transition \(index)")
        }
        controller.canvas.selection = CGRect(x:32,y:41,width:96,height:100)
        controller.canvas.onSelect?(controller.canvas.selection)
        verify(controller,state:"ROI metrics pending")
        wait(controller,"ROI metrics",until:{ controller.cachedMetrics.count == 3 })
        verify(controller,state:"ROI metrics ready")
        controller.clearSelection()
        wait(controller,"full-image metrics",until:{ controller.cachedMetrics.count == 3 })
        verify(controller,state:"full-image metrics restored")

        for (index,size) in [NSSize(width:1440,height:920),NSSize(width:1120,height:740),NSSize(width:2048,height:1152),NSSize(width:2560,height:1440),NSSize(width:1366,height:768),NSSize(width:2048,height:1152)].enumerated() {
            window.setContentSize(size)
            verify(controller,state:"resize \(index) \(Int(size.width))×\(Int(size.height))")
            controller.modeControl.selectedSegment = index%3; controller.modeChanged()
            controller.table.selectRowIndexes(IndexSet(integer:index%3),byExtendingSelection:false)
            controller.statusLabel.stringValue = index%2 == 0 ? "Ready" : String(repeating:"Current image and analysis status · ",count:30)
            verify(controller,state:"mode and status after resize \(index)")
        }
        controller.pausePlayback()
        snapshot(controller,name:failures.isEmpty ? "passed-final" : "failed-final")
        window.orderOut(nil)
        if failures.isEmpty {
            print("PASS: \(checks) native layout checks across \(states) state transitions and 5 window sizes")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n",stderr) }
            fputs("FAILED: \(failures.count) of \(checks) layout checks across \(states) states\n",stderr)
            exit(1)
        }
    }
}
