import Cocoa
import Vision

/// Slim editor window — a focused post-capture annotation window with a real NSToolbar
/// and a strict set of 5 annotation tools (select, arrow, text, censor, crop).
///
/// Opened from the slim-mode capture path (AppDelegate → overlayDidConfirm when
/// `slimEditorMode` UserDefault is true). Does NOT replace the thumbnail/Edit or
/// "Open in Editor Window" flows — those still open DetachedEditorWindowController.
@MainActor
class SlimEditorWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {

    // MARK: - Static lifecycle

    private static var activeControllers: [SlimEditorWindowController] = []

    static func open(image: NSImage, historyEntryID: String? = nil) {
        let controller = SlimEditorWindowController()
        controller.historyEntryID = historyEntryID
        controller.show(image: image)
        activeControllers.append(controller)
        if activeControllers.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Instance state

    private var window: NSWindow?
    private var editorView: EditorView?
    private var ocrController: OCRResultController?
    private var historyEntryID: String?
    private var lastSavedUndoDepth: Int = 0

    // MARK: - Window setup

    private func show(image: NSImage) {
        let imgSize = image.size
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame

        let minW: CGFloat = 500
        let minH: CGFloat = 300
        let maxW = screenFrame.width * 0.92
        let maxH = screenFrame.height * 0.92
        // Slim chrome: toolbar is NSToolbar (integrated into title bar), no extra bottom/right strips.
        // Add modest padding so the image isn't flush with the window edge.
        let padding: CGFloat = 16
        let winW = min(maxW, max(minW, imgSize.width + padding * 2))
        let winH = min(maxH, max(minH, imgSize.height + padding * 2))

        let win = SlimEditorWindow(
            contentRect: NSRect(
                x: screenFrame.midX - winW / 2,
                y: screenFrame.midY - winH / 2,
                width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: false
        )
        win.title = "macshot"
        win.subtitle = pixelSubtitle(for: image)
        win.minSize = NSSize(width: minW, height: minH)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.titlebarAppearsTransparent = false
        // Follow the SYSTEM appearance (light chrome in Light mode, dark in Dark)
        // rather than pinning to the always-dark theme bg. The slim editor's native
        // NSToolbar and the semantic canvas color below both track the window
        // appearance, so leaving this nil gives a true light OR dark editor.
        // (The forced-dark ToolOptionsRowView/PopoverHelper path is not used here.)
        win.appearance = nil

        // Install NSToolbar before showing the window.
        let toolbar = NSToolbar(identifier: "SlimEditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = true
        win.toolbar = toolbar
        // Modern unified style: title sits inline with the toolbar in a single
        // compact row (the Xcode/Mail/Safari look), rather than the legacy
        // two-row expanded title bar. Available since macOS 11; min target 12.3.
        win.toolbarStyle = .unified

        // EditorView inside NSScrollView + CenteringClipView
        let view = EditorView()
        view.frame = NSRect(origin: .zero, size: imgSize)
        view.autoresizingMask = []
        view.screenshotImage = image
        view.overlayDelegate = self
        // Suppress floating toolbar strips — slim editor uses NSToolbar instead.
        view.suppressFloatingToolbars = true
        // Fixed red annotation color — the slim editor has no color swatch, and
        // "red box / red arrow" is the intended look. NOTE: currentColor's didSet
        // persists lastUsedColor app-wide, so opening the slim editor resets the
        // overlay/detached editors to red. Accepted: the slim editor is the
        // primary path and red is the house style.
        view.currentColor = .systemRed
        // Clamp the opening tool to one that's actually in the enabled slim toolbar.
        // The global last-used tool may be one not shown here (e.g. pencil/ellipse);
        // fall back to Arrow if enabled, else the first enabled tool (always at least
        // Crop). NOTE: currentTool's didSet also persists lastUsedTool app-wide, so
        // this clamp can overwrite the global last-tool when it fires. Accepted for
        // the same reason as the color above. Selecting/moving/deleting existing
        // annotations does NOT require the removed Select tool — click-to-select
        // (startAnnotation) and Backspace-delete (keyDown) fire for any active tool.
        let enabledAtOpen = enabledSlimTools().map { $0.0 }
        if !enabledAtOpen.contains(view.currentTool) {
            view.currentTool = enabledAtOpen.contains(.arrow)
                ? .arrow
                : (enabledAtOpen.first ?? .crop)
        }

        let scrollView = NSScrollView(frame: win.contentView?.bounds ?? NSRect(origin: .zero, size: NSSize(width: winW, height: winH)))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        // Semantic canvas color that follows the system appearance: a neutral
        // page-gray in Light mode, dark in Dark mode (MarkEdit-style). Replaces
        // the always-dark themed bg so the slim editor has a true light mode.
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = false
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let clipView = CenteringClipView(frame: scrollView.contentView.frame)
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = view

        view.applySelection(NSRect(origin: .zero, size: imgSize))

        // Settle deferred state before snapshotting the baseline.
        view.ensureCustomBeautifyBackgroundLoaded()
        lastSavedUndoDepth = view.undoStack.count

        win.contentView = scrollView

        // Wire up chromeParentView AFTER win.contentView = scrollView so the property
        // points at the live scroll view (the actual content view), not the discarded
        // placeholder that win.contentView held before assignment.  This is the same
        // ordering used in DetachedEditorWindowController (chromeParentView = container
        // AFTER container is wired up).  The property is consulted by canvasToView()
        // for text placement and other coordinate helpers — pointing it at a dead view
        // silently broke text, censor, and crop tool coordinate math.
        view.chromeParentView = scrollView
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        // Fit-to-window for large images (same logic as DetachedEditorWindowController).
        scrollView.layoutSubtreeIfNeeded()
        let visible = scrollView.contentView.bounds.size
        if imgSize.width > 0, imgSize.height > 0, visible.width > 0, visible.height > 0 {
            let fitMag = min(visible.width / imgSize.width, visible.height / imgSize.height)
            let initialMag = min(1.0, fitMag)
            let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, initialMag))
            if clamped < 0.999 {
                scrollView.magnification = clamped
            }
        }

        // Scroll to top for tall images.
        if let docView = scrollView.documentView, scrollView.magnification >= 0.999 {
            docView.scroll(NSPoint(x: 0, y: docView.frame.maxY))
        }

        self.window = win
        self.editorView = view

        // Reflect the editor's current tool as the selected toolbar item, and
        // keep the two in sync whenever the tool changes (toolbar click or
        // keyboard shortcut). Set after the window is on screen so the toolbar
        // items are realized before we assign selectedItemIdentifier.
        view.onToolChange = { [weak self] tool in
            self?.syncToolbarSelection(to: tool)
        }
        syncToolbarSelection(to: view.currentTool)
    }

    private func pixelSubtitle(for image: NSImage) -> String {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return "\(cg.width) \u{00D7} \(cg.height)"
        }
        let w = Int(image.size.width)
        let h = Int(image.size.height)
        return "\(w) \u{00D7} \(h)"
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        editorView?.reset()
        editorView?.overlayDelegate = nil
        window?.contentView = nil
        editorView = nil
        window = nil
        Self.activeControllers.removeAll { $0 === self }
        if Self.activeControllers.isEmpty {
            (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
        }
    }

    // MARK: - NSToolbarDelegate

    // Action item IDs (static; tool IDs are dynamic — see toolItemID(for:)).
    private static let colorSwatchID  = NSToolbarItem.Identifier("slim.color")
    private static let undoID         = NSToolbarItem.Identifier("slim.undo")
    private static let redoID         = NSToolbarItem.Identifier("slim.redo")
    private static let copyID         = NSToolbarItem.Identifier("slim.copy")
    private static let saveID         = NSToolbarItem.Identifier("slim.save")
    private static let pinID          = NSToolbarItem.Identifier("slim.pin")
    // NOTE: Do NOT define a custom flexibleSpaceID static — NSToolbarItem.Identifier.flexibleSpace
    // is a magic system identifier; duplicating its rawValue creates a ghost toolbar item that
    // renders as a truncated label (e.g. "Bu..." from "Button") instead of a real spacer.
    // Use .flexibleSpace directly in toolbarDefaultItemIdentifiers and toolbarAllowedItemIdentifiers.

    /// Stable, per-tool identifier derived from the tool's rawValue.
    private func toolItemID(for tool: AnnotationTool) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("slim.tool.\(tool.rawValue)")
    }

