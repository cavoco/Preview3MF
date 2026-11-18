import SceneKit
import simd

extension SceneBuilder {

    /// A sliced print as the slicer's preview shows it: every extrusion drawn as a bead of
    /// plastic, on the same turntable and bed as a 3MF model.
    static func buildScene(
        from toolpath: GCodeToolpath,
        appearance: Appearance = .light,
        showBuildPlate: Bool = true,
        tubeBudget: Int = ToolpathGeometry.tubeBudget
    ) -> SCNScene {
        buildToolpathScene(from: toolpath, appearance: appearance, showBuildPlate: showBuildPlate,
                           tubeBudget: tubeBudget).scene
    }

    /// The scene, and the drawn toolpath for showing it a layer at a time.
    static func buildToolpathScene(
        from toolpath: GCodeToolpath,
        appearance: Appearance = .light,
        showBuildPlate: Bool = true,
        tubeBudget: Int = ToolpathGeometry.tubeBudget
    ) -> (scene: SCNScene, model: ToolpathGeometry.Model?) {
        let containerNode = SCNNode()
        let model = ToolpathGeometry.build(toolpath, budget: tubeBudget)
        if let model {
            let node = SCNNode(geometry: model.geometry)
            node.simdTransform = zUpToYUp
            containerNode.addChildNode(node)
        }
        let scene = stage(containerNode, appearance: appearance, showBuildPlate: showBuildPlate,
                          bedSize: toolpath.printSettings?.bedSize)
        return (scene, model)
    }
}

/// Turns a toolpath into one piece of geometry: each extrusion a short tube with a diamond
/// cross-section, as wide as the line the nozzle lays and as tall as the layer, smooth-shaded
/// so it reads as a rounded bead.
///
/// One geometry rather than one per layer or feature: SceneKit's cost is per draw call far
/// more than per triangle, and a print has hundreds of layers.
enum ToolpathGeometry {

    /// The most tubes drawn. Each costs 416 bytes (8 vertices, 24 indices), so this caps the
    /// geometry near 100 MB. A small print (~150k extrusions) fits whole; a big multi-plate
    /// Bambu print runs to millions, and is thinned to fit — see `Plan`.
    ///
    /// Colours stay four floats a vertex: SceneKit draws a byte-per-channel colour source
    /// as plain white.
    static let tubeBudget = 250_000

    enum Coloring: Equatable {
        /// By what each line is for, in the colours PrusaSlicer's preview uses (which Bambu
        /// Studio and OrcaSlicer share closely), so the picture matches the slicer's.
        case feature
        /// By the filament each line is printed in.
        case filament
    }

    /// Filament colours when the print changes filament, since which colour goes where is
    /// the point of a multi-colour print. Otherwise by feature: a single colour would show
    /// only the shape, which the slicer's thumbnail already does.
    static func coloring(for path: GCodeToolpath) -> Coloring {
        guard !path.filamentColors.isEmpty, let first = path.tools.first else { return .feature }
        return path.tools.contains { $0 != first } ? .filament : .feature
    }

    /// sRGB, like the slicer's own.
    static func color(of feature: GCodeFeature) -> SIMD4<Float> {
        func hex(_ value: UInt32) -> SIMD4<Float> {
            SIMD4(Float((value >> 16) & 0xFF) / 255, Float((value >> 8) & 0xFF) / 255,
                  Float(value & 0xFF) / 255, 1)
        }
        switch feature {
        case .other: return hex(0x5ED194)
        case .outerWall: return hex(0xFF7D38)
        case .innerWall: return hex(0xFFE64D)
        case .overhangWall: return hex(0x1F1FFF)
        case .sparseInfill: return hex(0xB03029)
        case .solidInfill, .bottomSurface: return hex(0x9654CC)
        case .topSurface: return hex(0xF04040)
        case .bridge: return hex(0x4D80BA)
        case .gapFill: return hex(0xFFFFFF)
        case .ironing: return hex(0xFF8C69)
        case .support: return hex(0x00FF00)
        case .supportInterface: return hex(0x008000)
        case .skirt: return hex(0x00876E)
        case .primeTower: return hex(0xB3E3AB)
        }
    }

    /// A drawn toolpath. Tubes go into the geometry in print order, so the print up to any
    /// layer is the start of it, and showing less of the print is only a matter of drawing
    /// fewer of its triangles: nothing is rebuilt.
    struct Model {
        let geometry: SCNGeometry
        /// Per layer of the toolpath, how many tubes are drawn up to and including it. A
        /// layer left out of a thinned print ends where the drawn layer below it does.
        let layerEnds: [Int]
        /// What was left out to fit the budget.
        let plan: Plan

