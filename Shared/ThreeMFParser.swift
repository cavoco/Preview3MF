import Foundation
import simd
import ZIPFoundation

struct MeshData {
    var vertices: [SIMD3<Float>]
    var triangles: [(UInt32, UInt32, UInt32)]
}

enum ThreeMFParserError: Error, LocalizedError {
    case cannotOpenArchive
    case modelEntryNotFound
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive:
            return "Cannot open .3mf archive"
        case .modelEntryNotFound:
            return "3D/3dmodel.model not found in archive"
        case .parsingFailed(let reason):
            return "XML parsing failed: \(reason)"
        }
    }
}

final class ThreeMFParser {

    static func parse(fileAt url: URL) throws -> MeshData {
        // Read file data first — works in sandboxed contexts where fopen would fail
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fileData = try Data(contentsOf: url)

        let archive: Archive
        do {
            archive = try Archive(data: fileData, accessMode: .read)
        } catch {
            throw ThreeMFParserError.cannotOpenArchive
        }

        // Collect all .model entries — mesh may be in 3D/3dmodel.model or 3D/Objects/*.model
        var modelEntries: [Entry] = []
        for entry in archive {
            if entry.path.hasSuffix(".model") && entry.type == .file {
                modelEntries.append(entry)
            }
        }
        guard !modelEntries.isEmpty else {
            throw ThreeMFParserError.modelEntryNotFound
        }

        // Parse all model files, merging vertices/triangles per-object to keep indices correct
        var allVertices: [SIMD3<Float>] = []
        var allTriangles: [(UInt32, UInt32, UInt32)] = []

        for entry in modelEntries {
            var xmlData = Data()
            _ = try archive.extract(entry) { chunk in
                xmlData.append(chunk)
            }

            let delegate = ModelXMLDelegate()
            let parser = XMLParser(data: xmlData)
            parser.delegate = delegate
            guard parser.parse() else { continue }

            guard !delegate.vertices.isEmpty else { continue }

            // Offset triangle indices by the current vertex count
            let vertexOffset = UInt32(allVertices.count)
            allVertices.append(contentsOf: delegate.vertices)
            for tri in delegate.triangles {
                allTriangles.append((tri.0 + vertexOffset, tri.1 + vertexOffset, tri.2 + vertexOffset))
            }
        }

        guard !allVertices.isEmpty else {
            throw ThreeMFParserError.parsingFailed("No mesh data found in any model file")
        }

        return MeshData(vertices: allVertices, triangles: allTriangles)
    }
}

// MARK: - XML Parsing

private final class ModelXMLDelegate: NSObject, XMLParserDelegate {
    var vertices: [SIMD3<Float>] = []
    var triangles: [(UInt32, UInt32, UInt32)] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "vertex":
            guard
                let xStr = attributes["x"], let x = Float(xStr),
                let yStr = attributes["y"], let y = Float(yStr),
                let zStr = attributes["z"], let z = Float(zStr)
            else { return }
            vertices.append(SIMD3<Float>(x, y, z))

        case "triangle":
            guard
                let v1Str = attributes["v1"], let v1 = UInt32(v1Str),
                let v2Str = attributes["v2"], let v2 = UInt32(v2Str),
                let v3Str = attributes["v3"], let v3 = UInt32(v3Str)
            else { return }
            triangles.append((v1, v2, v3))

        default:
            break
        }
    }
}