    /// Returns the ordered (tool, SF-symbol, label) list that drives the slim toolbar.
    /// Mirrors the same tool ordering as ToolbarDefinitions.bottomButtons(_:) and
    /// filters by the "enabledTools" UserDefault ([Int] of rawValues).
    /// nil enabledTools (fresh install, never set) = all tools enabled.
    /// .crop is always appended last — it is editor-only and has no enabledTools entry.
    private func enabledSlimTools() -> [(AnnotationTool, String, String)] {
        // ponytail: no migration side-effects here; ToolbarDefinitions owns those writes.
        let enabledRaw = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]

        let allTools: [(AnnotationTool, String, String)] = [
            (.pencil,    "scribble",       "Pencil"),
            (.line,      "line.diagonal",  "Line"),
            (.arrow,     "arrow.up.right", "Arrow"),
            (.rectangle, "rectangle",      "Rectangle"),
            (.ellipse,   "oval",           "Ellipse"),
            (.marker,    {
                if #available(macOS 14.0, *) { return "highlighter" }
                return "paintbrush.pointed.fill"
            }(),                           "Marker"),
            (.text,      "textformat",     "Text"),
            (.number,    "1.circle.fill",  "Number"),
            (.pixelate,  "_custom.checkerboard", "Censor"),
            (.highlight, "sun.max",        "Highlight"),
            (.loupe,     "magnifyingglass","Magnify"),
            (.stamp,     "face.smiling",   "Stamp"),
            (.colorSampler, "eyedropper",  "Color Picker"),
            (.measure,   "ruler",          "Measure"),
        ]

