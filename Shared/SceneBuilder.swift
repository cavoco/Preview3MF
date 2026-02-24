import SceneKit
import simd

final class SceneBuilder {

    static func buildScene(from mesh: MeshData) -> SCNScene {
        let scene = SCNScene()

        let geometry = buildGeometry(from: mesh)
        let modelNode = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(modelNode)

        // Compute bounding box for camera framing
        let (bbMin, bbMax) = modelNode.boundingBox
        let center = SCNVector3(
            (bbMin.x + bbMax.x) / 2,
            (bbMin.y + bbMax.y) / 2,
            (bbMin.z + bbMax.z) / 2
        )
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
            center.x + distance * 0.5,
            center.y + distance * 0.5,
            center.z + distance
        )
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)

        // Key light
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 800
        keyLight.color = NSColor.white
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(
            center.x + distance,
            center.y + distance * 1.5,
            center.z + distance
        )
        keyNode.look(at: center)
        scene.rootNode.addChildNode(keyNode)

        // Fill light
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 400
        fillLight.color = NSColor.white
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(
            center.x - distance,
            center.y + distance * 0.5,
            center.z - distance * 0.5
        )
        fillNode.look(at: center)
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

    private static func buildGeometry(from mesh: MeshData) -> SCNGeometry {
        let vertices = mesh.vertices
        let triangles = mesh.triangles

        // Build per-face vertices with normals for flat shading
        var faceVertices: [SCNVector3] = []
        var faceNormals: [SCNVector3] = []
        var indices: [UInt32] = []

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

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])

        // Neutral material
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(white: 0.75, alpha: 1.0)
        material.specular.contents = NSColor.white
        material.shininess = 25
        material.lightingModel = .phong
        material.isDoubleSided = true
        geometry.materials = [material]

        return geometry
    }
}
