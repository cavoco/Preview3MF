import Cocoa
import Quartz
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {

    private var sceneView: ZoomableSCNView!
    private var infoLabel: NSTextField!
    private var plateControl: NSStackView!
    private var plateLabel: NSTextField!
    private var viewportSpinner: NSView!
    private var plateSpinner: NSProgressIndicator!
    private var viewControl: NSStackView!
    private var spinButton: NSButton!
    private var layerControl: NSStackView!
    private var layerSlider: NSSlider!
    private var layerLabel: NSTextField!
    /// Keeps the info label clear of the layer slider, while there is one.
    private var infoClearOfLayers: NSLayoutConstraint!
    /// The G-code on show, and its drawn toolpath, for the layer slider.
    private var toolpath: GCodeToolpath?
    private var toolpathModel: ToolpathGeometry.Model?
    private var result: ParseResult?
    /// Survives paging, which swaps in a freshly built (spinning) scene.
    private var isSpinning = true
    /// The plate paging is heading for while its model files load; nil once it's shown.
    private var targetPlate: Int?
    private var isLoadingPlate = false
    /// Bumped per file, so a plate load that finishes after another file opened is dropped.
    private var fileGeneration = 0
    /// The way paging last went (+1 or -1): the likelier way to go next, so the plate
    /// that way is the one parsed ahead.
    private var pagingDirection = 1
    private let plateLoadQueue = DispatchQueue(label: "Preview3MF.plate-loading", qos: .userInitiated)

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        sceneView = ZoomableSCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.width, .height]
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = true
        sceneView.isPlaying = true   // keep painting during the settle
        view.addSubview(sceneView)

        infoLabel = NSTextField(labelWithString: "")
        infoLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.backgroundColor = NSColor(white: 0, alpha: 0.5)
        infoLabel.drawsBackground = true
        infoLabel.isBezeled = false
        infoLabel.isEditable = false
        // Wrap rather than run off the edge: the Quick Look panel opens narrow, and the
        // print-profile line would otherwise only show once the panel is widened.
        infoLabel.maximumNumberOfLines = 0
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        // Top-right, clear of the info label along the bottom edge.
        plateLabel = NSTextField(labelWithString: "")
        plateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        plateLabel.alignment = .center
        plateLabel.lineBreakMode = .byTruncatingTail
        plateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        plateControl = NSStackView(views: [
            overlayButton("chevron.left", String(localized: "Previous plate"), #selector(previousPlate)),
            plateLabel,
            overlayButton("chevron.right", String(localized: "Next plate"), #selector(nextPlate)),
        ])
        styleOverlay(plateControl)
        plateControl.isHidden = true
        view.addSubview(plateControl)

        plateSpinner = NSProgressIndicator()
        plateSpinner.style = .spinning
        plateSpinner.controlSize = .regular
        plateSpinner.isDisplayedWhenStopped = false
        plateSpinner.translatesAutoresizingMaskIntoConstraints = false

        viewportSpinner = NSView()
        viewportSpinner.wantsLayer = true
        viewportSpinner.layer?.cornerRadius = 18
        viewportSpinner.translatesAutoresizingMaskIntoConstraints = false
        viewportSpinner.isHidden = true
        viewportSpinner.addSubview(plateSpinner)
        view.addSubview(viewportSpinner)

        // Top-left, mirroring the plate control.
        spinButton = overlayButton("pause.fill", String(localized: "Pause rotation"), #selector(toggleSpin))
        viewControl = NSStackView(views: [spinButton])
        styleOverlay(viewControl)
        view.addSubview(viewControl)

        // Right edge, under the top corner, as in the slicers' previews: drag down to see
        // the print as it stood at an earlier layer.
        layerLabel = NSTextField(labelWithString: "")
        layerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        layerLabel.alignment = .center
        layerLabel.maximumNumberOfLines = 2

        layerSlider = FirstMouseSlider(value: 0, minValue: 0, maxValue: 1,
                                       target: self, action: #selector(layerSliderMoved))
        layerSlider.isVertical = true
        layerSlider.isContinuous = true
        layerSlider.controlSize = .small
        layerSlider.setAccessibilityLabel(String(localized: "Layer"))

        layerControl = NSStackView(views: [layerLabel, layerSlider])
        styleOverlay(layerControl)
        layerControl.orientation = .vertical
        layerControl.alignment = .centerX
        layerControl.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 10, right: 8)
        layerControl.layer?.cornerRadius = 12
        layerControl.isHidden = true
        view.addSubview(layerControl)

        infoClearOfLayers = infoLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: layerControl.leadingAnchor, constant: -8)

        NSLayoutConstraint.activate([
            layerControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            layerControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            layerControl.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            layerControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            infoLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            plateControl.leadingAnchor.constraint(greaterThanOrEqualTo: viewControl.trailingAnchor, constant: 8),
            plateControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            plateControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            plateControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            viewportSpinner.centerXAnchor.constraint(equalTo: sceneView.centerXAnchor),
            viewportSpinner.centerYAnchor.constraint(equalTo: sceneView.centerYAnchor),
            viewportSpinner.widthAnchor.constraint(equalToConstant: 36),
            viewportSpinner.heightAnchor.constraint(equalToConstant: 36),
            plateSpinner.centerXAnchor.constraint(equalTo: viewportSpinner.centerXAnchor),
            plateSpinner.centerYAnchor.constraint(equalTo: viewportSpinner.centerYAnchor),
            viewControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            viewControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            viewControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])

        sceneView.onHorizontalArrow = { [weak self] delta in self?.stepPlate(delta) }

        self.view = view
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // A wrapping label needs to know its width up front to report the right height.
        infoLabel.preferredMaxLayoutWidth = view.bounds.width - 24
        if let result {
            let text = plateLabelText(result, index: targetPlate ?? result.plateIndex)
            if plateLabel.stringValue != text {
                plateLabel.stringValue = text
            }
        }
    }

    private func styleOverlay(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func symbolImage(_ symbol: String, accessibilityDescription label: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config) ?? NSImage()
    }

    private func overlayButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = FirstMouseButton(
            image: symbolImage(symbol, accessibilityDescription: label),
            target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.setAccessibilityLabel(label)
        button.toolTip = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        return button
    }

    @objc private func toggleSpin() {
        isSpinning.toggle()
        if let scene = sceneView.scene {
            SceneBuilder.setSpinning(isSpinning, in: scene)
        }
        let label = isSpinning ? String(localized: "Pause rotation") : String(localized: "Resume rotation")
        spinButton.image = symbolImage(isSpinning ? "pause.fill" : "play.fill",
                                       accessibilityDescription: label)
        spinButton.setAccessibilityLabel(label)
        spinButton.toolTip = label
    }

    @objc private func layerSliderMoved() {
        showLayer(Int(layerSlider.doubleValue.rounded()))
    }

    private func showLayer(_ index: Int) {
        guard let toolpath, !toolpath.layers.isEmpty else { return }
        let index = min(max(index, 0), toolpath.layers.count - 1)
        toolpathModel?.show(throughLayer: index)
        layerLabel.stringValue = "\(index + 1)/\(toolpath.layers.count)\n"
            + String(format: "%.2f mm", toolpath.layers[index].z)
    }

    /// Shows or hides the layer slider: only a G-code file with more than one layer has one.
    private func setLayerControl(for toolpath: GCodeToolpath?, model: ToolpathGeometry.Model?) {
        self.toolpath = toolpath
        toolpathModel = model
        let layers = toolpath?.layers.count ?? 0
        let shown = model != nil && layers > 1
        layerControl.isHidden = !shown
        infoClearOfLayers.isActive = shown
        guard shown else { return }
        layerSlider.minValue = 0
        layerSlider.maxValue = Double(layers - 1)
        layerSlider.doubleValue = Double(layers - 1)
        showLayer(layers - 1)
    }

    @objc private func previousPlate() { stepPlate(-1) }
    @objc private func nextPlate() { stepPlate(1) }

    /// Page to the next plate that actually holds geometry, wrapping at the ends. Plates the
    /// slicer left empty stay in the numbering but are skipped over.
    private func stepPlate(_ delta: Int) {
        guard let result, let current = targetPlate ?? result.plateIndex,
              let next = Self.plate(after: current, step: delta, in: result) else { return }
        pagingDirection = delta
        targetPlate = next
        plateLabel.stringValue = plateLabelText(result, index: next)
        showTargetPlate(from: result)
    }

    /// The next plate with geometry from `index`, stepping by `step` and wrapping at the
    /// ends, or nil if there is nowhere else to go.
    private static func plate(after index: Int, step: Int, in result: ParseResult) -> Int? {
        guard result.plateCount > 1 else { return nil }
        var next = index
        for _ in 0..<result.plateCount {
            next = (next + step + result.plateCount) % result.plateCount
            if result.plates[next].hasGeometry { break }
        }
        return next == index ? nil : next
    }

    /// Start parsing the plate paging is likeliest to reach next, while this one is looked at.
    private func prefetchNextPlate() {
        guard let result, let package = result.package, let current = result.plateIndex,
              let next = Self.plate(after: current, step: pagingDirection, in: result),
              !result.plates[next].isLoaded else { return }
        package.prefetchPlate(next)
    }

    /// Show `targetPlate`, first parsing its model files off the main thread if they aren't
    /// loaded — a big plate takes seconds. Clicks that land mid-load only move the target;
    /// whichever plate it ends on is loaded next and shown.
    private func showTargetPlate(from base: ParseResult) {
        guard !isLoadingPlate, let target = targetPlate else { return }
        if base.plates[target].isLoaded, let updated = base.showingPlate(target) {
            targetPlate = nil
            result = updated
            render(updated, animated: false)
            prefetchNextPlate()
            return
        }

        isLoadingPlate = true
        setViewportLoading(true)
        let generation = fileGeneration
        plateLoadQueue.async { [weak self] in
            let loaded = try? base.loadingPlate(target)
            DispatchQueue.main.async {
                guard let self, generation == self.fileGeneration else { return }
                self.isLoadingPlate = false
                self.setViewportLoading(false)
                if let loaded {
                    self.showTargetPlate(from: loaded)
                } else if let result = self.result {
                    // Stay on the plate already on screen.
                    self.targetPlate = nil
                    self.plateLabel.stringValue = self.plateLabelText(result)
                }
            }
        }
    }

    private var currentAppearance: SceneBuilder.Appearance {
        let name = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return name == .darkAqua ? .dark : .light
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        fileGeneration += 1
        targetPlate = nil
        isLoadingPlate = false
        setViewportLoading(false)
        do {
            if GCodeParser.isGCode(url) {
                let path = try GCodeParser.parse(fileAt: url, segmentLimit: GCodeParser.previewSegmentLimit)
                guard path.segmentCount > 0 else { throw GCodeParser.ParseError.nothingPrinted }
                result = nil
                render(path)
                handler(nil)
                return
            }
            let result = try ThreeMFParser.parse(fileAt: url)
            self.result = result
            pagingDirection = 1
            render(result, animated: true)
            handler(nil)
            prefetchNextPlate()
        } catch {
            handler(error)
        }
    }

    private func setViewportLoading(_ loading: Bool) {
        viewportSpinner.isHidden = !loading
        if loading {
            plateSpinner.startAnimation(nil)
        } else {
            plateSpinner.stopAnimation(nil)
        }
    }

    /// Colours the overlays for the current appearance, and returns the text colour.
    private func styleOverlays(for appearance: SceneBuilder.Appearance) -> NSColor {
        let foreground = appearance == .dark
            ? NSColor(white: 0.8, alpha: 1.0)
            : NSColor(white: 0.2, alpha: 1.0)
        infoLabel.textColor = foreground
        plateLabel.textColor = foreground
        let overlayBackground = appearance == .dark
            ? NSColor(white: 0, alpha: 0.5)
            : NSColor(white: 1, alpha: 0.6)
        infoLabel.backgroundColor = overlayBackground
        plateControl.layer?.backgroundColor = overlayBackground.cgColor
        viewControl.layer?.backgroundColor = overlayBackground.cgColor
        viewportSpinner.layer?.backgroundColor = overlayBackground.cgColor
        layerControl.layer?.backgroundColor = overlayBackground.cgColor
        layerLabel.textColor = foreground
        spinButton.contentTintColor = foreground
        return foreground
    }

    /// A G-code file: one print, so no plates to page through.
    private func render(_ path: GCodeToolpath) {
        let appearance = currentAppearance
        let foreground = styleOverlays(for: appearance)
        plateControl.isHidden = true

        let (scene, model) = SceneBuilder.buildToolpathScene(from: path, appearance: appearance)
        infoLabel.attributedStringValue = NSAttributedString(
            string: buildInfoString(path, omissions: model?.plan.omissions ?? []),
            attributes: [
                .font: infoLabel.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: foreground,
            ])
        setLayerControl(for: path, model: model)
        SceneBuilder.setSpinning(isSpinning, in: scene)
        sceneView.scene = scene
        // Same first-frame settle as a 3MF's first render.
        scene.isPaused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sceneView.scene?.isPaused = false
        }
    }

    private func render(_ result: ParseResult, animated: Bool) {
        let appearance = currentAppearance
        // Text first. It costs nothing to set, and paging should feel immediate even
        // though rebuilding the geometry behind it does not.
        let foreground = styleOverlays(for: appearance)
        infoLabel.attributedStringValue = buildInfoText(result, foreground: foreground)

        setLayerControl(for: nil, model: nil)

        // Only worth showing when there is somewhere to page to.
        let populated = result.plates.filter { $0.hasGeometry }.count
        plateControl.isHidden = populated < 2
        plateLabel.stringValue = plateLabelText(result)

        let rebuild = { [weak self] in
            guard let self else { return }
            let scene = SceneBuilder.buildScene(from: result.items, appearance: appearance,
                                                bedSize: result.printSettings?.bedSize)
            SceneBuilder.setSpinning(self.isSpinning, in: scene)
            self.sceneView.scene = scene
            if animated {
                // Hold the spin still briefly so the first-frame geometry upload doesn't
                // surface as a jump in the rotation.
                scene.isPaused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.sceneView.scene?.isPaused = false
                }
            }
        }

        if animated {
            // First render of the file: stay synchronous so the preview is complete by the
            // time preparePreviewOfFile's completion handler reports success.
            rebuild()
        } else {
            // Paging: yield once so the new label paints before the rebuild blocks main.
            DispatchQueue.main.async(execute: rebuild)
        }
    }

    private func plateLabelText(_ result: ParseResult, index: Int? = nil) -> String {
        guard let index = index ?? result.plateIndex else { return "" }
        let width = view.bounds.width
        if width > 0 && width < 340 {
            return "\(index + 1)/\(result.plateCount)"
        }
        let counter = String(localized: "Plate \(index + 1)/\(result.plateCount)")
        if let name = result.plates[index].name, !name.isEmpty {
            return "\(counter) · \(name)"
        }
        return counter
    }

    /// The info text, plus a line of colour-swatched weights for a multi-filament plate.
    private func buildInfoText(_ result: ParseResult, foreground: NSColor) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: infoLabel.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: foreground,
        ]
        let text = NSMutableAttributedString(string: buildInfoString(result), attributes: attributes)
        let breakdown = result.sliceEstimate?.filamentBreakdown ?? []
        for (index, filament) in breakdown.enumerated() {
            text.append(NSAttributedString(string: index == 0 ? "\n" : "   ", attributes: attributes))
            let swatch = NSTextAttachment()
            swatch.image = swatchImage(filament.color, outline: foreground)
            swatch.bounds = NSRect(x: 0, y: -1, width: 9, height: 9)
            text.append(NSAttributedString(attachment: swatch))
            text.append(NSAttributedString(string: " " + filament.label, attributes: attributes))
        }
        return text
    }

    /// A filled dot in the filament's colour, outlined so white filament still shows against
    /// a light overlay. An unknown colour is drawn hollow.
    private func swatchImage(_ color: SIMD4<Float>?, outline: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let color {
                NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y),
                        blue: CGFloat(color.z), alpha: 1).setFill()
                dot.fill()
            }
            outline.withAlphaComponent(0.6).setStroke()
            dot.lineWidth = 1
            dot.stroke()
            return true
        }
    }

    private func buildInfoString(_ result: ParseResult) -> String {
        var parts: [String] = []

        if let title = result.metadata.title {
            parts.append(title)
        }
        if let designer = result.metadata.designer {
            parts.append(String(localized: "by \(designer)"))
        }

        var stats: [String] = []
        let triangleCount = formatNumber(result.totalTriangles)
        stats.append(String(localized: "\(triangleCount) triangles"))
        let objectCount = result.objectCount
        stats.append(objectCount == 1
            ? String(localized: "\(objectCount) object")
            : String(localized: "\(objectCount) objects"))
        if let dims = result.dimensions {
            stats.append("\(formatDim(dims.x)) x \(formatDim(dims.y)) x \(formatDim(dims.z)) mm")
        }

        var line = stats.joined(separator: "  ·  ")
        if !parts.isEmpty {
            line = parts.joined(separator: " ") + "  ·  " + line
        }
        // The print profile gets a line of its own; it is a different kind of fact. The
        // slicer's estimate leads it, since time and filament are what people look for.
        let printLine = (result.sliceEstimate?.summary ?? []) + (result.printSettings?.summary ?? [])
        if !printLine.isEmpty {
            line += "\n" + printLine.joined(separator: "  ·  ")
        }
        return line
    }

    /// "PrusaSlicer 2.4.2  ·  569 layers  ·  60 x 25 x 91 mm", then the print profile line.
    /// A print too big to draw whole says what it's drawn without: "simplified: no infill".
    private func buildInfoString(_ path: GCodeToolpath, omissions: [String]) -> String {
        var stats: [String] = []
        if let slicer = path.slicer { stats.append(slicer) }
        let layerCount = formatNumber(path.layers.count)
        stats.append(path.layers.count == 1
            ? String(localized: "\(layerCount) layer")
            : String(localized: "\(layerCount) layers"))
        if let (lower, upper) = path.bounds {
            let size = upper - lower
            stats.append("\(formatDim(size.x)) x \(formatDim(size.y)) x \(formatDim(upper.z)) mm")
        }
        if !omissions.isEmpty {
            let list = omissions.joined(separator: ", ")
            stats.append(String(localized: "simplified: \(list)"))
        }
        var line = stats.joined(separator: "  ·  ")
        let printLine = (path.estimate?.summary ?? []) + (path.printSettings?.summary ?? [])
        if !printLine.isEmpty {
            line += "\n" + printLine.joined(separator: "  ·  ")
        }
        return line
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func formatDim(_ v: Float) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
}