        /// Draws the print up to and including `layer`; the last layer, or past it, is all of it.
        func show(throughLayer layer: Int) {
            guard let element = geometry.elements.first else { return }
            if layer >= layerEnds.count - 1 {
                element.primitiveRange = NSRange(location: NSNotFound, length: 0)
            } else {
                element.primitiveRange = NSRange(location: 0, length: layerEnds[max(layer, 0)] * trianglesPerTube)
            }
        }
    }

    static let trianglesPerTube = 8

    /// What gets drawn, worked out before any geometry is: which features, which layers,
    /// and how tall each tube is.
    struct Plan: Equatable {
        /// Features left out entirely. Interior ones go first, since they're hidden by the
        /// walls and top surfaces around them.
        var droppedFeatures: Set<GCodeFeature> = []
        /// Every `layerStride`th layer is drawn, counting down from the top so the top
        /// surface always is; each drawn layer is that many layers tall, so the print
        /// keeps its height and has no gaps.
        var layerStride = 1
        /// Every `tubeStride`th tube is drawn. Only for the rare print whose top layer alone
        /// is over budget, which no amount of layer skipping can bring under it.
        var tubeStride = 1
        var tubeCount = 0

        /// What a viewer is missing, for a print thinned to fit: "no infill", "1 in 3
        /// layers". Empty when the whole print is drawn.
        var omissions: [String] {
            var parts: [String] = []
            if droppedFeatures.contains(.sparseInfill) { parts.append(String(localized: "no infill")) }
            if droppedFeatures.contains(.innerWall) { parts.append(String(localized: "no inner walls")) }
            if layerStride > 1 { parts.append(String(localized: "1 in \(layerStride) layers")) }
            if tubeStride > 1 { parts.append(String(localized: "1 in \(tubeStride) lines")) }
            return parts
        }
    }

    /// Features that can be left out with the least visible loss, in order.
    static let droppableFeatures: [GCodeFeature] = [.sparseInfill, .innerWall]

    static func plan(_ path: GCodeToolpath, budget: Int = tubeBudget) -> Plan {
        // Tubes per feature per layer, after merging. Merging never crosses a feature or a
        // layer, so dropping either removes exactly its own count.
        let featureCount = GCodeFeature.allCases.count
        var counts = [Int](repeating: 0, count: path.layers.count * featureCount)
        for (layerIndex, layer) in path.layers.enumerated() {
            forEachTube(in: path, segments: path.printedSegments(of: layer), dropping: []) { start, _, _ in
                counts[layerIndex * featureCount + Int(path.features[start].rawValue)] += 1
            }
        }
        func total(dropping dropped: Set<GCodeFeature>, stride: Int) -> Int {
            var sum = 0
            let top = path.layers.count - 1
            for layerIndex in path.layers.indices where (top - layerIndex) % stride == 0 {
                for feature in GCodeFeature.allCases where !dropped.contains(feature) {
                    sum += counts[layerIndex * featureCount + Int(feature.rawValue)]
                }
            }
            return sum
        }

        var plan = Plan()
        plan.tubeCount = total(dropping: [], stride: 1)
        for feature in droppableFeatures where plan.tubeCount > budget {
            plan.droppedFeatures.insert(feature)
            plan.tubeCount = total(dropping: plan.droppedFeatures, stride: 1)
        }
        // Layers are roughly alike, so the first stride that the average says fits nearly
        // always does; stepping on covers the prints where it doesn't.
        // Past the layer count only the top layer is left, so that's as far as it goes.
        if plan.tubeCount > budget {
            let layers = max(path.layers.count, 1)
            plan.layerStride = min((plan.tubeCount + budget - 1) / budget, layers)
            plan.tubeCount = total(dropping: plan.droppedFeatures, stride: plan.layerStride)
            while plan.tubeCount > budget, plan.layerStride < layers {
                plan.layerStride += 1
                plan.tubeCount = total(dropping: plan.droppedFeatures, stride: plan.layerStride)
            }
        }
        if plan.tubeCount > budget {
            plan.tubeStride = (plan.tubeCount + budget - 1) / budget
            plan.tubeCount = (plan.tubeCount + plan.tubeStride - 1) / plan.tubeStride
        }
        return plan
    }

