import SwiftUI
import UniformTypeIdentifiers
import SceneKit

struct ContentView: View {
    @State private var droppedFileURL: URL?
    @State private var scene: SCNScene?
    @State private var parseResult: ParseResult?
    @State private var errorMessage: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            Text("Preview3MF")
                .font(.largeTitle.bold())

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Quick Look extension is installed")
                        .font(.headline)
                }

                Text("Select a .3mf file in Finder and press Space to preview.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                Button("Open System Extensions Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.extensions?Quick Look") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Divider()

            if let scene = scene {
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                    .frame(minHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundColor(.secondary.opacity(0.5))
                    VStack(spacing: 8) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Drop a .3mf file here to preview")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minHeight: 300)
            }

            if let result = parseResult {
                ModelInfoView(result: result)
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 500)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, url.pathExtension.lowercased() == "3mf" else { return }
                DispatchQueue.main.async {
                    loadFile(at: url)
                }
            }
            return true
        }
    }

    private func loadFile(at url: URL) {
        errorMessage = nil
        do {
            let result = try ThreeMFParser.parse(fileAt: url)
            let appearance: SceneBuilder.Appearance = colorScheme == .dark ? .dark : .light
            scene = SceneBuilder.buildScene(from: result.items, appearance: appearance)
            parseResult = result
        } catch {
            errorMessage = error.localizedDescription
            scene = nil
            parseResult = nil
        }
    }
}

struct ModelInfoView: View {
    let result: ParseResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Metadata
            if let title = result.metadata.title {
                LabeledContent("Title", value: title)
            }
            if let designer = result.metadata.designer {
                LabeledContent("Designer", value: designer)
            }
            if let description = result.metadata.description {
                LabeledContent("Description", value: description)
            }

            Divider()

            // Stats
            HStack(spacing: 24) {
                StatItem(label: "Objects", value: "\(result.objectCount)")
                StatItem(label: "Triangles", value: Self.formatNumber(result.totalTriangles))
                if let dims = result.dimensions {
                    StatItem(label: "Size (mm)",
                             value: "\(Self.formatDim(dims.x)) x \(Self.formatDim(dims.y)) x \(Self.formatDim(dims.z))")
                }
                if result.hasColors {
                    StatItem(label: "Colors", value: "Yes")
                }
            }
        }
        .font(.caption)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private static func formatDim(_ v: Float) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
}

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .fontWeight(.medium)
            Text(label)
                .foregroundColor(.secondary)
        }
    }
}