/// A button that responds to the click that also activates its window.
///
/// `acceptsFirstMouse` is false by default, which is right for a normal app — you do not
/// want a stray click on a background window pressing a button. It is wrong here: the Quick
/// Look panel is frequently not the key window, so the first click on the plate control was
/// being spent activating it instead. Pressing again then read as a double-click, which
/// Quick Look handles by opening the file.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The same for the layer slider, so the first drag in an inactive panel moves it.
/// Scrolling over it steps a layer at a time, for finer control than dragging over a
/// print of hundreds of layers.
final class FirstMouseSlider: NSSlider {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Scroll not yet amounting to a whole step.
    private var pendingSteps: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        // A mouse wheel moves in lines, a trackpad in points; a few points a layer keeps
        // a swipe from flying past the one wanted.
        pendingSteps += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 4 : event.scrollingDeltaY
        let steps = pendingSteps.rounded(.towardZero)
        guard steps != 0 else { return }
        pendingSteps -= steps
        let value = min(max(doubleValue + Double(steps), minValue), maxValue)
        guard value != doubleValue else { return }
        doubleValue = value
        sendAction(action, to: target)
    }
}

/// An `SCNView` that adds scroll-wheel zoom on top of SceneKit's built-in camera control.
/// The default controller handles orbit (drag) and trackpad pinch, but ignores the scroll
/// wheel — this dollies the camera toward/away from its target so mouse users can zoom too.
final class ZoomableSCNView: SCNView {