        var result = allTools.filter { tool, _, _ in
            guard let enabledRaw = enabledRaw else { return true } // nil = all enabled
            return enabledRaw.contains(tool.rawValue)
        }
        // Crop is editor-only; always show it regardless of enabledTools.
        result.append((.crop, "crop", "Crop"))
        return result
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Tools driven by enabledTools UserDefault + always-present Crop.
        // Copy/Save/Pin actions stay fixed. Undo/Redo live on Cmd+Z / Cmd+Shift+Z;
        // color is fixed to red (no swatch) for a deliberately minimal bar.
        let toolIDs = enabledSlimTools().map { toolItemID(for: $0.0) }
        return toolIDs + [.flexibleSpace, Self.copyID, Self.saveID, Self.pinID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    // Only the annotation tools get the persistent "selected" highlight. The
    // action buttons (copy/save/pin) stay momentary — clicking them does NOT
    // clear the active-tool selection (matches Xcode: hitting Run doesn't
    // deselect your editor tool).
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        enabledSlimTools().map { toolItemID(for: $0.0) }
    }

    /// Maps an annotation tool to its toolbar identifier, or nil if the tool
    /// is not in the current enabled set (e.g. a keyboard shortcut switched to
    /// a tool not on this toolbar — toolbar selection should clear in that case).
    private func toolbarIdentifier(for tool: AnnotationTool) -> NSToolbarItem.Identifier? {
        let enabled = enabledSlimTools().map { $0.0 }
        guard enabled.contains(tool) else { return nil }
        return toolItemID(for: tool)
    }

