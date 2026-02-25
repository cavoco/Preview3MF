import XCTest
import simd
@testable import Preview3MF

final class ThreeMFParserTests: XCTestCase {

    // MARK: - MiniZIP Helper

    /// Builds a minimal stored (uncompressed) ZIP archive in memory.
    private struct MiniZIP {
        struct Entry {
            let path: String
            let data: Data
        }

        static func createArchive(entries: [Entry]) -> Data {
            var archive = Data()
            var centralDirectory = Data()
            var localOffsets: [UInt32] = []

            for entry in entries {
                localOffsets.append(UInt32(archive.count))
                let nameData = Data(entry.path.utf8)
                let crc = crc32(entry.data)
                let size = UInt32(entry.data.count)

                // Local file header
                append32(&archive, 0x04034B50)
                append16(&archive, 20)          // version needed
                append16(&archive, 0)           // flags
                append16(&archive, 0)           // compression: stored
                append16(&archive, 0)           // mod time
                append16(&archive, 0)           // mod date
                append32(&archive, crc)
                append32(&archive, size)        // compressed size
                append32(&archive, size)        // uncompressed size
                append16(&archive, UInt16(nameData.count))
                append16(&archive, 0)           // extra field length
                archive.append(nameData)
                archive.append(entry.data)
            }

            let cdOffset = UInt32(archive.count)

            for (i, entry) in entries.enumerated() {
                let nameData = Data(entry.path.utf8)
                let crc = crc32(entry.data)
                let size = UInt32(entry.data.count)

                // Central directory entry
                append32(&centralDirectory, 0x02014B50)
                append16(&centralDirectory, 20)  // version made by
                append16(&centralDirectory, 20)  // version needed
                append16(&centralDirectory, 0)   // flags
                append16(&centralDirectory, 0)   // compression
                append16(&centralDirectory, 0)   // mod time
                append16(&centralDirectory, 0)   // mod date
                append32(&centralDirectory, crc)
                append32(&centralDirectory, size)
                append32(&centralDirectory, size)
                append16(&centralDirectory, UInt16(nameData.count))
                append16(&centralDirectory, 0)   // extra field length
                append16(&centralDirectory, 0)   // comment length
                append16(&centralDirectory, 0)   // disk number
                append16(&centralDirectory, 0)   // internal attrs
                append32(&centralDirectory, 0)   // external attrs
                append32(&centralDirectory, localOffsets[i])
                centralDirectory.append(nameData)
            }

            let cdSize = UInt32(centralDirectory.count)
            archive.append(centralDirectory)

            // End of central directory record
            append32(&archive, 0x06054B50)
            append16(&archive, 0)   // disk number
            append16(&archive, 0)   // cd start disk
            append16(&archive, UInt16(entries.count))
            append16(&archive, UInt16(entries.count))
            append32(&archive, cdSize)
            append32(&archive, cdOffset)
            append16(&archive, 0)   // comment length

            return archive
        }

        private static func append16(_ data: inout Data, _ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        private static func append32(_ data: inout Data, _ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        private static func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return crc ^ 0xFFFF_FFFF
        }

        private static let crc32Table: [UInt32] = (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }

    // MARK: - XML Helpers

    private func makeModelXML(vertices: [SIMD3<Float>], triangles: [(Int, Int, Int)]) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<model xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">"
        xml += "<resources><object id=\"1\" type=\"model\"><mesh><vertices>"
        for v in vertices {
            xml += "<vertex x=\"\(v.x)\" y=\"\(v.y)\" z=\"\(v.z)\"/>"
        }
        xml += "</vertices><triangles>"
        for t in triangles {
            xml += "<triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>"
        }
        xml += "</triangles></mesh></object></resources>"
        xml += "<build><item objectid=\"1\"/></build></model>"
        return Data(xml.utf8)
    }

    private func makeColorModelXML(
        colors: [(String)],
        vertices: [SIMD3<Float>],
        triangles: [(v1: Int, v2: Int, v3: Int, pid: Int?, p1: Int?, p2: Int?, p3: Int?)],
        objectPID: Int? = nil,
        objectPIndex: Int? = nil
    ) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<model xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">"
        xml += "<resources>"
        xml += "<basematerials id=\"1\">"
        for color in colors {
            xml += "<base displaycolor=\"\(color)\"/>"
        }
        xml += "</basematerials>"

        var objAttrs = "id=\"2\" type=\"model\""
        if let pid = objectPID { objAttrs += " pid=\"\(pid)\"" }
        if let pindex = objectPIndex { objAttrs += " pindex=\"\(pindex)\"" }
        xml += "<object \(objAttrs)><mesh><vertices>"
        for v in vertices {
            xml += "<vertex x=\"\(v.x)\" y=\"\(v.y)\" z=\"\(v.z)\"/>"
        }
        xml += "</vertices><triangles>"
        for t in triangles {
            var triAttrs = "v1=\"\(t.v1)\" v2=\"\(t.v2)\" v3=\"\(t.v3)\""
            if let pid = t.pid { triAttrs += " pid=\"\(pid)\"" }
            if let p1 = t.p1 { triAttrs += " p1=\"\(p1)\"" }
            if let p2 = t.p2 { triAttrs += " p2=\"\(p2)\"" }
            if let p3 = t.p3 { triAttrs += " p3=\"\(p3)\"" }
            xml += "<triangle \(triAttrs)/>"
        }
        xml += "</triangles></mesh></object></resources>"
        xml += "<build><item objectid=\"2\"/></build></model>"
        return Data(xml.utf8)
    }

