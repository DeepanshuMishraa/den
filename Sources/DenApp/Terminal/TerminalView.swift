import AppKit
import Carbon.HIToolbox
import MetalKit
import DenProtocol
import DenVT

/// Draws one pane's replica with Metal. Interactive views also turn AppKit
/// input into VT bytes; thumbnail views scale the whole grid to fit and
/// ignore input (peek, exposé).
@MainActor
final class TerminalView: MTKView {
    enum Mode { case interactive, thumbnail }

    let paneID: PaneID
    let mode: Mode
    private weak var model: AppModel?
    private var replica: PaneReplica?
    private let pipelines: RenderPipelines
    private var metrics: FontMetrics
    private var renderState: VTRenderState?
    /// Textures for the replica's kitty images.
    private lazy var images = ImageTextures(device: pipelines.device, queue: pipelines.queue)
    private let keyEncoder = try? KeyEncoder()
    private let mouseEncoder = try? MouseEncoder()
    private let selection = try? SelectionGesture()
    private var scrollRemainder: CGFloat = 0
    private var pressedButtons = 0
    private var selecting = false
    /// The cell under the mouse while a click there would open a link.
    private var linkCell: (col: Int, row: Int)?
    /// The link under the mouse, underlined and opened by a click.
    private var hoveredLink: TerminalLink?
    /// The link pressed, opened on release if the click didn't drag.
    private var pressedLink: TerminalLink?
    private let scroller = ScrollIndicator()
    var isFocusedPane = false {
        didSet {
            guard oldValue != isFocusedPane else { return }
            needsDisplay = true
            cursorActivity()
            if isFocusedPane { claimFocus() }
        }
    }

    // MARK: Cursor blink

    /// When typing, output or a click last touched this pane; the blink
    /// rests solid for a moment after it.
    private var lastActivity = Date()
    private var blinkTimer: Timer?
    /// The cursor opacity the last frame drew, so ticks redraw only on change.
    private var drawnCursorOpacity: Float = 1

    private var cursorOpacity: Float {
        guard mode == .interactive, isFocusedPane, window?.isKeyWindow == true, let model, model.cursorBlink else { return 1 }
        return model.cursorBlinkStyle.opacity(sinceActivity: Date().timeIntervalSince(lastActivity),
                                              fades: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Restarts the blink at solid, and runs its timer only where it blinks.
    private func cursorActivity() {
        lastActivity = Date()
        guard model?.cursorBlink == true, mode == .interactive, isFocusedPane else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            return
        }
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, abs(self.cursorOpacity - self.drawnCursorOpacity) > 0.01 else { return }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    /// Inset of the grid inside the view, in points.
    static let padding = CGSize(width: 12, height: 4)

    init?(paneID: PaneID, model: AppModel, mode: Mode = .interactive) {
        guard let pipelines = RenderPipelines.shared else { return nil }
        self.paneID = paneID
        self.model = model
        self.mode = mode
        self.pipelines = pipelines
        self.metrics = FontMetrics(family: model.fontFamily, pointSize: model.fontSize, scale: NSScreen.main?.backingScaleFactor ?? 2)
        super.init(frame: .zero, device: pipelines.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        // Mid-resize, keep the last frame pinned at its origin instead of
        // stretching it; the redraw at the new size follows immediately.
        layerContentsPlacement = .topLeft
        layer?.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderState = try? VTRenderState()
        if mode == .interactive {
            scroller.onScroll = { [weak self] row in
                guard let replica = self?.replica else { return }
                replica.terminal.scrollViewport(toRow: row)
                replica.touch()
            }
            addSubview(scroller)
            // Files and images dropped or pasted onto the terminal become
            // shell-quoted paths at the cursor, so TUI agents get the file.
            registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        }
        attach(model.replica(paneID))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        replica?.stopObserving(self)
        blinkTimer?.invalidate()
    }

    /// Connects to the pane's replica once its snapshot has arrived.
    func attach(_ replica: PaneReplica?) {
        guard replica !== self.replica else { return }
        self.replica?.stopObserving(self)
        self.replica = replica
        // Output (and setting changes) show the cursor solid again.
        replica?.observe(self) { [weak self] in
            self?.needsDisplay = true
            self?.cursorActivity()
        }
        needsDisplay = true
        reportSize()
    }

    override var acceptsFirstResponder: Bool { mode == .interactive }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Thumbnails are part of a clickable card; let clicks reach SwiftUI.
        mode == .thumbnail ? nil : super.hitTest(point)
    }

    override func becomeFirstResponder() -> Bool {
        // Never switches tabs: a late focus change from a pane that is going
        // away must not pull the window back to its tab.
        model?.paneTookKeyboardFocus(paneID)
        sendFocus(true)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        sendFocus(false)
        needsDisplay = true
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isFocusedPane { claimFocus() }
    }

    /// Takes keyboard focus when the model says this pane is focused. Never
    /// takes it from a text field being edited (its field editor is an
    /// NSTextView); anything else, such as a SwiftUI host left holding focus
    /// after a click on the tab bar, gives it up, or typing would go nowhere.
    private func claimFocus() {
        guard mode == .interactive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFocusedPane, let window = self.window, window.firstResponder !== self else { return }
            if !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(self)
            }
        }
    }