    /// Sync the toolbar's selected item to the current tool. NSToolbar updates
    /// selection automatically on a toolbar click, but a keyboard/programmatic
    /// tool switch must update it explicitly.
    private func syncToolbarSelection(to tool: AnnotationTool) {
        window?.toolbar?.selectedItemIdentifier = toolbarIdentifier(for: tool)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Dynamic tool items: identifier rawValue is "slim.tool.<rawValue>".
        if itemIdentifier.rawValue.hasPrefix("slim.tool."),
           let rawInt = Int(itemIdentifier.rawValue.dropFirst("slim.tool.".count)),
           let tool = AnnotationTool(rawValue: rawInt) {
            // Look up symbol + label from the enabled list; fall back to a generic symbol
            // in case the identifier is stale (toolbar autosave re-requests old items).
            let entry = enabledSlimTools().first { $0.0 == tool }
            let symbol = entry?.1 ?? "questionmark.circle"
            let label  = entry?.2 ?? "\(tool)"
            return makeToolItem(id: itemIdentifier, symbol: symbol,
                                label: label, tip: label,
                                tag: tool.rawValue,
                                action: #selector(toolSelected(_:)))
        }

        switch itemIdentifier {

        case Self.colorSwatchID:
            return makeColorSwatchItem()

        case Self.undoID:
            return makeActionItem(id: itemIdentifier, symbol: "arrow.uturn.backward",
                                  label: "Undo", tip: "Undo (Cmd+Z)",
                                  action: #selector(undoAction(_:)))

        case Self.redoID:
            return makeActionItem(id: itemIdentifier, symbol: "arrow.uturn.forward",
                                  label: "Redo", tip: "Redo (Cmd+Shift+Z)",
                                  action: #selector(redoAction(_:)))

        case Self.copyID:
            return makeActionItem(id: itemIdentifier, symbol: "doc.on.doc",
                                  label: "Copy", tip: "Copy to clipboard (Cmd+C)",
                                  action: #selector(copyAction(_:)))

        case Self.saveID:
            return makeActionItem(id: itemIdentifier, symbol: "square.and.arrow.down",
                                  label: "Save", tip: "Save to file (Cmd+S)",
                                  action: #selector(saveAction(_:)))

        case Self.pinID:
            return makeActionItem(id: itemIdentifier, symbol: "pin",
                                  label: "Pin", tip: "Pin to screen",
                                  action: #selector(pinAction(_:)))

        default:
            return nil
        }
    }

    // MARK: - Toolbar validation (BUG C)
    // NSToolbar autovalidation calls validateToolbarItem for every item on every
    // event loop cycle. Without this, items whose action targets are not in the
    // responder chain get auto-disabled (greyed out). Returning true here keeps
    // all slim-editor toolbar items permanently enabled; the action methods
    // themselves guard on editorView being non-nil before acting.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        return true
    }

    // MARK: - Toolbar item factories

    private func makeToolItem(id: NSToolbarItem.Identifier, symbol: String, label: String, tip: String, tag: Int, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.tag = tag
        item.target = self
        item.action = action
        if symbol.hasPrefix("_custom.") {
            // Custom (programmatic) symbol — not a system or asset name.
            // ponytail: checkerboard generated inline; falls back to "square.grid.2x2" if
            // the symbol name is unknown, so pixelate never crashes or renders blank.
            if symbol == "_custom.checkerboard" {
                item.image = Self.checkerboardIcon()
            } else {
                item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: label)
            }
        } else if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            item.image = img
        }
        return item
    }

    /// Programmatic checkerboard icon for the Pixelate/Censor tool, mirroring
    /// ToolbarButtonView.checkerboardIcon but using a neutral monochrome tint
    /// suitable for NSToolbarItem (which applies its own tinting).
    private static func checkerboardIcon() -> NSImage {
        let size: CGFloat = 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let cellSize = size / 4
            let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                    xRadius: 3, yRadius: 3)
            clip.addClip()
            for row in 0..<4 {
                for col in 0..<4 {
                    let isDark = (row + col) % 2 == 0
                    if isDark {
                        NSColor.labelColor.setFill()
                    } else {
                        NSColor.labelColor.withAlphaComponent(0.35).setFill()
                    }
                    NSRect(x: CGFloat(col) * cellSize, y: CGFloat(row) * cellSize,
                           width: cellSize, height: cellSize).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func makeActionItem(id: NSToolbarItem.Identifier, symbol: String, label: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.target = self
        item.action = action
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            item.image = img
        }
        return item
    }

    private func makeColorSwatchItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.colorSwatchID)
        item.label = "Color"
        item.paletteLabel = "Color"
        item.toolTip = "Pick annotation color"
        let btn = ColorSwatchButton()
        btn.target = self
        btn.action = #selector(colorSwatchTapped(_:))
        btn.updateColor(editorView?.currentColor ?? .systemRed)
        item.view = btn
        return item
    }

    // MARK: - Toolbar actions

    @objc private func toolSelected(_ sender: NSToolbarItem) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        editorView?.currentTool = tool
    }

    @objc private func colorSwatchTapped(_ sender: NSButton) {
        guard let view = editorView else { return }
        let picker = ColorPickerView()
        picker.setColor(view.currentColor, opacity: 1.0)
        picker.onColorChanged = { [weak view, weak sender] color in
            view?.currentColor = color
            if let btn = sender as? ColorSwatchButton {
                btn.updateColor(color)
            }
        }
        // Pass appearance: nil so the color picker adapts to the window's light/dark mode.
        let rect = sender.bounds
        PopoverHelper.show(picker, size: NSSize(width: 240, height: 300),
                           relativeTo: rect, of: sender, preferredEdge: .minY,
                           appearance: nil)
    }

    @objc private func undoAction(_ sender: Any) {
        editorView?.undo()
    }

    @objc private func redoAction(_ sender: Any) {
        editorView?.redo()
    }

    @objc private func copyAction(_ sender: Any) {
        guard let raw = editorView?.captureSelectedRegion() else { return }
        ImageEncoder.copyToClipboard(raw)
        playCopySound()
        saveToHistoryIfNeeded(image: raw)
    }

    @objc private func saveAction(_ sender: Any) {
        guard let raw = editorView?.captureSelectedRegion() else { return }
        switch SaveActionPreference.current {
        case .saveToFolder:
            ImageSaveService.saveToConfiguredFolder(raw, sheetWindow: window) { [weak self] success in
                if success { self?.playCopySound() }
            }
        case .askWhereToSave:
            ImageSaveService.showSavePanel(for: raw, sheetWindow: window) { [weak self] success in
                if success { self?.playCopySound() }
            }
        }
        saveToHistoryIfNeeded(image: raw)
    }

    @objc private func pinAction(_ sender: Any) {
        guard let raw = editorView?.captureSelectedRegion() else { return }
        playCopySound()
        saveToHistoryIfNeeded(image: raw)
        (NSApp.delegate as? AppDelegate)?.showPin(image: raw)
    }

    // MARK: - Helpers

    private func saveToHistoryIfNeeded(image: NSImage) {
        guard let entryID = historyEntryID else { return }
        ScreenshotHistory.shared.updateEntry(
            id: entryID, compositedImage: image,
            rawImage: nil, annotations: nil, editState: nil)
    }

    private func playCopySound() {
        let enabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard enabled else { return }
        AppDelegate.captureSound?.stop()
        AppDelegate.captureSound?.play()
    }
}

// MARK: - OverlayViewDelegate

extension SlimEditorWindowController: OverlayViewDelegate {
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidCancel() { window?.performClose(nil) }
    func overlayViewDidChangeWindowSnapState() {}

