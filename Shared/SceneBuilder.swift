import SceneKit
import simd

final class SceneBuilder {

    enum Appearance {
        case light
        case dark
    }

    static let turntableNodeName = "turntable"

    /// Stops or restarts the auto-rotation. Pausing the turntable node rather than the whole
    /// scene freezes it at its current angle and leaves everything else (the camera
    /// controller's inertia, the first-frame settle that pauses the scene) independent.
    static func setSpinning(_ spinning: Bool, in scene: SCNScene) {
        scene.rootNode.childNode(withName: turntableNodeName, recursively: false)?.isPaused = !spinning
    }

    static func buildScene(
        from items: [BuildItem],
        appearance: Appearance = .light,
        showBuildPlate: Bool = true,
        bedSize: SIMD2<Float>? = nil
    ) -> SCNScene {
        let scene = SCNScene()

        let isDark = appearance == .dark
        scene.background.contents = isDark
            ? NSColor(white: 0.15, alpha: 1.0)
            : NSColor.white

        // 3MF is Z-up; SceneKit is Y-up. Rotate the whole assembly -90° about X so the
        // build plate lies flat in the XZ plane and the print height runs up the screen.
        let zUpToYUp = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))

        // Container holds all build items so we can center and rotate them together
        let containerNode = SCNNode()
        for item in items {
            let geometry = buildGeometry(from: item.mesh)
            let node = SCNNode(geometry: geometry)
            node.simdTransform = zUpToYUp * item.transform
            containerNode.addChildNode(node)
        }

        // Compute bounding box of the whole assembly, then re-center at the origin
        let (bbMin, bbMax) = containerNode.boundingBox
        let center = SCNVector3(
            (bbMin.x + bbMax.x) / 2,
            (bbMin.y + bbMax.y) / 2,
            (bbMin.z + bbMax.z) / 2
        )
        containerNode.position = SCNVector3(-center.x, -center.y, -center.z)

        // Pivot node sits at origin so rotation spins the model around its center
        let pivotNode = SCNNode()
        pivotNode.name = turntableNodeName
        pivotNode.addChildNode(containerNode)
        scene.rootNode.addChildNode(pivotNode)

        // Continuous rotation around the vertical (Y) axis
        let spin = SCNAction.repeatForever(
            SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 12)
        )
        pivotNode.runAction(spin)

        let extents = SCNVector3(
            bbMax.x - bbMin.x,
            bbMax.y - bbMin.y,
            bbMax.z - bbMin.z
        )
        let maxExtent = max(extents.x, extents.y, extents.z)

        // Build-plate grid — a child of the pivot, so it turns with the model and the
        // whole thing reads as one object on a turntable rather than the model sliding
        // over a fixed floor. Centred on the pivot, so it spins in place.
        // Skipped for thumbnails, where the grid would just be noise at icon size.
        var plateWidth: Float = 0
        var plateDepth: Float = 0
        if showBuildPlate {
            // Prefer the printer's real printable area, which the slicer records in the
            // project: it shows the model at true scale against the bed it was sliced for,
            // so a keychain on a 256 mm plate reads as small. Files without it (plain 3MF,
            // no slicer profile) fall back to a generic grid sized to the model itself.
            if let bedSize, bedSize.x > 0, bedSize.y > 0 {
                plateWidth = bedSize.x
                plateDepth = bedSize.y
            } else {
                let footprintMax = max(Float(extents.x), Float(extents.z))
                plateWidth = max(ceil(footprintMax * 1.5 / 50) * 50, 100)
                plateDepth = plateWidth
            }
            let gridNode = buildBuildPlate(width: plateWidth, depth: plateDepth, appearance: appearance)
            gridNode.position = SCNVector3(0, -extents.y / 2, 0)
            pivotNode.addChildNode(gridNode)
        }

        // Camera (frame the larger of model or plate)
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        // Frame the model, letting the plate pull the camera back only so far. A full bed is
        // often far bigger than the print, and framing the whole thing would shrink the model
        // to a speck; past this cap the bed simply runs off the edges of the view.
        let plateExtent = max(plateWidth, plateDepth) * 0.5
        let viewExtent = max(Float(maxExtent), min(plateExtent, Float(maxExtent) * 1.5))
        let distance = CGFloat(viewExtent) * 1.8
        cameraNode.position = SCNVector3(
            distance * 0.5,
            distance * 0.5,
            distance
        )
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // Key light
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = isDark ? 600 : 800
        keyLight.color = NSColor.white
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(distance, distance * 1.5, distance)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)

        // Fill light
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = isDark ? 300 : 400
        fillLight.color = NSColor.white
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-distance, distance * 0.5, -distance * 0.5)
        fillNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(fillNode)

        // Ambient light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = isDark ? 200 : 300
        ambientLight.color = NSColor(white: isDark ? 0.6 : 0.8, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    // MARK: - Build plate

    private static func buildBuildPlate(width: Float, depth: Float, appearance: Appearance) -> SCNNode {
        let isDark = appearance == .dark
        let halfWidth = width / 2
        let halfDepth = depth / 2
        let minorStep: Float = 10
        let majorEvery = 5  // every 5 minor steps = 50mm

        var minorVerts: [SCNVector3] = []
        var majorVerts: [SCNVector3] = []

        // Grid lines step out from the centre, so they stay aligned across the two axes even
        // when the bed is not square and its half-extent is not a whole number of steps.
        func addLines(halfExtent: Float, halfSpan: Float, alongZ: Bool) {
            for i in -Int(halfExtent / minorStep)...Int(halfExtent / minorStep) {
                let coord = Float(i) * minorStep
                let ends = alongZ
                    ? [SCNVector3(coord, 0, -halfSpan), SCNVector3(coord, 0, halfSpan)]
                    : [SCNVector3(-halfSpan, 0, coord), SCNVector3(halfSpan, 0, coord)]
                if i % majorEvery == 0 {
                    majorVerts.append(contentsOf: ends)
                } else {
                    minorVerts.append(contentsOf: ends)
                }
            }
        }
        addLines(halfExtent: halfWidth, halfSpan: halfDepth, alongZ: true)
        addLines(halfExtent: halfDepth, halfSpan: halfWidth, alongZ: false)

        // The bed's real outline. Grid lines land on multiples of 10 mm from the centre and
        // so stop short of an edge like 256 mm; without this the plate would look undersized.
        let corners = [
            SCNVector3(-halfWidth, 0, -halfDepth), SCNVector3( halfWidth, 0, -halfDepth),
            SCNVector3( halfWidth, 0,  halfDepth), SCNVector3(-halfWidth, 0,  halfDepth),
        ]
        for (i, corner) in corners.enumerated() {
            majorVerts.append(corner)
            majorVerts.append(corners[(i + 1) % corners.count])
        }

        let minorColor = isDark
            ? NSColor(white: 0.30, alpha: 1.0)
            : NSColor(white: 0.82, alpha: 1.0)
        let majorColor = isDark
            ? NSColor(white: 0.50, alpha: 1.0)
            : NSColor(white: 0.55, alpha: 1.0)

        let node = SCNNode()
        node.addChildNode(makeLineNode(vertices: minorVerts, color: minorColor))
        node.addChildNode(makeLineNode(vertices: majorVerts, color: majorColor))
        return node
    }

    private static func makeLineNode(vertices: [SCNVector3], color: NSColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: vertices)
        let indices: [UInt32] = (0..<UInt32(vertices.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    // MARK: - Geometry

    /// Flat-shaded geometry: each triangle gets its own three vertices, so its face normal
    /// isn't averaged with its neighbours'.
    ///
    /// Written straight into the buffers SceneKit keeps, as 32-bit floats, with no arrays in
    /// between. A 3.8M-triangle plate went through `SCNVector3` arrays (three 8-byte
    /// components each), then copies of them, peaking over 700 MB.
    static func buildGeometry(from mesh: MeshData) -> SCNGeometry {
        let vertices = mesh.vertices
        let triangles = mesh.triangles
        let triangleColors = mesh.triangleColors

        let positions = UnsafeMutablePointer<Float>.allocate(capacity: triangles.count * 9)
        let normals = UnsafeMutablePointer<Float>.allocate(capacity: triangles.count * 9)
        let colors = triangleColors.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: triangles.count * 12) }

        var kept = 0
        for (i, tri) in triangles.enumerated() {
            let i0 = Int(tri.0), i1 = Int(tri.1), i2 = Int(tri.2)
            // Skip triangles that reference vertices outside the mesh — a malformed
            // .3mf would otherwise crash with an out-of-bounds access.
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let v0 = vertices[i0], v1 = vertices[i1], v2 = vertices[i2]

            // Compute face normal (CCW winding)
            let normal = simd_normalize(simd_cross(v1 - v0, v2 - v0))

            // Written at the running count, not i, so skipped triangles leave no gaps.
            let p = positions + kept * 9, n = normals + kept * 9
            write3(p, v0); write3(p + 3, v1); write3(p + 6, v2)
            write3(n, normal); write3(n + 3, normal); write3(n + 6, normal)
            if let colors, let (c0, c1, c2) = triangleColors?[i] {
                let c = colors + kept * 12
                write4(c, c0); write4(c + 4, c1); write4(c + 8, c2)
            }
            kept += 1
        }

        let vertexCount = kept * 3
        func source(_ buffer: UnsafeMutablePointer<Float>, _ semantic: SCNGeometrySource.Semantic,
                    components: Int) -> SCNGeometrySource {
            // Handed over without a copy; SceneKit frees it with the geometry.
            let data = Data(bytesNoCopy: buffer, count: vertexCount * components * 4,
                            deallocator: .custom { pointer, _ in pointer.deallocate() })
            return SCNGeometrySource(
                data: data, semantic: semantic, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: components,
                bytesPerComponent: 4, dataOffset: 0, dataStride: components * 4
            )
        }
        var sources = [source(positions, .vertex, components: 3), source(normals, .normal, components: 3)]
        if let colors {
            sources.append(source(colors, .color, components: 4))
        }

        // Every triangle has vertices of its own, so the indices just count up. 16 bits
        // are enough for most meshes and halve the index buffer.
        let bytesPerIndex = vertexCount <= Int(UInt16.max) + 1 ? 2 : 4
        var indexData = Data(count: vertexCount * bytesPerIndex)
        indexData.withUnsafeMutableBytes { raw in
            if bytesPerIndex == 2 {
                let indices = raw.bindMemory(to: UInt16.self)
                for i in 0..<vertexCount { indices[i] = UInt16(i) }
            } else {
                let indices = raw.bindMemory(to: UInt32.self)
                for i in 0..<vertexCount { indices[i] = UInt32(i) }
            }
        }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .triangles, primitiveCount: kept, bytesPerIndex: bytesPerIndex
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        if colors != nil {
            material.diffuse.contents = NSColor.white
        } else if let color = mesh.uniformColor {
            material.diffuse.contents = linearColor(color)
        } else {
            material.diffuse.contents = NSColor(white: 0.75, alpha: 1.0)
        }
        material.specular.contents = NSColor.white
        material.shininess = 25
        material.lightingModel = .phong
        material.isDoubleSided = true
        geometry.materials = [material]

        return geometry
    }

    @inline(__always)
    private static func write3(_ p: UnsafeMutablePointer<Float>, _ v: SIMD3<Float>) {
        p[0] = v.x; p[1] = v.y; p[2] = v.z
    }

    @inline(__always)
    private static func write4(_ p: UnsafeMutablePointer<Float>, _ v: SIMD4<Float>) {
        p[0] = v.x; p[1] = v.y; p[2] = v.z; p[3] = v.w
    }

    /// A whole-mesh colour as a material colour that renders exactly as the same values do
    /// as vertex colours, which SceneKit reads as linear. (The values are really sRGB, so
    /// both render lighter than the filament; kept identical so the two paths agree.)
    static func linearColor(_ color: SIMD4<Float>) -> NSColor {
        let space = NSColorSpace(cgColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!
        let components = [CGFloat(color.x), CGFloat(color.y), CGFloat(color.z), CGFloat(color.w)]
        return NSColor(colorSpace: space, components: components, count: 4)
    }
}
