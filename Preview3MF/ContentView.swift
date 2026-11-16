import SwiftUI
import UniformTypeIdentifiers
import SceneKit
import AppKit

struct ContentView: View {
    @State private var droppedFileURL: URL?
    @State private var scene: SCNScene?
    @State private var parseResult: ParseResult?
    @State private var errorMessage: String?
    @State private var isSpinning = false
    @AppStorage("Preview3MF.showKeyInfo") private var showKeyInfo = true
    /// The plate paging is heading for while its model files load; nil once it's shown.
    @State private var targetPlate: Int?
    @State private var isLoadingPlate = false
    @State private var showPlateSpinner = false
    @State private var spinnerToken = 0
    @State private var spinnerShownAt: Date?
    @State private var spinnerHideWorkItem: DispatchWorkItem?
    private let minSpinnerDuration: TimeInterval = 2.0
    /// Bumped per file, so a plate load that finishes after another file opened is dropped.
    @State private var fileGeneration = 0
    /// The way paging last went (+1 or -1), so the plate that way is the one parsed ahead.
    @State private var pagingDirection = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            Text("Preview3MF")
                .font(.largeTitle.bold())

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("Enable both extensions to use Preview3MF")
                        .font(.headline)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("**PreviewExtension** — Space-bar 3D preview")
                    } icon: {
                        Image(systemName: "eye")
                            .foregroundColor(.secondary)
                    }
                    Label {
                        Text("**ThumbnailExtension** — Finder icon previews")
                    } icon: {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    }
                }
                .font(.callout)

                Button("Open Quick Look Extensions in System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.extensions?Quick Look") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Text("Then press Space on any .3mf file in Finder.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            if let scene = scene {
                ZoomableSceneView(scene: scene, isSpinning: isSpinning, onHorizontalArrow: stepPlate)
                    .frame(minHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        ViewControls(isSpinning: $isSpinning, showKeyInfo: $showKeyInfo)
                            .padding(12)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let result = parseResult, populatedPlateCount(result) > 1 {
                            PlateSwitcher(result: result, index: targetPlate ?? result.plateIndex,
                                          isLoading: showPlateSpinner, step: stepPlate)
                                .padding(12)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if showKeyInfo, let result = parseResult {
                            KeyInfoBarView(result: result)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: showKeyInfo)
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

            HStack(spacing: 16) {
                Link("Star on GitHub", destination: ProjectLinks.repository)
                Link("Report a problem", destination: ProjectLinks.reportProblem)
            }
            .font(.caption)
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

    private func populatedPlateCount(_ result: ParseResult) -> Int {
        result.plates.filter { $0.hasGeometry }.count
    }

    private func beginSpinnerWithMinDuration() {
        spinnerToken += 1
        spinnerHideWorkItem?.cancel()
        spinnerHideWorkItem = nil
        spinnerShownAt = Date()
        withAnimation(.easeInOut(duration: 0.25)) {
            showPlateSpinner = true
        }
    }

    private func scheduleSpinnerHideIfReady() {
        guard !isLoadingPlate else { return }
        spinnerHideWorkItem?.cancel()
        let token = spinnerToken
        let elapsed = spinnerShownAt.map { Date().timeIntervalSince($0) } ?? minSpinnerDuration
        let remaining = max(0, minSpinnerDuration - elapsed)
        let work = DispatchWorkItem {
            guard spinnerToken == token, !isLoadingPlate else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                showPlateSpinner = false
            }
        }
        spinnerHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    /// Page to the next plate holding geometry, wrapping at the ends.
    private func stepPlate(_ delta: Int) {
        guard let current = parseResult, let index = targetPlate ?? current.plateIndex,
              let next = Self.plate(after: index, step: delta, in: current) else { return }
        pagingDirection = delta
        targetPlate = next
        beginSpinnerWithMinDuration()
        showTargetPlate(from: current)
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
    private func prefetchNextPlate(_ result: ParseResult) {
        guard let package = result.package, let current = result.plateIndex,
              let next = Self.plate(after: current, step: pagingDirection, in: result),
              !result.plates[next].isLoaded else { return }
        package.prefetchPlate(next)
    }

    /// Show `targetPlate`, first parsing its model files off the main thread if they aren't
    /// loaded. Steps taken mid-load only move the target; it is loaded once this one ends.
    private func showTargetPlate(from base: ParseResult) {
        guard !isLoadingPlate, let target = targetPlate else { return }
        if base.plates[target].isLoaded, let updated = base.showingPlate(target) {
            targetPlate = nil
            parseResult = updated
            let appearance: SceneBuilder.Appearance = colorScheme == .dark ? .dark : .light
            scene = SceneBuilder.buildScene(from: updated.items, appearance: appearance,
                                            bedSize: updated.printSettings?.bedSize)
            prefetchNextPlate(updated)
            scheduleSpinnerHideIfReady()
            return
        }

        isLoadingPlate = true
        let generation = fileGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? base.loadingPlate(target)
            DispatchQueue.main.async {
                guard generation == fileGeneration else { return }
                isLoadingPlate = false
                if let loaded {
                    showTargetPlate(from: loaded)
                } else {
                    targetPlate = nil
                    scheduleSpinnerHideIfReady()
                }
            }
        }
    }

    private func loadFile(at url: URL) {
        errorMessage = nil
        fileGeneration += 1
        targetPlate = nil
        isLoadingPlate = false
        spinnerToken += 1
        spinnerHideWorkItem?.cancel()
        spinnerHideWorkItem = nil
        showPlateSpinner = false
        do {
            let result = try ThreeMFParser.parse(fileAt: url)
            let appearance: SceneBuilder.Appearance = colorScheme == .dark ? .dark : .light
            let newScene = SceneBuilder.buildScene(from: result.items, appearance: appearance,
                                                   bedSize: result.printSettings?.bedSize)
            // Hold the spin still briefly so the first-frame upload doesn't jump (as in the preview).
            newScene.isPaused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { newScene.isPaused = false }
            scene = newScene
            parseResult = result
            pagingDirection = 1
            prefetchNextPlate(result)
        } catch {
            errorMessage = error.localizedDescription
            scene = nil
            parseResult = nil
        }
    }
}

/// A filament's colour as a small dot. The outline keeps white filament visible on a light
/// background; an unknown colour is drawn hollow.
struct FilamentSwatch: View {
    let color: SIMD4<Float>?

    var body: some View {
        Circle()
            .fill(color.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) } ?? .clear)
            .overlay(Circle().strokeBorder(.secondary, lineWidth: 0.5))
            .frame(width: 8, height: 8)
    }
}

