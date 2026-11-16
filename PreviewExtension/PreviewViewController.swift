import Cocoa
import Quartz
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {

    private var sceneView: ZoomableSCNView!
    private var infoBar: NSStackView!
    private var infoLabel: NSTextField!
    private var plateControl: NSStackView!
    private var plateLabel: NSTextField!
    private var plateSpinner: NSProgressIndicator!
    private var spinnerContainer: NSView!
    private var spinnerWidthConstraint: NSLayoutConstraint!
    private var spinnerToken = 0
    private var spinnerShownAt: Date?
    private var spinnerHideWorkItem: DispatchWorkItem?
    private let minSpinnerDuration: TimeInterval = 2.0
    private var viewControl: NSStackView!
    private var spinButton: NSButton!
    private var infoButton: NSButton!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private static let showInfoDefaultsKey = "Preview3MF.showKeyInfo"
    private var showKeyInfo: Bool = (UserDefaults.standard.object(forKey: "Preview3MF.showKeyInfo") as? Bool) ?? true
    private var hasKeyInfoContent = false
    private var isCompactHUD = false
    private var lastLayoutWidth: CGFloat = 0
    private var result: ParseResult?
    /// Survives paging, which swaps in a freshly built (spinning) scene.
    private var isSpinning = false
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
        infoLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.drawsBackground = false
        infoLabel.isBezeled = false
        infoLabel.isEditable = false
        infoLabel.maximumNumberOfLines = 1
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        infoBar = NSStackView(views: [infoLabel])
        styleOverlay(infoBar)
        infoBar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        infoBar.layer?.cornerRadius = 14
        infoBar.alphaValue = showKeyInfo ? 1 : 0
        infoBar.isHidden = true
        view.addSubview(infoBar)

        // Top-right, clear of the info label along the bottom edge.
        plateLabel = NSTextField(labelWithString: "")
        plateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        plateLabel.alignment = .center
        plateLabel.lineBreakMode = .byTruncatingTail
        plateLabel.setContentHuggingPriority(.required, for: .horizontal)
        plateLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        plateSpinner = NSProgressIndicator()
        plateSpinner.style = .spinning
        plateSpinner.controlSize = .small
        plateSpinner.isDisplayedWhenStopped = false
        plateSpinner.translatesAutoresizingMaskIntoConstraints = false

        spinnerContainer = NSView()
        spinnerContainer.translatesAutoresizingMaskIntoConstraints = false
        spinnerContainer.wantsLayer = true
        spinnerContainer.layer?.masksToBounds = true
        spinnerContainer.alphaValue = 0
        spinnerContainer.addSubview(plateSpinner)
        spinnerWidthConstraint = spinnerContainer.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            spinnerWidthConstraint,
            spinnerContainer.heightAnchor.constraint(equalToConstant: 16),
            plateSpinner.leadingAnchor.constraint(equalTo: spinnerContainer.leadingAnchor),
            plateSpinner.centerYAnchor.constraint(equalTo: spinnerContainer.centerYAnchor),
            plateSpinner.widthAnchor.constraint(equalToConstant: 14),
            plateSpinner.heightAnchor.constraint(equalToConstant: 14),
        ])

        prevButton = overlayButton("chevron.left", String(localized: "Previous plate"), #selector(previousPlate))
        nextButton = overlayButton("chevron.right", String(localized: "Next plate"), #selector(nextPlate))
        plateControl = NSStackView(views: [
            prevButton,
            plateLabel,
            spinnerContainer,
            nextButton,
        ])
        styleOverlay(plateControl)
        plateControl.setCustomSpacing(8, after: prevButton)
        plateControl.setCustomSpacing(8, after: plateLabel)
        plateControl.setCustomSpacing(0, after: spinnerContainer)
        plateControl.isHidden = true
        view.addSubview(plateControl)

        // Top-left, mirroring the plate control.
        spinButton = overlayButton("play.fill", String(localized: "Resume rotation"), #selector(toggleSpin))
        infoButton = overlayButton(showKeyInfo ? "info.circle.fill" : "info.circle",
                                   showKeyInfo ? String(localized: "Hide key info") : String(localized: "Show key info"),
                                   #selector(toggleInfo))
        viewControl = NSStackView(views: [spinButton, infoButton])
        styleOverlay(viewControl)
        view.addSubview(viewControl)

        NSLayoutConstraint.activate([
            infoBar.heightAnchor.constraint(equalToConstant: 28),
            infoBar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            infoBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            infoBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            infoBar.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            plateControl.heightAnchor.constraint(equalToConstant: 32),
            plateControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            plateControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            plateControl.leadingAnchor.constraint(greaterThanOrEqualTo: viewControl.trailingAnchor, constant: 8),
            viewControl.heightAnchor.constraint(equalToConstant: 32),
            viewControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            viewControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            viewControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])

        sceneView.onHorizontalArrow = { [weak self] delta in self?.stepPlate(delta) }

        self.view = view
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        guard abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        applyResponsiveHUDLayout(forWidth: width)
    }

    private func applyResponsiveHUDLayout(forWidth width: CGFloat) {
        let compact = width > 0 && width < 340
        isCompactHUD = compact
        if compact {
            viewControl.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
            viewControl.spacing = 6
            plateControl.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
            plateControl.setCustomSpacing(5, after: prevButton)
            plateControl.setCustomSpacing(5, after: plateLabel)
            infoBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        } else {
            viewControl.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            viewControl.spacing = 8
            plateControl.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            plateControl.setCustomSpacing(8, after: prevButton)
            plateControl.setCustomSpacing(8, after: plateLabel)
            infoBar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        }
        if let result {
            plateLabel.stringValue = plateLabelText(result, index: targetPlate ?? result.plateIndex)
            refreshKeyInfoBarText(result, width: width)
        }
    }

    private func styleOverlay(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func symbolImage(_ symbol: String, label: String) -> NSImage {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        return base?.withSymbolConfiguration(config) ?? base ?? NSImage()
    }

    private func overlayButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = FirstMouseButton(image: symbolImage(symbol, label: label), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }

    @objc private func toggleSpin() {
        isSpinning.toggle()
        if let scene = sceneView.scene {
            SceneBuilder.setSpinning(isSpinning, in: scene)
        }
        let label = isSpinning ? String(localized: "Pause rotation") : String(localized: "Resume rotation")
        spinButton.image = symbolImage(isSpinning ? "pause.fill" : "play.fill", label: label)
        spinButton.setAccessibilityLabel(label)
        spinButton.toolTip = label
    }

    @objc private func toggleInfo() {
        showKeyInfo.toggle()
        UserDefaults.standard.set(showKeyInfo, forKey: Self.showInfoDefaultsKey)
        let label = showKeyInfo ? String(localized: "Hide key info") : String(localized: "Show key info")
        infoButton.image = symbolImage(showKeyInfo ? "info.circle.fill" : "info.circle", label: label)
        infoButton.setAccessibilityLabel(label)
        infoButton.toolTip = label
        updateInfoBarVisibility(animated: true)
    }

    private func updateInfoBarVisibility(animated: Bool) {
        let shouldShow = showKeyInfo && hasKeyInfoContent
        guard animated else {
            infoBar.alphaValue = shouldShow ? 1 : 0
            infoBar.isHidden = !shouldShow
            return
        }
        if shouldShow {
            infoBar.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.infoBar.animator().alphaValue = shouldShow ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !(self.showKeyInfo && self.hasKeyInfoContent) {
                self.infoBar.isHidden = true
            }
        })
    }

    @objc private func previousPlate() { stepPlate(-1) }
    @objc private func nextPlate() { stepPlate(1) }

    private func beginSpinnerWithMinDuration() {
        spinnerToken += 1
        spinnerHideWorkItem?.cancel()
        spinnerHideWorkItem = nil
        spinnerShownAt = Date()
        plateSpinner.startAnimation(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            self.spinnerWidthConstraint.constant = self.isCompactHUD ? 19 : 22
            self.spinnerContainer.alphaValue = 1
            self.view.layoutSubtreeIfNeeded()
        }
    }

    private func scheduleSpinnerHideIfReady() {
        guard !isLoadingPlate else { return }
        spinnerHideWorkItem?.cancel()
        let token = spinnerToken
        let elapsed = spinnerShownAt.map { Date().timeIntervalSince($0) } ?? minSpinnerDuration
        let remaining = max(0, minSpinnerDuration - elapsed)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.spinnerToken == token, !self.isLoadingPlate else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                self.spinnerWidthConstraint.constant = 0
                self.spinnerContainer.alphaValue = 0
                self.view.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self] in
                guard let self, self.spinnerToken == token, !self.isLoadingPlate else { return }
                self.plateSpinner.stopAnimation(nil)
            })
        }
        spinnerHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func resetSpinnerImmediately() {
        spinnerToken += 1
        spinnerHideWorkItem?.cancel()
        spinnerHideWorkItem = nil
        spinnerShownAt = nil
        spinnerWidthConstraint.constant = 0
        spinnerContainer.alphaValue = 0
        plateSpinner.stopAnimation(nil)
    }

    /// Page to the next plate that actually holds geometry, wrapping at the ends. Plates the
    /// slicer left empty stay in the numbering but are skipped over.
    private func stepPlate(_ delta: Int) {
        guard let result, let current = targetPlate ?? result.plateIndex,
              let next = Self.plate(after: current, step: delta, in: result) else { return }
        pagingDirection = delta
        targetPlate = next
        plateLabel.stringValue = plateLabelText(result, index: next)
        beginSpinnerWithMinDuration()
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
            scheduleSpinnerHideIfReady()
            return
        }

        isLoadingPlate = true
        let generation = fileGeneration
        plateLoadQueue.async { [weak self] in
            let loaded = try? base.loadingPlate(target)
            DispatchQueue.main.async {
                guard let self, generation == self.fileGeneration else { return }
                self.isLoadingPlate = false
                if let loaded {
                    self.showTargetPlate(from: loaded)
                } else if let result = self.result {
                    // Stay on the plate already on screen.
                    self.targetPlate = nil
                    self.plateLabel.stringValue = self.plateLabelText(result)
                    self.scheduleSpinnerHideIfReady()
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
        resetSpinnerImmediately()
        do {
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

    private func render(_ result: ParseResult, animated: Bool) {
        let appearance = currentAppearance
        let foreground = appearance == .dark
            ? NSColor(white: 0.8, alpha: 1.0)
            : NSColor(white: 0.2, alpha: 1.0)

        // Text first. It costs nothing to set, and paging should feel immediate even
        // though rebuilding the geometry behind it does not.
        plateLabel.textColor = foreground
        let overlayBackground = appearance == .dark
            ? NSColor(white: 0, alpha: 0.55)
            : NSColor(white: 1, alpha: 0.72)
        infoBar.layer?.backgroundColor = overlayBackground.cgColor
        plateControl.layer?.backgroundColor = overlayBackground.cgColor
        viewControl.layer?.backgroundColor = overlayBackground.cgColor
        spinButton.contentTintColor = foreground
        infoButton.contentTintColor = foreground

        // Only worth showing when there is somewhere to page to.
        let populated = result.plates.filter { $0.hasGeometry }.count
        plateControl.isHidden = populated < 2
        applyResponsiveHUDLayout(forWidth: view.bounds.width)

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
        if isCompactHUD {
            return "\(index + 1)/\(result.plateCount)"
        }
        let counter = String(localized: "Plate \(index + 1)/\(result.plateCount)")
        if let name = result.plates[index].name, !name.isEmpty {
            return "\(counter) · \(name)"
        }
        return counter
    }

    private func refreshKeyInfoBarText(_ result: ParseResult, width: CGFloat) {
        let appearance = currentAppearance
        let foreground = appearance == .dark
            ? NSColor(white: 0.8, alpha: 1.0)
            : NSColor(white: 0.2, alpha: 1.0)
        infoLabel.textColor = foreground
        let horizontalReserve: CGFloat = isCompactHUD ? 56 : 64
        let maxTextWidth = width > 0 ? max(80, width - horizontalReserve) : 520
        let keyText = buildKeyInfoText(result, foreground: foreground, maxWidth: maxTextWidth)
        hasKeyInfoContent = keyText.length > 0
        infoLabel.attributedStringValue = keyText
        updateInfoBarVisibility(animated: false)
    }

    /// Compact single-line key metrics bar fitted strictly to available width (never trailing an orphan separator).
    private func buildKeyInfoText(_ result: ParseResult, foreground: NSColor, maxWidth: CGFloat) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: infoLabel.font ?? NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: foreground,
        ]
        var segments: [NSAttributedString] = []

        if let est = result.sliceEstimate?.localizedSummary, !est.isEmpty {
            segments.append(NSAttributedString(string: est.joined(separator: " · "), attributes: attributes))
        }

        let breakdown = result.sliceEstimate?.filamentBreakdown ?? []
        if !breakdown.isEmpty {
            let swatchStr = NSMutableAttributedString()
            for (index, filament) in breakdown.prefix(3).enumerated() {
                if index > 0 {
                    swatchStr.append(NSAttributedString(string: " ", attributes: attributes))
                }
                let swatch = NSTextAttachment()
                swatch.image = swatchImage(filament.color, outline: foreground)
                swatch.bounds = NSRect(x: 0, y: -1, width: 8, height: 8)
                swatchStr.append(NSAttributedString(attachment: swatch))
                swatchStr.append(NSAttributedString(string: " " + filament.label, attributes: attributes))
            }
            if breakdown.count > 3 {
                swatchStr.append(NSAttributedString(string: " " + String(localized: "+\(breakdown.count - 3) more"), attributes: attributes))
            }
            segments.append(swatchStr)
        } else if let types = result.printSettings?.filamentTypes, !types.isEmpty {
            var seen = Set<String>()
            let unique = types.filter { seen.insert($0).inserted }
            segments.append(NSAttributedString(string: unique.prefix(3).joined(separator: "/"), attributes: attributes))
        }

        if let lh = result.printSettings?.layerHeight, !lh.isEmpty {
            segments.append(NSAttributedString(string: String(localized: "\(lh)mm layer"), attributes: attributes))
        }
        if let infill = result.printSettings?.infillDensity, !infill.isEmpty {
            segments.append(NSAttributedString(string: String(localized: "\(infill) infill"), attributes: attributes))
        }
        if result.printSettings?.supportsEnabled == true {
            segments.append(NSAttributedString(string: String(localized: "Supports"), attributes: attributes))
        }
        if let dims = result.dimensions {
            segments.append(NSAttributedString(
                string: "\(formatDim(dims.x))×\(formatDim(dims.y))×\(formatDim(dims.z)) mm",
                attributes: attributes
            ))
        }

        guard let first = segments.first else { return NSAttributedString() }
        let out = NSMutableAttributedString(attributedString: first)
        let sep = NSAttributedString(string: "  ·  ", attributes: attributes)
        for seg in segments.dropFirst() {
            let candidate = NSMutableAttributedString(attributedString: out)
            candidate.append(sep)
            candidate.append(seg)
            if ceil(candidate.size().width) <= maxWidth {
                out.append(sep)
                out.append(seg)
            } else {
                break
            }
        }
        return out
    }

    /// A filled dot in the filament's colour, outlined so white filament still shows against
    /// a light overlay. An unknown colour is drawn hollow.
    private func swatchImage(_ color: SIMD4<Float>?, outline: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
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