    private var lastFocusRequest = 0

    /// After a menu or the palette closes, the focused pane takes the
    /// keyboard back even though it no longer holds first responder.
    func reclaimFocus(request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        guard mode == .interactive, isFocusedPane else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    private func sendFocus(_ gained: Bool) {
        guard let replica, replica.terminal.focusReporting else { return }
        model?.input(paneID, VTTerminal.encodeFocus(gained))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        if scale != metrics.scale { metrics = FontMetrics(family: metrics.family, pointSize: metrics.pointSize, scale: scale) }
        reportSize()
    }

    /// Switches font or size; the grid is re-measured and dend told.
    func applyFont(family: String, size: CGFloat) {
        guard family != metrics.family || size != metrics.pointSize else { return }
        metrics = FontMetrics(family: family, pointSize: size, scale: window?.backingScaleFactor ?? metrics.scale)
        needsDisplay = true
        reportSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroller.frame = NSRect(x: newSize.width - ScrollIndicator.hitWidth, y: 0, width: ScrollIndicator.hitWidth, height: newSize.height)
        // Drawing is on demand, so a new size needs an explicit redraw or the
        // pane shows the old frame until the server's reflow arrives.
        needsDisplay = true
        reportSize()
    }

    private func reportSize() {
        guard mode == .interactive, let model, bounds.width > 0, bounds.height > 0 else { return }
        let scale = metrics.scale
        let usableW = (bounds.width - Self.padding.width * 2) * scale
        let usableH = (bounds.height - Self.padding.height * 2) * scale
        let cols = UInt16(clamping: max(2, Int(usableW / metrics.cellWidth)))
        let rows = UInt16(clamping: max(1, Int(usableH / metrics.cellHeight)))
        model.resize(paneID, GridSize(cols: cols, rows: rows, cellWidthPx: UInt32(metrics.cellWidth), cellHeightPx: UInt32(metrics.cellHeight)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor, let model,
              let atlas = pipelines.atlas(for: metrics, smoothing: model.fontSmoothing),
              let buffer = pipelines.queue.makeCommandBuffer() else { return }

        let pad = SIMD2(Float(Self.padding.width * metrics.scale), Float(Self.padding.height * metrics.scale))
        var frame = FrameBuilder(
            metrics: metrics, atlas: atlas, pipelines: pipelines,
            origin: mode == .thumbnail ? .zero : pad,
            theme: replica?.theme ?? model.theme,
            cursorFocused: mode == .interactive && isFocusedPane && window?.isKeyWindow == true,
            showCursor: mode == .interactive,
            contrastCorrection: replica?.contrastCorrection ?? false,
            ligatures: model.fontLigatures,
            cursorOpacity: cursorOpacity
        )
        drawnCursorOpacity = frame.cursorOpacity
        var gridSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        // Laid out for the current cell size each frame, so images follow
        // font size and display scale changes.
        var placements: [VTImagePlacement] = []
        if let replica, let renderState {
            do {
                try renderState.update(from: replica.terminal)
                frame.build(renderState)
                placements = try replica.terminal.imagePlacements(cellWidth: Float(metrics.cellWidth), cellHeight: Float(metrics.cellHeight))
                refreshHover()
                if let hoveredLink { frame.underline(hoveredLink) }
                let (cols, rows) = renderState.size
                gridSize = SIMD2(Float(cols) * Float(metrics.cellWidth), Float(rows) * Float(metrics.cellHeight))
            } catch {
                NSLog("Den: render update for \(paneID) failed: \(error)")
            }
            if mode == .interactive {
                scroller.setColor((replica.theme).foreground.nsColor)
                scroller.update(replica.terminal.scrollbar)
            }
        }

        let clear = frame.clear.map { $0.simd() } ?? .zero
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: Double(clear.w))
        pass.colorAttachments[0].loadAction = .clear
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Thumbnails map the whole grid into the drawable, preserving aspect.
        var viewport = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        if mode == .thumbnail, gridSize.x > 0, gridSize.y > 0 {
            let fit = min(viewport.x / gridSize.x, viewport.y / gridSize.y)
            viewport /= fit
        }
        var uniforms = SIMD4<Float>(viewport.x, viewport.y, Float(atlas.texture.width), Float(atlas.texture.height))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 0)

        func drawRects(_ rects: [RectInstance]) {
            guard !rects.isEmpty, let b = pipelines.device.makeBuffer(bytes: rects, length: MemoryLayout<RectInstance>.stride * rects.count) else { return }
            encoder.setRenderPipelineState(pipelines.rect)
            encoder.setVertexBuffer(b, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rects.count)
        }
        if let terminal = replica?.terminal { images.beginFrame(terminal) }
        let origin = SIMD4(frame.origin.x, frame.origin.y, 0, 0)
        func drawImages(_ layer: VTImagePlacement.Layer) {
            guard let terminal = replica?.terminal else { return }
            for placement in placements where placement.layer == layer {
                guard let texture = images.texture(for: placement, in: terminal) else { continue }
                var instance = (placement.clip + origin, placement.image + origin)
                encoder.setRenderPipelineState(pipelines.image)
                encoder.setVertexBytes(&instance, length: MemoryLayout<(SIMD4<Float>, SIMD4<Float>)>.size, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        drawImages(.belowBackgrounds)
        drawRects(frame.backgrounds)
        drawRects(frame.selections)
        drawImages(.belowText)
        if !frame.glyphs.isEmpty, let b = pipelines.device.makeBuffer(bytes: frame.glyphs, length: MemoryLayout<GlyphInstance>.stride * frame.glyphs.count) {
            encoder.setRenderPipelineState(pipelines.glyph)
            encoder.setVertexBuffer(b, offset: 0, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: frame.glyphs.count)
        }
        drawImages(.aboveText)
        drawRects(frame.decorations)
        images.endFrame()
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: Keyboard

    /// Config keybinds run before Den's menu shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, runKeybind(event) else { return super.performKeyEquivalent(with: event) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard mode == .interactive, let model else { return }
        if event.keyCode == UInt16(kVK_Escape), model.overview != .none {
            model.overview = .none
            return
        }
        if runKeybind(event) { return }
        sendKey(event)
    }

    private func sendKey(_ event: NSEvent) {
        guard let replica, let keyEncoder, let model else { return }
        let bytes = keyEncoder.encode(keyInput(event, action: event.isARepeat ? .repeat : .press), terminal: replica.terminal, optionAsAlt: optionAsAlt)
        guard !bytes.isEmpty else { return }
        cursorActivity()
        replica.terminal.clearSelection()
        replica.scroll(.bottom)
        model.input(paneID, bytes)
    }

    /// Runs the config keybind for `event`, if there is one.
    private func runKeybind(_ event: NSEvent) -> Bool {
        guard mode == .interactive, event.type == .keyDown, let model, let replica,
              let bind = model.config.keybind(keyCode: event.keyCode, unmodified: event.characters(byApplyingModifiers: []), flags: event.modifierFlags)
        else { return false }
        switch bind.action {
        case .ignore: break
        case .command(let command): command.perform(model)
        case .passthrough: sendKey(event)
        case .text(let bytes):
            replica.terminal.clearSelection()
            replica.scroll(.bottom)
            model.input(paneID, bytes)
        }
        return true
    }

    override func keyUp(with event: NSEvent) {
        guard mode == .interactive, let replica, let keyEncoder, let model else { return }
        model.input(paneID, keyEncoder.encode(keyInput(event, action: .release), terminal: replica.terminal, optionAsAlt: optionAsAlt))
    }

    private var optionAsAlt: OptionAsAlt { model?.config.optionAsAlt ?? .both }

    private func keyInput(_ event: NSEvent, action: KeyAction) -> KeyInput {
        let flags = event.modifierFlags
        var mods: KeyMods = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.super) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }
        // Device-dependent bits (NX_DEVICELALTKEYMASK/NX_DEVICERALTKEYMASK)
        // say which option key is down.
        let rightOption = flags.contains(.option) && flags.rawValue & 0x40 != 0 && flags.rawValue & 0x20 == 0
        if rightOption { mods.insert(.altRight) }
        let optionIsAlt = flags.contains(.option) && optionAsAlt.treatsAsAlt(rightSide: rightOption)

        // With option-as-alt the text is what the key types without option,
        // and the encoder adds the ESC prefix. Otherwise option composes it.
        let produced = event.type == .keyDown || event.type == .keyUp
            ? (optionIsAlt ? event.characters(byApplyingModifiers: flags.subtracting(.option)) : event.characters)
            : nil
        let text = produced.flatMap { s -> String? in
            guard let scalar = s.unicodeScalars.first else { return nil }
            // Control characters and AppKit's function-key range are encoded
            // from the physical key instead.
            if scalar.value < 0x20 || scalar.value == 0x7F || (0xF700 ... 0xF8FF).contains(scalar.value) { return nil }
            return s
        }
        // Control and command never translate text; option does only when
        // it isn't alt. Whatever remains (shift, caps lock) produced the
        // text, so kitty-mode programs get `:` and not `<S-;>`.
        var consumed = mods.subtracting(optionIsAlt ? [.ctrl, .alt, .altRight, .super] : [.ctrl, .altRight, .super])
        if text == nil { consumed = [] }
        let unshifted = (event.type == .keyDown || event.type == .keyUp)
            ? event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
            : 0
        return KeyInput(macKeyCode: (event.type == .keyDown || event.type == .keyUp) ? event.keyCode : 0,
                        action: action, mods: mods, consumedMods: consumed, text: text, unshifted: unshifted)
    }

    @objc func paste(_ sender: Any?) {
        guard let replica else { return }
        let board = NSPasteboard.general
        // Plain text first: the common case, byte-for-byte as before.
        if let text = board.string(forType: .string), !text.isEmpty {
            replica.scroll(.bottom)
            model?.input(paneID, replica.terminal.encodePaste(text))
            return
        }
        // A copied file (Finder's ⌘C, a screenshot file) pastes as its path.
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            insertFileURLs(urls)
            return
        }
        // A copied image with no file (screenshot to clipboard, browser
        // image) is saved to a temp PNG and its path pasted, so TUI agents
        // receive something they can read.
        if let data = board.data(forType: .tiff) ?? board.data(forType: .png),
           let image = NSImage(data: data),
           let url = Self.writePastedImage(image) {
            insertFileURLs([url])
            return
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let text = replica?.terminal.selectedText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        mode == .interactive && canAcceptDrop(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        mode == .interactive && canAcceptDrop(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard mode == .interactive, let replica, let model else { return false }
        let urls = urls(from: sender)
        if !urls.isEmpty {
            window?.makeFirstResponder(self)
            insertFileURLs(urls)
            return true
        }
        // Dragged text (e.g. from another app) types like a paste.
        if let text = sender.draggingPasteboard.string(forType: .string), !text.isEmpty {
            window?.makeFirstResponder(self)
            replica.scroll(.bottom)
            model.input(paneID, replica.terminal.encodePaste(text))
            return true
        }
        return false
    }

    /// File URLs from a drag or pasteboard: real files plus images offered as
    /// raw bitmaps (written to a temp PNG first).
    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        if let data = board.data(forType: .tiff) ?? board.data(forType: .png),
           let image = NSImage(data: data),
           let url = Self.writePastedImage(image) {
            return [url]
        }
        return []
    }

    /// Whether a drag carries something we can turn into paths, checked
    /// without side effects (no temp files written while hovering).
    private func canAcceptDrop(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return board.data(forType: .tiff) != nil || board.data(forType: .png) != nil
            || board.string(forType: .string) != nil
    }

    /// Types file paths at the cursor, shell-quoted and relative like Insert
    /// Path does, through bracketed paste when the program asked for it.
    private func insertFileURLs(_ urls: [URL]) {
        guard let replica, let model else { return }
        let cwd = model.cwd(of: paneID)
        let home = model.hostHomes[model.host(ofPane: paneID)]
        let text = urls.map { PathQuery.insertion(for: $0.path, cwd: cwd, home: home) }.joined(separator: " ")
        guard !text.isEmpty else { return }
        replica.scroll(.bottom)
        model.input(paneID, replica.terminal.encodePaste(text))
    }

    /// Saves a clipboard/dragged bitmap so it has a path agents can read.
    private static func writePastedImage(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Den/pastes", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "pasted-image-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000 ... 9999)).png"
            let url = dir.appending(path: name)
            try png.write(to: url)
            return url
        } catch {
            NSLog("Den: could not save pasted image: %@", error.localizedDescription)
            return nil
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let replica, let selection else { return }
        let rows = Int(replica.terminal.rows), cols = Int(replica.terminal.cols)
        let now = DispatchTime.now().uptimeNanoseconds
        let geometry = (columns: cols, cellWidth: Int(metrics.cellWidth), screenHeight: rows * Int(metrics.cellHeight))
        selection.handle(.press, col: 0, row: 0, x: 0, y: 0, timeNs: now, columns: geometry.columns, cellWidth: geometry.cellWidth, screenHeight: geometry.screenHeight, terminal: replica.terminal)
        selection.handle(.drag, col: cols - 1, row: rows - 1, x: Double(cols) * Double(metrics.cellWidth), y: Double(rows) * Double(metrics.cellHeight) - 1,
                         timeNs: now, columns: geometry.columns, cellWidth: geometry.cellWidth, screenHeight: geometry.screenHeight, terminal: replica.terminal)
        selection.handle(.release, col: cols - 1, row: rows - 1, x: 0, y: 0, timeNs: now, columns: geometry.columns, cellWidth: geometry.cellWidth, screenHeight: geometry.screenHeight, terminal: replica.terminal)
        replica.touch()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cursorActivity()
        pressedLink = nil
        swallowingClick = false
        // ⌘-click opens a link even when the program has the mouse. The
        // program never saw the press, so it mustn't see the drag or release.
        if mode == .interactive, event.modifierFlags.contains(.command), let link = link(at: event) {
            open(link)
            swallowingClick = true
            return
        }
        // ⌘-drag picks the pane up to move it.
        if mode == .interactive, event.modifierFlags.contains(.command), let model, model.beginPaneDrag(paneID, at: windowPoint(event)) {
            draggingPane = true
            NSCursor.closedHand.set()
            return
        }
        if wantsSelection(event) {
            // Shift-clicks only select (and extend a selection).
            let opensLinks = mode == .interactive && replica?.terminal.isMouseTracking == false
                && !event.modifierFlags.contains(.shift)
            pressedLink = opensLinks ? link(at: event) : nil
            return select(event, .press)
        }
        mouseReport(event, .press, .left)
    }

    override func mouseUp(with event: NSEvent) {
        if swallowingClick {
            swallowingClick = false
            return
        }
        if draggingPane {
            draggingPane = false
            model?.endPaneDrag()
            updateCursor(event.modifierFlags)
            return
        }
        if selecting {
            // Checked before the release, whose copy-on-select clears it.
            let selected = replica?.terminal.selectedText() != nil
            select(event, .release)
            // A click that didn't select anything opens the link it hit.
            if let link = pressedLink, !selected, self.link(at: event) == link { open(link) }
            pressedLink = nil
            return
        }
        mouseReport(event, .release, .left)
    }

    override func mouseDragged(with event: NSEvent) {
        if swallowingClick { return }
        if draggingPane {
            NSCursor.closedHand.set()
            return model?.updatePaneDrag(at: windowPoint(event)) ?? ()
        }
        if selecting { return select(event, .drag) }
        mouseReport(event, .motion, .left)
    }

    override func rightMouseDown(with event: NSEvent) { mouseReport(event, .press, .right) }
    override func rightMouseUp(with event: NSEvent) { mouseReport(event, .release, .right) }
    override func otherMouseDown(with event: NSEvent) { mouseReport(event, .press, .middle) }
    override func otherMouseUp(with event: NSEvent) { mouseReport(event, .release, .middle) }
    override func mouseMoved(with event: NSEvent) {
        updateHover(event, flags: event.modifierFlags)
        updateCursor(event.modifierFlags)
        // Nearing the right edge brings the scrollbar up to grab.
        let nearEdge = convert(event.locationInWindow, from: nil).x > bounds.width - ScrollIndicator.hitWidth
        scroller.setHovering(nearEdge)
        if nearEdge, scroller.alphaValue > 0 { NSCursor.arrow.set() }
        mouseReport(event, .motion, nil)
    }

    override func mouseExited(with event: NSEvent) {
        scroller.setHovering(false)
        setLinkCell(nil)
    }

    /// Holding ⌘ over a pane shows it can be grabbed, or that a link
    /// under the mouse opens even while the program has the mouse.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), flags: event.modifierFlags)
        updateCursor(event.modifierFlags)
    }

