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

    static func buildGeometry(from mesh: MeshData) -> SCNGeometry {
        let vertices = mesh.vertices
        let triangles = mesh.triangles

        // Build per-face vertices with normals for flat shading
        var faceVertices: [SCNVector3] = []
        var faceNormals: [SCNVector3] = []
        var faceColors: [Float] = []
        var indices: [UInt32] = []
        let hasColors = mesh.triangleColors != nil

        for (i, tri) in triangles.enumerated() {
            let i0 = Int(tri.0), i1 = Int(tri.1), i2 = Int(tri.2)
            // Skip triangles that reference vertices outside the mesh — a malformed
            // .3mf would otherwise crash with an out-of-bounds access.
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let v0 = vertices[i0]
            let v1 = vertices[i1]
            let v2 = vertices[i2]

            // Compute face normal (CCW winding)
            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let normal = simd_normalize(simd_cross(edge1, edge2))
            let scnNormal = SCNVector3(normal.x, normal.y, normal.z)

            // Index off the running vertex count, not i*3, so skipped triangles
            // don't leave gaps that desync indices from faceVertices.
            let baseIndex = UInt32(faceVertices.count)
            faceVertices.append(SCNVector3(v0.x, v0.y, v0.z))
            faceVertices.append(SCNVector3(v1.x, v1.y, v1.z))
            faceVertices.append(SCNVector3(v2.x, v2.y, v2.z))
            faceNormals.append(scnNormal)
            faceNormals.append(scnNormal)
            faceNormals.append(scnNormal)
            indices.append(baseIndex)
            indices.append(baseIndex + 1)
            indices.append(baseIndex + 2)

            if let colors = mesh.triangleColors {
                let (c0, c1, c2) = colors[i]
                faceColors.append(contentsOf: [c0.x, c0.y, c0.z, c0.w])
                faceColors.append(contentsOf: [c1.x, c1.y, c1.z, c1.w])
                faceColors.append(contentsOf: [c2.x, c2.y, c2.z, c2.w])
            }
        }

        let vertexSource = SCNGeometrySource(
            vertices: faceVertices
        )
        let normalSource = SCNGeometrySource(
            normals: faceNormals
        )
        let element = SCNGeometryElement(
            indices: indices,
            primitiveType: .triangles
        )

        var sources = [vertexSource, normalSource]

        if hasColors {
            let colorData = Data(bytes: faceColors, count: faceColors.count * MemoryLayout<Float>.size)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: faceVertices.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )
            sources.append(colorSource)
        }

        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        if hasColors {
            material.diffuse.contents = NSColor.white
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
}
