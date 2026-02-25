import SceneKit
import simd

final class SceneBuilder {

    static func buildScene(from mesh: MeshData) -> SCNScene {
        let scene = SCNScene()

        let geometry = buildGeometry(from: mesh)
        let modelNode = SCNNode(geometry: geometry)

        // Compute bounding box, then re-center the model at the origin
        let (bbMin, bbMax) = modelNode.boundingBox
        let center = SCNVector3(
            (bbMin.x + bbMax.x) / 2,
            (bbMin.y + bbMax.y) / 2,
            (bbMin.z + bbMax.z) / 2
        )
        modelNode.position = SCNVector3(-center.x, -center.y, -center.z)

        // Pivot node sits at origin so rotation spins the model around its center
        let pivotNode = SCNNode()
        pivotNode.addChildNode(modelNode)
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

        // Camera
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let distance = CGFloat(maxExtent) * 1.8
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
        keyLight.intensity = 800
        keyLight.color = NSColor.white
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(distance, distance * 1.5, distance)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)

        // Fill light
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 400
        fillLight.color = NSColor.white
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-distance, distance * 0.5, -distance * 0.5)
        fillNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(fillNode)

        // Ambient light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 300
        ambientLight.color = NSColor(white: 0.8, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        return scene
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
            let v0 = vertices[Int(tri.0)]
            let v1 = vertices[Int(tri.1)]
            let v2 = vertices[Int(tri.2)]

            // Compute face normal (CCW winding)
            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let normal = simd_normalize(simd_cross(edge1, edge2))
            let scnNormal = SCNVector3(normal.x, normal.y, normal.z)

            let baseIndex = UInt32(i * 3)
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