    func overlayViewDidConfirm() {
        // Copy on Cmd+Return in editor mode.
        guard let raw = editorView?.captureSelectedRegion() else { return }
        ImageEncoder.copyToClipboard(raw)
        playCopySound()
        saveToHistoryIfNeeded(image: raw)
        (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: raw, historyEntryID: historyEntryID)
    }

    func overlayViewDidRequestSave() {
        switch SaveActionPreference.current {
        case .saveToFolder: overlayViewDidRequestFileSave()
        case .askWhereToSave: overlayViewDidRequestSaveAs()
        }
    }

    func overlayViewDidRequestSaveAs() {
        guard let raw = editorView?.captureSelectedRegion() else { return }
        ImageSaveService.showSavePanel(for: raw, sheetWindow: window) { [weak self] success in
            if success { self?.playCopySound() }
        }
    }

    func overlayViewDidRequestFileSave() {
        guard let raw = editorView?.captureSelectedRegion() else { return }
        ImageSaveService.saveToConfiguredFolder(raw, sheetWindow: window) { [weak self] success in
            if success { self?.playCopySound() }
        }
    }

    func overlayViewDidRequestPin() {
        guard let raw = editorView?.captureSelectedRegion() else { return }
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showPin(image: raw)
    }

    func overlayViewDidRequestOCR() {
        guard let image = editorView?.captureSelectedRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextAndQRCodeRecognition(cgImage: cgImage) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
                    let shouldCopy = ocrAction == 0 || ocrAction == 2
                    let shouldShowWindow = ocrAction == 0 || ocrAction == 1
                    if shouldCopy && !result.copyText.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.copyText, forType: .string)
                    }
                    if shouldShowWindow {
                        self.ocrController?.close()
                        let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
                        self.ocrController = ocr
                        ocr.show()
                    }
                }
            }
        }
    }

    func overlayViewDidRequestQuickSave() {
        guard let raw = editorView?.captureSelectedRegion() else { return }
        let mode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1
        if mode == 1 || mode == 2 { ImageEncoder.copyToClipboard(raw) }
        if mode == 0 || mode == 2 { ImageSaveService.saveToConfiguredFolder(raw, sheetWindow: window) }
        playCopySound()
        saveToHistoryIfNeeded(image: raw)
        (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: raw, historyEntryID: historyEntryID)
    }

    func overlayViewDidRequestUpload() {
        guard let raw = editorView?.captureSelectedRegion() else { return }
        (NSApp.delegate as? AppDelegate)?.uploadImage(raw)
    }

    func overlayViewDidRequestShare(anchorView: NSView?) {
        guard let raw = editorView?.captureSelectedRegion(),
              let data = ImageEncoder.encode(raw) else { return }
        let url = TmpScratchDirectory.makeURL(filename: FilenameFormatter.defaultImageFilename())
        try? data.write(to: url)
        let picker = NSSharingServicePicker(items: [url])
        if let anchor = anchorView {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
        } else if let view = editorView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    // Stubs for overlay-only features not applicable in editor mode.
    @available(macOS 14.0, *) func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidRequestAddCapture() {}
}

// MARK: - SlimEditorWindow

/// NSWindow subclass that intercepts Cmd+Q to close instead of quitting.
private class SlimEditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.keyCode == 12 { // Q
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - ColorSwatchButton

/// Small square button that shows the current annotation color as its fill.
private class ColorSwatchButton: NSButton {
    private var swatchColor: NSColor = .systemRed

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateColor(_ color: NSColor) {
        swatchColor = color
        layer?.backgroundColor = color.cgColor
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = isDark
            ? NSColor.white.withAlphaComponent(0.3).cgColor
            : NSColor.black.withAlphaComponent(0.25).cgColor
    }
}