    /// How far a merged tube may stray from the extrusions it stands for, in millimetres:
    /// far below what shows at any zoom Quick Look allows.
    static let mergeTolerance: Float = 0.02
    /// Longest run of extrusions merged into one tube, which bounds the straightness check.
    static let mergeLimit = 64

    /// Calls `body` with each tube's first segment, start and end point. Consecutive
    /// extrusions of the same feature and tool that join end to start and run (nearly) in
    /// a line become one tube: slicers write long straight lines in many short pieces, and
    /// Bambu's arcs arrive flattened into them.
    static func forEachTube(
        in path: GCodeToolpath,
        segments: Range<Int>,
        dropping dropped: Set<GCodeFeature>,
        _ body: (_ firstSegment: Int, _ start: SIMD3<Float>, _ end: SIMD3<Float>) -> Void
    ) {
        let points = path.points
        let features = path.features
        let tools = path.tools
        // The points a tube passes through, which have to stay near its centre line.
        var joints: [SIMD3<Float>] = []
        joints.reserveCapacity(mergeLimit)
        var i = segments.lowerBound
        while i < segments.upperBound {
            if dropped.contains(features[i]) { i += 1; continue }
            let start = points[2 * i]
            var end = points[2 * i + 1]
            var last = i
            joints.removeAll(keepingCapacity: true)
            while last + 1 < segments.upperBound, last - i + 1 < mergeLimit {
                let next = last + 1
                guard features[next] == features[i], tools[next] == tools[i],
                      points[2 * next] == end else { break }
                let candidate = points[2 * next + 1]
                let axis = candidate - start
                let length = simd_length(axis)
                guard length > 0 else { break }
                let direction = axis / length
                joints.append(end)
                let straight = joints.allSatisfy { joint in
                    let offset = joint - start
                    let along = simd_dot(offset, direction)
                    guard along > 0, along < length else { return false }
                    return simd_length(offset - along * direction) <= mergeTolerance
                }
                guard straight else { joints.removeLast(); break }
                end = candidate
                last = next
            }
            body(i, start, end)
            i = last + 1
        }
    }

    /// The bead's size: the nozzle's line width, and the layer height.
    static func beadSize(of path: GCodeToolpath) -> (width: Float, height: Float) {
        let nozzle = path.printSettings?.nozzleDiameter.flatMap { Float($0) } ?? 0.4
        var height = path.printSettings?.layerHeight.flatMap { Float($0) }
        if height == nil, path.layers.count > 1 {
            // The commonest step between layers, which skips the odd first layer.
            let steps = zip(path.layers.dropFirst(), path.layers).map { ($0.z - $1.z) }.filter { $0 > 0 }
            let rounded = Dictionary(grouping: steps) { ($0 * 100).rounded() / 100 }
            height = rounded.max { $0.value.count < $1.value.count }?.key
        }
        let clampedHeight = min(max(height ?? 0.2, 0.05), 1)
        // Slicers default to a line a little wider than the nozzle.
        return (min(max(nozzle * 1.125, 0.1), 2), clampedHeight)
    }

    static func build(_ path: GCodeToolpath, budget: Int = tubeBudget) -> Model? {
        let plan = plan(path, budget: budget)
        guard plan.tubeCount > 0 else { return nil }

        let (width, layerHeight) = beadSize(of: path)
        let height = layerHeight * Float(plan.layerStride)
        let halfWidth = width / 2

        let coloring = coloring(for: path)
        // Vertex colours are taken as already linear; see `SceneBuilder.linearComponents`.
        let featureColors = GCodeFeature.allCases.map { SceneBuilder.linearComponents(color(of: $0)) }
        let fallback = SceneBuilder.linearComponents(SIMD4(0.75, 0.75, 0.75, 1))
        let toolColors = path.filamentColors.map(SceneBuilder.linearComponents)

        let vertexCount = plan.tubeCount * 8
        let positions = UnsafeMutablePointer<Float>.allocate(capacity: vertexCount * 3)
        let normals = UnsafeMutablePointer<Float>.allocate(capacity: vertexCount * 3)
        let colors = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: vertexCount)
        let indices = UnsafeMutablePointer<UInt32>.allocate(capacity: plan.tubeCount * 24)

