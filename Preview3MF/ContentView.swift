import SwiftUI
import UniformTypeIdentifiers
import SceneKit

struct ContentView: View {
    @State private var droppedFileURL: URL?
    @State private var scene: SCNScene?
    @State private var errorMessage: String?

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
            let mesh = try ThreeMFParser.parse(fileAt: url)
            scene = SceneBuilder.buildScene(from: mesh)
        } catch {
            errorMessage = error.localizedDescription
            scene = nil
        }
    }
}