    private func makeMultiObjectModelXML(
        objects: [(vertices: [SIMD3<Float>], triangles: [(Int, Int, Int)])]
    ) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<model xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">"
        xml += "<resources>"
        for (idx, obj) in objects.enumerated() {
            xml += "<object id=\"\(idx + 1)\" type=\"model\"><mesh><vertices>"
            for v in obj.vertices {
                xml += "<vertex x=\"\(v.x)\" y=\"\(v.y)\" z=\"\(v.z)\"/>"
            }
            xml += "</vertices><triangles>"
            for t in obj.triangles {
                xml += "<triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>"
            }
            xml += "</triangles></mesh></object>"
        }
        xml += "</resources><build>"
        for (idx, _) in objects.enumerated() {
            xml += "<item objectid=\"\(idx + 1)\"/>"
        }
        xml += "</build></model>"
        return Data(xml.utf8)
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".3mf")
        try data.write(to: url)
        return url
    }

    // MARK: - Tests

    func testParseSimpleTriangle() throws {
        let vertices: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)
        ]
        let triangles: [(Int, Int, Int)] = [(0, 1, 2)]
        let xml = makeModelXML(vertices: vertices, triangles: triangles)
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        XCTAssertEqual(mesh.vertices.count, 3)
        XCTAssertEqual(mesh.triangles.count, 1)
        XCTAssertEqual(mesh.vertices[0], SIMD3(0, 0, 0))
        XCTAssertEqual(mesh.vertices[1], SIMD3(1, 0, 0))
        XCTAssertEqual(mesh.vertices[2], SIMD3(0, 1, 0))
        XCTAssertEqual(mesh.triangles[0].0, 0)
        XCTAssertEqual(mesh.triangles[0].1, 1)
        XCTAssertEqual(mesh.triangles[0].2, 2)
    }

    func testParseCube() throws {
        let vertices: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        let triangles: [(Int, Int, Int)] = [
            (0, 1, 2), (0, 2, 3),
            (4, 6, 5), (4, 7, 6),
            (0, 4, 5), (0, 5, 1),
            (3, 2, 6), (3, 6, 7),
            (0, 3, 7), (0, 7, 4),
            (1, 5, 6), (1, 6, 2),
        ]
        let xml = makeModelXML(vertices: vertices, triangles: triangles)
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        XCTAssertEqual(mesh.vertices.count, 8)
        XCTAssertEqual(mesh.triangles.count, 12)
    }

    func testMultipleObjects() throws {
        // Two objects in a single model file — the parser's XML delegate collects
        // all vertices into one flat array across objects.
        let xml = makeMultiObjectModelXML(objects: [
            (vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
             triangles: [(0, 1, 2)]),
            (vertices: [SIMD3(2, 0, 0), SIMD3(3, 0, 0), SIMD3(2, 1, 0)],
             triangles: [(0, 1, 2)]),
        ])
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        XCTAssertEqual(mesh.vertices.count, 6)
        XCTAssertEqual(mesh.triangles.count, 2)
    }

    func testMultipleModelFiles() throws {
        let xml1 = makeModelXML(
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            triangles: [(0, 1, 2)]
        )
        let xml2 = makeModelXML(
            vertices: [SIMD3(5, 0, 0), SIMD3(6, 0, 0), SIMD3(5, 1, 0), SIMD3(6, 1, 0)],
            triangles: [(0, 1, 2), (1, 3, 2)]
        )
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml1),
            .init(path: "3D/Objects/part.model", data: xml2),
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        XCTAssertEqual(mesh.vertices.count, 7)  // 3 + 4
        XCTAssertEqual(mesh.triangles.count, 3)  // 1 + 2
        // Second file's triangle indices are offset by the first file's vertex count (3)
        XCTAssertEqual(mesh.triangles[1].0, 3)
        XCTAssertEqual(mesh.triangles[1].1, 4)
        XCTAssertEqual(mesh.triangles[1].2, 5)
    }

    func testInvalidArchive() throws {
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        let url = try writeTempFile(garbage)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFParser.parse(fileAt: url)) { error in
            guard let parserError = error as? ThreeMFParserError else {
                return XCTFail("Expected ThreeMFParserError, got \(error)")
            }
            if case .cannotOpenArchive = parserError { /* expected */ } else {
                XCTFail("Expected cannotOpenArchive, got \(parserError)")
            }
        }
    }

    func testMissingModelEntry() throws {
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "readme.txt", data: Data("hello".utf8))
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFParser.parse(fileAt: url)) { error in
            guard let parserError = error as? ThreeMFParserError else {
                return XCTFail("Expected ThreeMFParserError, got \(error)")
            }
            if case .modelEntryNotFound = parserError { /* expected */ } else {
                XCTFail("Expected modelEntryNotFound, got \(parserError)")
            }
        }
    }

    func testEmptyMesh() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        <resources><object id="1" type="model"><mesh>
        <vertices></vertices><triangles></triangles>
        </mesh></object></resources>
        <build><item objectid="1"/></build></model>
        """.utf8)
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFParser.parse(fileAt: url)) { error in
            guard let parserError = error as? ThreeMFParserError else {
                return XCTFail("Expected ThreeMFParserError, got \(error)")
            }
            if case .parsingFailed = parserError { /* expected */ } else {
                XCTFail("Expected parsingFailed, got \(parserError)")
            }
        }
    }

    // MARK: - Color Parsing Tests

    func testParseWithColors() throws {
        let xml = makeColorModelXML(
            colors: ["#FF0000", "#00FF00"],
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            triangles: [(v1: 0, v2: 1, v3: 2, pid: 1, p1: 0, p2: 0, p3: 0)]
        )
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        XCTAssertNotNil(mesh.triangleColors)
        XCTAssertEqual(mesh.triangleColors?.count, 1)

        let (c0, c1, c2) = mesh.triangleColors![0]
        // All three vertices should be red (#FF0000)
        XCTAssertEqual(c0.x, 1.0, accuracy: 1e-3)
        XCTAssertEqual(c0.y, 0.0, accuracy: 1e-3)
        XCTAssertEqual(c0.z, 0.0, accuracy: 1e-3)
        XCTAssertEqual(c1, c0)
        XCTAssertEqual(c2, c0)
    }

    func testParseObjectDefaultColor() throws {
        // Object has pid=1 pindex=1 (green), triangles inherit it
        let xml = makeColorModelXML(
            colors: ["#FF0000", "#00FF00"],
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            triangles: [(v1: 0, v2: 1, v3: 2, pid: nil, p1: nil, p2: nil, p3: nil)],
            objectPID: 1,
            objectPIndex: 1
        )
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        XCTAssertNotNil(mesh.triangleColors)
        let (c0, _, _) = mesh.triangleColors![0]
        // pindex=1 → green
        XCTAssertEqual(c0.x, 0.0, accuracy: 1e-3)
        XCTAssertEqual(c0.y, 1.0, accuracy: 1e-3)
        XCTAssertEqual(c0.z, 0.0, accuracy: 1e-3)
    }

    func testParsePerTriangleColorOverride() throws {
        // Object default is red (pindex=0), but triangle overrides with green (p1=1)
        let xml = makeColorModelXML(
            colors: ["#FF0000", "#00FF00"],
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            triangles: [(v1: 0, v2: 1, v3: 2, pid: 1, p1: 1, p2: 1, p3: 1)],
            objectPID: 1,
            objectPIndex: 0
        )
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        let (c0, c1, c2) = mesh.triangleColors![0]
        // Override: all green
        XCTAssertEqual(c0.x, 0.0, accuracy: 1e-3)
        XCTAssertEqual(c0.y, 1.0, accuracy: 1e-3)
        XCTAssertEqual(c1, c0)
        XCTAssertEqual(c2, c0)
    }

    func testParseVertexColorInterpolation() throws {
        // p1=0 (red), p2=1 (green), p3=2 (blue) — three different colors per vertex
        let xml = makeColorModelXML(
            colors: ["#FF0000", "#00FF00", "#0000FF"],
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            triangles: [(v1: 0, v2: 1, v3: 2, pid: 1, p1: 0, p2: 1, p3: 2)]
        )
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        let (c0, c1, c2) = mesh.triangleColors![0]
        // Vertex 0: red
        XCTAssertEqual(c0.x, 1.0, accuracy: 1e-3)
        XCTAssertEqual(c0.y, 0.0, accuracy: 1e-3)
        XCTAssertEqual(c0.z, 0.0, accuracy: 1e-3)
        // Vertex 1: green
        XCTAssertEqual(c1.x, 0.0, accuracy: 1e-3)
        XCTAssertEqual(c1.y, 1.0, accuracy: 1e-3)
        XCTAssertEqual(c1.z, 0.0, accuracy: 1e-3)
        // Vertex 2: blue
        XCTAssertEqual(c2.x, 0.0, accuracy: 1e-3)
        XCTAssertEqual(c2.y, 0.0, accuracy: 1e-3)
        XCTAssertEqual(c2.z, 1.0, accuracy: 1e-3)
    }

    func testParseNoColorsMeansNil() throws {
        // Standard model without any basematerials → triangleColors should be nil
        let xml = makeModelXML(
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            triangles: [(0, 1, 2)]
        )
        let zip = MiniZIP.createArchive(entries: [
            .init(path: "3D/3dmodel.model", data: xml)
        ])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFParser.parse(fileAt: url)
        XCTAssertNil(mesh.triangleColors)
    }
}
