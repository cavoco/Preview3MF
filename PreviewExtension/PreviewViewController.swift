import Cocoa
import Quartz
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {

    private var sceneView: SCNView!
    private var infoLabel: NSTextField!

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        sceneView = SCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.width, .height]
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = true
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
