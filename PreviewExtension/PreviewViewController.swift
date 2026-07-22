import Cocoa
import Quartz
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {

    private var sceneView: SCNView!
    private var infoLabel: NSTextField!

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

        NSLayoutConstraint.activate([
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            infoLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])

        self.view = view
    }

    private var currentAppearance: SceneBuilder.Appearance {
        let name = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return name == .darkAqua ? .dark : .light
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let result = try ThreeMFParser.parse(fileAt: url)
            let appearance = currentAppearance
            let scene = SceneBuilder.buildScene(from: result.items, appearance: appearance)
            sceneView.scene = scene
            // Hold the spin still briefly so the first-frame geometry upload doesn't
            // surface as a jump in the rotation.
            scene.isPaused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.sceneView.scene?.isPaused = false
            }
            infoLabel.stringValue = buildInfoString(result)
            infoLabel.textColor = appearance == .dark
                ? NSColor(white: 0.8, alpha: 1.0)
                : NSColor(white: 0.3, alpha: 1.0)
            handler(nil)
        } catch {
            handler(error)
        }
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

/// An `SCNView` that adds scroll-wheel zoom on top of SceneKit's built-in camera control.
/// The default controller handles orbit (drag) and trackpad pinch, but ignores the scroll
/// wheel — this dollies the camera toward/away from its target so mouse users can zoom too.
final class ZoomableSCNView: SCNView {

    /// The initial framing distance, captured on first scroll, used to bound zoom range.
    private var baselineDistance: CGFloat?

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