    /// The initial framing distance, captured on first scroll, used to bound zoom range.
    private var baselineDistance: CGFloat?

    /// Left/right arrow, as -1/+1.
    ///
    /// Confirmed dead inside Quick Look and kept anyway, because this class is compiled
    /// into the host app too, where the keys do work. The extension is a remote view
    /// service: its view is hosted in the Quick Look panel's process, so nothing here can
    /// become first responder of that window, and the panel claims the arrows for stepping
    /// through the Finder selection regardless. The on-screen control is what has to work
    /// in both places.
    var onHorizontalArrow: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Same reasoning as `FirstMouseButton`: without this the first drag in an inactive
    /// Quick Look panel is spent activating it rather than orbiting the model.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onHorizontalArrow?(-1)
        case 124: onHorizontalArrow?(1)
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let controller = defaultCameraController
        guard allowsCameraControl, let pov = controller.pointOfView else {
            super.scrollWheel(with: event)
            return
        }

        // Current distance from the camera to the point it orbits.
        let cam = pov.worldPosition
        let tgt = controller.target
        let dx = cam.x - tgt.x, dy = cam.y - tgt.y, dz = cam.z - tgt.z
        let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard distance > 0 else { super.scrollWheel(with: event); return }

        let baseline = baselineDistance ?? distance
        baselineDistance = baseline

        // Trackpad precise deltas are pixel-scale (large); mouse-wheel deltas are
        // line-scale (small). Normalise so both gestures feel similar.
        var delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { delta /= 10 }

        // Proportional zoom: move a fraction of the current distance, so the feel is
        // consistent regardless of model size. Wheel up (delta > 0) zooms in.
        let fraction = max(-0.4, min(0.4, -delta * 0.03))
        var newDistance = distance * (1 + fraction)
        newDistance = max(baseline * 0.05, min(baseline * 12, newDistance))

        // Camera space +Z points backward, so a positive step moves the camera away.
        let step = newDistance - distance
        controller.translateInCameraSpaceBy(x: 0, y: 0, z: Float(step))
    }
}