/// Compact single-line bottom capsule in the host preview window.
struct KeyInfoBarView: View {
    let result: ParseResult

    var body: some View {
        let est = result.sliceEstimate?.localizedSummary ?? []
        let breakdown = result.sliceEstimate?.filamentBreakdown ?? []
        let segments = trailingSegments
        let hasMaterials = !breakdown.isEmpty || !(result.printSettings?.filamentTypes ?? []).isEmpty

        if !est.isEmpty || hasMaterials || !segments.isEmpty {
            HStack(spacing: 6) {
                if !est.isEmpty {
                    Text(est.joined(separator: " · "))
                }
                if !breakdown.isEmpty {
                    if !est.isEmpty { Text("·") }
                    HStack(spacing: 6) {
                        ForEach(Array(breakdown.prefix(3).enumerated()), id: \.offset) { _, f in
                            HStack(spacing: 4) {
                                FilamentSwatch(color: f.color)
                                Text(f.label)
                            }
                        }
                        if breakdown.count > 3 {
                            Text(String(localized: "+\(breakdown.count - 3) more"))
                        }
                    }
                } else if let types = result.printSettings?.filamentTypes, !types.isEmpty {
                    let unique = types.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    Text((!est.isEmpty ? "· " : "") + unique.prefix(3).joined(separator: "/"))
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Text("· " + seg)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private var trailingSegments: [String] {
        var segs: [String] = []
        if let lh = result.printSettings?.layerHeight, !lh.isEmpty {
            segs.append(String(localized: "\(lh)mm layer"))
        }
        if let infill = result.printSettings?.infillDensity, !infill.isEmpty {
            segs.append(String(localized: "\(infill) infill"))
        }
        if result.printSettings?.supportsEnabled == true {
            segs.append(String(localized: "Supports"))
        }
        if let dims = result.dimensions {
            segs.append("\(Self.formatDim(dims.x))×\(Self.formatDim(dims.y))×\(Self.formatDim(dims.z)) mm")
        }
        return segs
    }

    private static func formatDim(_ v: Float) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
}

/// Pause/resume rotation + key-info toggle, top-left of the scene.
struct ViewControls: View {
    @Binding var isSpinning: Bool
    @Binding var showKeyInfo: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { isSpinning.toggle() } label: {
                Image(systemName: isSpinning ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .help(isSpinning ? "Pause rotation" : "Resume rotation")
            .accessibilityLabel(isSpinning ? "Pause rotation" : "Resume rotation")

            Button { showKeyInfo.toggle() } label: {
                Image(systemName: showKeyInfo ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .help(showKeyInfo ? "Hide key info" : "Show key info")
            .accessibilityLabel(showKeyInfo ? "Hide key info" : "Show key info")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(minWidth: 40, minHeight: 32)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Pages between the build plates of a multi-plate slicer project.
struct PlateSwitcher: View {
    let result: ParseResult
    /// The plate to name — the one being paged to, while it loads.
    let index: Int?
    let isLoading: Bool
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .accessibilityLabel("Previous plate")
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            Button { step(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .accessibilityLabel("Next plate")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(.regularMaterial, in: Capsule())
        .animation(.easeInOut(duration: 0.25), value: isLoading)
    }

    private var label: String {
        guard let index else { return "" }
        let counter = String(localized: "Plate \(index + 1)/\(result.plateCount)")
        if let name = result.plates[index].name, !name.isEmpty {
            return "\(counter) · \(name)"
        }
        return counter
    }
}

/// Hosts a SceneKit scene with orbit + pinch (built-in) plus scroll-wheel zoom.
/// SwiftUI's `SceneView` doesn't expose the underlying `SCNView`, so we wrap our own
/// `ZoomableSCNView` to intercept the scroll wheel.
struct ZoomableSceneView: NSViewRepresentable {
    let scene: SCNScene
    var isSpinning = true
    var onHorizontalArrow: ((Int) -> Void)?

    func makeNSView(context: Context) -> ZoomableSCNView {
        let view = ZoomableSCNView()
        view.onHorizontalArrow = onHorizontalArrow
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.isPlaying = true   // keep rendering so the model keeps auto-rotating
        view.scene = scene
        SceneBuilder.setSpinning(isSpinning, in: scene)
        return view
    }

    func updateNSView(_ nsView: ZoomableSCNView, context: Context) {
        nsView.onHorizontalArrow = onHorizontalArrow
        if nsView.scene !== scene {
            nsView.scene = scene
        }
        SceneBuilder.setSpinning(isSpinning, in: scene)
    }
}

/// An `SCNView` that adds scroll-wheel zoom on top of SceneKit's built-in camera control.
/// The default controller handles orbit (drag) and trackpad pinch, but ignores the scroll
/// wheel — this dollies the camera toward/away from its target so mouse users can zoom too.
final class ZoomableSCNView: SCNView {

    /// The initial framing distance, captured on first scroll, used to bound zoom range.
    private var baselineDistance: CGFloat?

    /// Left/right arrow, as -1/+1, for paging between build plates.
    var onHorizontalArrow: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

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
