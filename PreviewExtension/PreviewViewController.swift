import Cocoa
import Quartz
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {

    private var sceneView: ZoomableSCNView!
    private var infoLabel: NSTextField!
    private var plateControl: NSStackView!
    private var plateLabel: NSTextField!
    private var result: ParseResult?

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
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        // Top-right, clear of the info label along the bottom edge.
        plateLabel = NSTextField(labelWithString: "")
        plateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        plateLabel.alignment = .center

        plateControl = NSStackView(views: [
            plateButton("chevron.left", "Previous plate", #selector(previousPlate)),
            plateLabel,
            plateButton("chevron.right", "Next plate", #selector(nextPlate)),
        ])
        plateControl.orientation = .horizontal
        plateControl.spacing = 6
        plateControl.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        plateControl.wantsLayer = true
        plateControl.layer?.cornerRadius = 6
        plateControl.isHidden = true
        plateControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(plateControl)

        NSLayoutConstraint.activate([
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            infoLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            plateControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            plateControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])

        sceneView.onHorizontalArrow = { [weak self] delta in self?.stepPlate(delta) }

        self.view = view
    }

    private func plateButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let button = FirstMouseButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func previousPlate() { stepPlate(-1) }
    @objc private func nextPlate() { stepPlate(1) }

    /// Page to the next plate that actually holds geometry, wrapping at the ends. Plates the
    /// slicer left empty stay in the numbering but are skipped over.
    private func stepPlate(_ delta: Int) {
        guard let result, result.plateCount > 1, let current = result.plateIndex else { return }
        var next = current
        for _ in 0..<result.plateCount {
            next = (next + delta + result.plateCount) % result.plateCount
            if !result.plates[next].items.isEmpty { break }
        }
        guard next != current, let updated = result.showingPlate(next) else { return }
        self.result = updated
        render(updated, animated: false)
    }

    private var currentAppearance: SceneBuilder.Appearance {
        let name = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return name == .darkAqua ? .dark : .light
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let result = try ThreeMFParser.parse(fileAt: url)
            self.result = result
            render(result, animated: true)
            handler(nil)
        } catch {
            handler(error)
        }
    }

    private func render(_ result: ParseResult, animated: Bool) {
        let appearance = currentAppearance
        let foreground = appearance == .dark
            ? NSColor(white: 0.8, alpha: 1.0)
            : NSColor(white: 0.3, alpha: 1.0)

        // Text first. It costs nothing to set, and paging should feel immediate even
        // though rebuilding the geometry behind it does not.
        infoLabel.stringValue = buildInfoString(result)
        infoLabel.textColor = foreground
        plateLabel.textColor = foreground
        plateControl.layer?.backgroundColor = NSColor(white: appearance == .dark ? 0 : 1,
                                                      alpha: 0.5).cgColor

        // Only worth showing when there is somewhere to page to.
        let populated = result.plates.filter { !$0.items.isEmpty }.count
        plateControl.isHidden = populated < 2
        plateLabel.stringValue = plateLabelText(result)

        let rebuild = { [weak self] in
            guard let self else { return }
            let scene = SceneBuilder.buildScene(from: result.items, appearance: appearance)
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

    private func plateLabelText(_ result: ParseResult) -> String {
        guard let index = result.plateIndex else { return "" }
        let counter = "Plate \(index + 1)/\(result.plateCount)"
        if let name = result.plates[index].name, !name.isEmpty {
            return "\(counter) · \(name)"
        }
        return counter
    }

    private func buildInfoString(_ result: ParseResult) -> String {
        var parts: [String] = []

        if let title = result.metadata.title {
            parts.append(title)
        }
        if let designer = result.metadata.designer {
            parts.append("by \(designer)")
        }

        var stats: [String] = []
        stats.append("\(formatNumber(result.totalTriangles)) triangles")
        stats.append("\(result.objectCount) object\(result.objectCount == 1 ? "" : "s")")
        if let dims = result.dimensions {
            stats.append("\(formatDim(dims.x)) x \(formatDim(dims.y)) x \(formatDim(dims.z)) mm")
        }

        if parts.isEmpty {
            return stats.joined(separator: "  ·  ")
        }
        return parts.joined(separator: " ") + "  ·  " + stats.joined(separator: "  ·  ")
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