    private var draggingPane = false
    /// A ⌘-click opened a link on press; its drag and release go nowhere.
    private var swallowingClick = false

    private func updateCursor(_ flags: NSEvent.ModifierFlags) {
        guard mode == .interactive, !draggingPane else { return }
        if hoveredLink != nil { return NSCursor.pointingHand.set() }
        let movable = (model?.activeLayout?.root.panes.count ?? 0) > 1
        (flags.contains(.command) && movable ? NSCursor.openHand : NSCursor.iBeam).set()
    }

    // MARK: Links

    /// The viewport cell under a point in view coordinates, if it's on the grid.
    private func cell(at point: NSPoint) -> (col: Int, row: Int)? {
        guard let replica else { return nil }
        let x = (point.x - Self.padding.width) * metrics.scale, y = (point.y - Self.padding.height) * metrics.scale
        guard x >= 0, y >= 0 else { return nil }
        let col = Int(x / metrics.cellWidth), row = Int(y / metrics.cellHeight)
        guard col < Int(replica.terminal.cols), row < Int(replica.terminal.rows) else { return nil }
        return (col, row)
    }

    private func link(at event: NSEvent) -> TerminalLink? {
        guard let replica, let cell = cell(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return replica.terminal.link(atCol: cell.col, row: cell.row)
    }

    private func updateHover(_ event: NSEvent, flags: NSEvent.ModifierFlags) {
        updateHover(at: convert(event.locationInWindow, from: nil), flags: flags)
    }

    /// Links light up where a click would open them: anywhere the program
    /// doesn't track the mouse, and with ⌘ where it does.
    private func updateHover(at point: NSPoint, flags: NSEvent.ModifierFlags) {
        guard mode == .interactive, let replica,
              !replica.terminal.isMouseTracking || flags.contains(.command),
              let cell = cell(at: point) else { return setLinkCell(nil) }
        setLinkCell(cell)
    }

    /// Output may have moved, replaced or printed a link under a still
    /// mouse, or turned mouse tracking on, so look again before drawing.
    private func refreshHover() {
        guard let window else { return }
        let before = hoveredLink
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), flags: NSEvent.modifierFlags)
        if hoveredLink != before { updateCursor(NSEvent.modifierFlags) }
    }

    private func setLinkCell(_ cell: (col: Int, row: Int)?) {
        let link = cell.flatMap { replica?.terminal.link(atCol: $0.col, row: $0.row) }
        linkCell = link == nil ? nil : cell
        guard link != hoveredLink else { return }
        hoveredLink = link
        needsDisplay = true
    }

    private func open(_ link: TerminalLink) {
        guard let url = link.url else {
            model?.showToast("Den doesn't open \(URL(string: link.target)?.scheme ?? "these") links")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The event's position in window coordinates with the origin top-left,
    /// matching SwiftUI's global space.
    private func windowPoint(_ event: NSEvent) -> CGPoint {
        let height = window?.contentView?.bounds.height ?? 0
        return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard mode == .interactive else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(NSEvent.modifierFlags)
    }

    /// Selection wins unless the program tracks the mouse; shift forces it.
    private func wantsSelection(_ event: NSEvent) -> Bool {
        guard let replica else { return false }
        return !replica.terminal.isMouseTracking || event.modifierFlags.contains(.shift)
    }

    private func gridPoint(_ event: NSEvent) -> (Float, Float) {
        let p = convert(event.locationInWindow, from: nil)
        return (Float((p.x - Self.padding.width) * metrics.scale), Float((p.y - Self.padding.height) * metrics.scale))
    }

    private func select(_ event: NSEvent, _ phase: SelectionGesture.Phase) {
        guard let replica, let selection else { return }
        selecting = phase != .release
        let (x, y) = gridPoint(event)
        let col = Int(Float(x) / Float(metrics.cellWidth))
        let row = Int(Float(y) / Float(metrics.cellHeight))
        let rows = Int(replica.terminal.rows), cols = Int(replica.terminal.cols)
        selection.handle(
            phase, col: min(max(col, 0), cols - 1), row: min(max(row, 0), rows - 1),
            x: Double(x), y: Double(y), timeNs: UInt64(event.timestamp * 1_000_000_000),
            columns: cols, cellWidth: Int(metrics.cellWidth), screenHeight: rows * Int(metrics.cellHeight),
            terminal: replica.terminal
        )
        replica.touch()
        if phase == .release { autoCopy() }
    }

    /// Copy-on-select: a finished selection goes straight to the clipboard.
    private func autoCopy() {
        guard let replica, let text = replica.terminal.selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // The copy is the confirmation; drop the highlight like a finished action.
        replica.terminal.clearSelection()
        selection?.reset(replica.terminal)
        replica.touch()
        model?.showToast("Copied to clipboard")
    }

    private func mouseReport(_ event: NSEvent, _ action: MouseAction, _ button: MouseButton?) {
        if action == .press { pressedButtons += 1 }
        if action == .release { pressedButtons = max(0, pressedButtons - 1) }
        guard mode == .interactive, let replica, let mouseEncoder, let model, replica.terminal.isMouseTracking else { return }
        let (x, y) = gridPoint(event)
        let bytes = mouseEncoder.encode(
            action: action, button: button, mods: keyInput(event, action: .press).mods, x: x, y: y,
            cellWidth: UInt32(metrics.cellWidth), cellHeight: UInt32(metrics.cellHeight),
            cols: replica.terminal.cols, rows: replica.terminal.rows,
            anyButtonPressed: pressedButtons > 0, terminal: replica.terminal
        )
        model.input(paneID, bytes)
    }

    override func scrollWheel(with event: NSEvent) {
        guard mode == .interactive, let replica, let model else { return super.scrollWheel(with: event) }
        var delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { delta /= metrics.cellHeight / metrics.scale }
        scrollRemainder += delta
        let lines = Int(scrollRemainder.rounded(.towardZero))
        guard lines != 0 else { return }
        scrollRemainder -= CGFloat(lines)

        let terminal = replica.terminal
        if terminal.isMouseTracking, let mouseEncoder {
            let (x, y) = gridPoint(event)
            var out = Data()
            for _ in 0 ..< abs(lines) {
                out.append(mouseEncoder.encode(
                    action: .press, button: lines > 0 ? .wheelUp : .wheelDown, mods: [], x: x, y: y,
                    cellWidth: UInt32(metrics.cellWidth), cellHeight: UInt32(metrics.cellHeight),
                    cols: terminal.cols, rows: terminal.rows, anyButtonPressed: false, terminal: terminal
                ))
            }
            model.input(paneID, out)
        } else if terminal.isAlternateScreen, terminal.alternateScroll, let keyEncoder {
            let key = KeyInput(macKeyCode: UInt16(lines > 0 ? kVK_UpArrow : kVK_DownArrow), action: .press, mods: [], consumedMods: [], text: nil, unshifted: 0)
            let one = keyEncoder.encode(key, terminal: terminal, optionAsAlt: true)
            model.input(paneID, (0 ..< abs(lines)).reduce(into: Data()) { acc, _ in acc.append(one) })
        } else {
            replica.scroll(.delta(-lines))
        }
    }
}