        var tube = 0
        var candidate = 0
        var layerEnds = [Int](repeating: 0, count: path.layers.count)
        let up = SIMD3<Float>(0, 0, 1)
        let top = path.layers.count - 1
        for (layerIndex, layer) in path.layers.enumerated() {
            defer { layerEnds[layerIndex] = tube }
            guard (top - layerIndex) % plan.layerStride == 0 else { continue }
            // No bead reaches down through the bed: not the first layer, and not a thinned-out
            // print's lowest drawn layer, which stands in for fewer layers than the stride.
            let halfHeight = (layer.z > 0 ? min(height, layer.z) : height) / 2
            forEachTube(in: path, segments: path.printedSegments(of: layer), dropping: plan.droppedFeatures) { first, a, b in
                defer { candidate += 1 }
                guard candidate % plan.tubeStride == 0, tube < plan.tubeCount else { return }
                let color: SIMD4<Float>
                switch coloring {
                case .feature: color = featureColors[Int(path.features[first].rawValue)]
                case .filament:
                    let tool = Int(path.tools[first])
                    color = tool < toolColors.count ? toolColors[tool] : fallback
                }

                let along = b - a
                let length = simd_length(along)
                let direction = length > 0 ? along / length : SIMD3<Float>(1, 0, 0)
                // Across the line, level with the bed; a straight-up move has no "across"
                // of its own, so any level direction will do.
                var side = simd_cross(direction, up)
                side = simd_length(side) > 1e-6 ? simd_normalize(side) : SIMD3(1, 0, 0)
                let lift = simd_normalize(simd_cross(side, direction))
                // The nozzle rides on top of the bead it lays, so the bead hangs below the
                // line; and runs a half-width past each end so corners close up.
                let overhang = direction * halfWidth
                let drop = up * halfHeight
                let starts = a - overhang - drop, ends = b + overhang - drop

                // Corners round the cross-section: right, top, left, bottom. Each corner's
                // normal points straight out of it, which shades the diamond as a round bead.
                let base = tube * 8
                func corner(_ k: Int, _ offset: SIMD3<Float>, _ normal: SIMD3<Float>) {
                    for (v, centre) in [(base + k, starts), (base + 4 + k, ends)] {
                        let p = centre + offset
                        positions[v * 3] = p.x; positions[v * 3 + 1] = p.y; positions[v * 3 + 2] = p.z
                        normals[v * 3] = normal.x; normals[v * 3 + 1] = normal.y; normals[v * 3 + 2] = normal.z
                        colors[v] = color
                    }
                }
                corner(0, side * halfWidth, side)
                corner(1, lift * halfHeight, lift)
                corner(2, -side * halfWidth, -side)
                corner(3, -lift * halfHeight, -lift)
                // Four faces round the tube, each two triangles wound outwards.
                let index = indices + tube * 24
                for k in 0..<4 {
                    let a0 = UInt32(base + k), a1 = UInt32(base + (k + 1) % 4)
                    let b0 = a0 + 4, b1 = a1 + 4
                    let face = index + k * 6
                    face[0] = a0; face[1] = b0; face[2] = b1
                    face[3] = a0; face[4] = b1; face[5] = a1
                }
                tube += 1
            }
        }

        func data<T>(_ buffer: UnsafeMutablePointer<T>, count: Int) -> Data {
            // Handed over without a copy; SceneKit frees it with the geometry.
            Data(bytesNoCopy: buffer, count: count * MemoryLayout<T>.stride,
                 deallocator: .custom { pointer, _ in pointer.deallocate() })
        }
        func floatSource(_ buffer: UnsafeMutablePointer<Float>, _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(data: data(buffer, count: vertexCount * 3), semantic: semantic,
                              vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: 3,
                              bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        let colorSource = SCNGeometrySource(
            data: data(colors, count: vertexCount), semantic: .color, vectorCount: vertexCount,
            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
            dataOffset: 0, dataStride: 16
        )
        let element = SCNGeometryElement(
            data: data(indices, count: plan.tubeCount * 24), primitiveType: .triangles,
            primitiveCount: plan.tubeCount * trianglesPerTube, bytesPerIndex: 4
        )
        let geometry = SCNGeometry(
            sources: [floatSource(positions, .vertex), floatSource(normals, .normal), colorSource],
            elements: [element]
        )

        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white
        material.specular.contents = NSColor(white: 0.4, alpha: 1)
        material.shininess = 30
        material.lightingModel = .phong
        geometry.materials = [material]
        return Model(geometry: geometry, layerEnds: layerEnds, plan: plan)
    }
}
