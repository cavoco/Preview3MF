import XCTest
import SceneKit
import simd
@testable import Preview3MF

final class SceneBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func makeTriangleMesh() -> MeshData {
        MeshData(
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            triangles: [(0, 1, 2)]
        )
    }

    private func makeCubeMesh() -> MeshData {
        MeshData(
            vertices: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
                SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
            ],
            triangles: [
                (0, 1, 2), (0, 2, 3),
                (4, 6, 5), (4, 7, 6),
                (0, 4, 5), (0, 5, 1),
                (3, 2, 6), (3, 6, 7),
                (0, 3, 7), (0, 7, 4),
                (1, 5, 6), (1, 6, 2),
            ]
        )
    }

    private func findModelNode(in scene: SCNScene) throws -> SCNNode {
        let pivotNode = try XCTUnwrap(
            scene.rootNode.childNodes.first { $0.childNodes.contains { $0.geometry != nil } },
            "Should have a pivot node containing the model"
        )
        return try XCTUnwrap(
            pivotNode.childNodes.first { $0.geometry != nil },
            "Pivot should contain a model node with geometry"
        )
    }

    /// Extract normal vectors from a geometry's normal source as [SIMD3<Float>].
    private func extractNormals(from geometry: SCNGeometry) throws -> [SIMD3<Float>] {
        let source = try XCTUnwrap(
            geometry.sources.first { $0.semantic == .normal },
            "Geometry should have a normal source"
        )
        let stride = source.dataStride
        let offset = source.dataOffset
        let count = source.vectorCount
        let data = source.data

        return data.withUnsafeBytes { buffer in
            (0..<count).map { i in
                let base = stride * i + offset
                let x = buffer.loadUnaligned(fromByteOffset: base, as: Float.self)
                let y = buffer.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                let z = buffer.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                return SIMD3(x, y, z)
            }
        }
    }

    // MARK: - Tests

    func testSceneNodeHierarchy() throws {
        let scene = SceneBuilder.buildScene(from: makeTriangleMesh())

        let pivotNode = try XCTUnwrap(
            scene.rootNode.childNodes.first { $0.childNodes.contains { $0.geometry != nil } },
            "Should have a pivot node containing the model"
        )
        let modelNode = pivotNode.childNodes.first { $0.geometry != nil }
        XCTAssertNotNil(modelNode, "Pivot should contain a model node with geometry")
    }

    func testCameraExists() {
        let scene = SceneBuilder.buildScene(from: makeTriangleMesh())
        let cameraNodes = scene.rootNode.childNodes.filter { $0.camera != nil }
        XCTAssertEqual(cameraNodes.count, 1, "Scene should have exactly one camera")
    }

    func testLightingSetup() {
        let scene = SceneBuilder.buildScene(from: makeTriangleMesh())
        let lightNodes = scene.rootNode.childNodes.filter { $0.light != nil }
        XCTAssertEqual(lightNodes.count, 3, "Scene should have 3 lights")

        let lightTypes = lightNodes.compactMap { $0.light?.type }
        let directionalCount = lightTypes.filter { $0 == .directional }.count
        let ambientCount = lightTypes.filter { $0 == .ambient }.count
        XCTAssertEqual(directionalCount, 2, "Should have 2 directional lights")
        XCTAssertEqual(ambientCount, 1, "Should have 1 ambient light")
    }

    func testGeometryVertexCount() throws {
        let mesh = makeCubeMesh()
        let scene = SceneBuilder.buildScene(from: mesh)

        let modelNode = try findModelNode(in: scene)
        let geometry = try XCTUnwrap(modelNode.geometry)
        let vertexSource = try XCTUnwrap(geometry.sources.first { $0.semantic == .vertex })

        // Flat shading: each triangle gets its own 3 vertices
        XCTAssertEqual(vertexSource.vectorCount, mesh.triangles.count * 3)
    }

    func testGeometryHasNormals() throws {
        let scene = SceneBuilder.buildScene(from: makeTriangleMesh())

        let modelNode = try findModelNode(in: scene)
        let geometry = try XCTUnwrap(modelNode.geometry)
        let normalSource = try XCTUnwrap(
            geometry.sources.first { $0.semantic == .normal },
            "Geometry should include normals"
        )
        let vertexSource = try XCTUnwrap(geometry.sources.first { $0.semantic == .vertex })
        XCTAssertEqual(normalSource.vectorCount, vertexSource.vectorCount,
                       "Should have one normal per vertex")
    }

    func testNormalValues() throws {
        // Triangle in the XY plane at z=0: (0,0,0), (1,0,0), (0,1,0)
        // CCW cross product of (1,0,0)-(0,0,0) x (0,1,0)-(0,0,0) = (0,0,1)
        let scene = SceneBuilder.buildScene(from: makeTriangleMesh())

        let modelNode = try findModelNode(in: scene)
        let geometry = try XCTUnwrap(modelNode.geometry)
        let normals = try extractNormals(from: geometry)

        // Single triangle produces 3 identical normals (flat shading)
        XCTAssertEqual(normals.count, 3)
        for normal in normals {
            XCTAssertEqual(normal.x, 0, accuracy: 1e-5)
            XCTAssertEqual(normal.y, 0, accuracy: 1e-5)
            XCTAssertEqual(normal.z, 1, accuracy: 1e-5)
        }
    }

    func testNormalValuesMultipleTriangles() throws {
        // Two triangles: one in XY plane (normal +Z), one in XZ plane (normal -Y)
        let mesh = MeshData(
            vertices: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),  // XY plane
                SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0),  // XZ plane, CCW from -Y
            ],
            triangles: [(0, 1, 2), (3, 4, 5)]
        )
        let scene = SceneBuilder.buildScene(from: mesh)

        let modelNode = try findModelNode(in: scene)
        let geometry = try XCTUnwrap(modelNode.geometry)
        let normals = try extractNormals(from: geometry)

        XCTAssertEqual(normals.count, 6)

        // First triangle: normal should be (0, 0, 1)
        for i in 0..<3 {
            XCTAssertEqual(normals[i].x, 0, accuracy: 1e-5)
            XCTAssertEqual(normals[i].y, 0, accuracy: 1e-5)
            XCTAssertEqual(normals[i].z, 1, accuracy: 1e-5)
        }

        // Second triangle: cross((0,0,1)-(0,0,0), (1,0,0)-(0,0,0)) = (0,1,0)
        for i in 3..<6 {
            XCTAssertEqual(normals[i].x, 0, accuracy: 1e-5)
            XCTAssertEqual(normals[i].y, 1, accuracy: 1e-5)
            XCTAssertEqual(normals[i].z, 0, accuracy: 1e-5)
        }
    }

    func testDegenerateTriangle() throws {
        // Collinear points produce a zero-length cross product.
        // simd_normalize of a zero vector yields NaN — verify the builder doesn't crash.
        let mesh = MeshData(
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)],
            triangles: [(0, 1, 2)]
        )
        let scene = SceneBuilder.buildScene(from: mesh)

        let modelNode = try findModelNode(in: scene)
        let geometry = try XCTUnwrap(modelNode.geometry)

        // Should still produce geometry with 3 vertices and normals (even if NaN)
        let vertexSource = try XCTUnwrap(geometry.sources.first { $0.semantic == .vertex })
        let normalSource = try XCTUnwrap(geometry.sources.first { $0.semantic == .normal })
        XCTAssertEqual(vertexSource.vectorCount, 3)
        XCTAssertEqual(normalSource.vectorCount, 3)
    }

    func testSingleTriangleVertexCount() throws {
        let scene = SceneBuilder.buildScene(from: makeTriangleMesh())
        let modelNode = try findModelNode(in: scene)
        let geometry = try XCTUnwrap(modelNode.geometry)
        let vertexSource = try XCTUnwrap(geometry.sources.first { $0.semantic == .vertex })
        XCTAssertEqual(vertexSource.vectorCount, 3)
    }

    func testModelCentering() throws {
        let mesh = MeshData(
            vertices: [SIMD3(2, 4, 6), SIMD3(4, 8, 12), SIMD3(6, 4, 6)],
            triangles: [(0, 1, 2)]
        )
        let scene = SceneBuilder.buildScene(from: mesh)

        let modelNode = try findModelNode(in: scene)

        // Bounding box center: ((2+6)/2, (4+8)/2, (6+12)/2) = (4, 6, 9)
        // Position should negate the center to place the model at the origin
        let pos = modelNode.position
        XCTAssertEqual(pos.x, -4, accuracy: 0.01)
        XCTAssertEqual(pos.y, -6, accuracy: 0.01)
        XCTAssertEqual(pos.z, -9, accuracy: 0.01)
    }

    func testMaterialProperties() throws {
        let scene = SceneBuilder.buildScene(from: makeTriangleMesh())

        let modelNode = try findModelNode(in: scene)
        let geometry = try XCTUnwrap(modelNode.geometry)
        let material = try XCTUnwrap(geometry.materials.first)

        XCTAssertEqual(material.lightingModel, .phong)
        XCTAssertTrue(material.isDoubleSided)

        let diffuseColor = try XCTUnwrap(material.diffuse.contents as? NSColor,
                                         "Diffuse contents should be an NSColor")
        XCTAssertEqual(diffuseColor.whiteComponent, 0.75, accuracy: 0.01)

        let specularColor = try XCTUnwrap(material.specular.contents as? NSColor,
                                          "Specular contents should be an NSColor")
        XCTAssertEqual(specularColor.whiteComponent, 1.0, accuracy: 0.01)
    }
}
