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
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fileData = try Data(contentsOf: url)
        var patched = fileData
        ThreeMFParser.patchZIP64Sentinels(&patched)

        let archive: Archive
        do {
            archive = try Archive(data: patched, accessMode: .read)
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

    // MARK: - ZIP64 patching

    /// Rewrite ZIP64 sentinel values (0xFFFFFFFF) throughout the archive so that
    /// ZIPFoundation's Data-backed provider can process the file correctly.
    private static func patchZIP64Sentinels(_ data: inout Data) {
        let sentinel32: UInt32 = 0xFFFF_FFFF

        // --- 1. Patch local file headers (PK\x03\x04) ---
        var offset = 0
        while offset + 30 <= data.count {
            guard data[offset] == 0x50, data[offset+1] == 0x4B,
                  data[offset+2] == 0x03, data[offset+3] == 0x04 else { break }

            let compSize  = load32(data, offset + 18)
            let uncompSize = load32(data, offset + 22)
            let nameLen  = Int(load16(data, offset + 26))
            let extraLen = Int(load16(data, offset + 28))
            let extraStart = offset + 30 + nameLen

            if compSize == sentinel32 || uncompSize == sentinel32 {
                patchZIP64Extra(&data, extraStart: extraStart, extraLen: extraLen,
                                compOffset: offset + 18, uncompOffset: offset + 22,
                                localHeaderOffset: nil,
                                needComp: compSize == sentinel32,
                                needUncomp: uncompSize == sentinel32,
                                needLocalOffset: false)
            }

            let patchedCompSize = Int(load32(data, offset + 18))
            offset = extraStart + extraLen + patchedCompSize
        }

        // --- 2. Find EOCD (PK\x05\x06) and patch cd_offset ---
        guard let eocdOffset = findSignature(data, sig: [0x50, 0x4B, 0x05, 0x06]) else { return }
        var cdOffset = Int(load32(data, eocdOffset + 16))

        if cdOffset == Int(sentinel32) {
            // Read real offset from ZIP64 EOCD record (PK\x06\x06)
            if let zip64EOCD = findSignature(data, sig: [0x50, 0x4B, 0x06, 0x06]) {
                let realCDOffset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: zip64EOCD + 48, as: UInt64.self) }
                cdOffset = Int(realCDOffset)
                let patched = UInt32(clamping: min(realCDOffset, UInt64(UInt32.max - 1)))
                store32(&data, eocdOffset + 16, patched)
            }
        }

        // --- 3. Patch central directory entries (PK\x01\x02) ---
        var cdOff = cdOffset
        while cdOff + 46 <= data.count {
            guard data[cdOff] == 0x50, data[cdOff+1] == 0x4B,
                  data[cdOff+2] == 0x01, data[cdOff+3] == 0x02 else { break }

            let cdCompSize   = load32(data, cdOff + 20)
            let cdUncompSize = load32(data, cdOff + 24)
            let cdNameLen    = Int(load16(data, cdOff + 28))
            let cdExtraLen   = Int(load16(data, cdOff + 30))
            let cdCommentLen = Int(load16(data, cdOff + 32))
            let cdLocalOffset = load32(data, cdOff + 42)
            let cdExtraStart = cdOff + 46 + cdNameLen

            if cdCompSize == sentinel32 || cdUncompSize == sentinel32 || cdLocalOffset == sentinel32 {
                patchZIP64Extra(&data, extraStart: cdExtraStart, extraLen: cdExtraLen,
                                compOffset: cdOff + 20, uncompOffset: cdOff + 24,
                                localHeaderOffset: cdOff + 42,
                                needComp: cdCompSize == sentinel32,
                                needUncomp: cdUncompSize == sentinel32,
                                needLocalOffset: cdLocalOffset == sentinel32)
            }

            cdOff += 46 + cdNameLen + cdExtraLen + cdCommentLen
        }
    }

    /// Walk extra fields to find ZIP64 tag (0x0001) and patch sentinel values.
    private static func patchZIP64Extra(
        _ data: inout Data, extraStart: Int, extraLen: Int,
        compOffset: Int, uncompOffset: Int, localHeaderOffset: Int?,
        needComp: Bool, needUncomp: Bool, needLocalOffset: Bool
    ) {
        var eOff = extraStart
        let eEnd = extraStart + extraLen
        while eOff + 4 <= eEnd {
            let tag = load16(data, eOff)
            let sz  = Int(load16(data, eOff + 2))
            if tag == 0x0001 {
                // ZIP64 extra field values appear in order: uncompressed, compressed, local offset
                // but only for fields that were set to 0xFFFFFFFF in the header.
                var pos = eOff + 4
                if needUncomp, pos + 8 <= eOff + 4 + sz {
                    let real = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt64.self) }
                    store32(&data, uncompOffset, UInt32(clamping: min(real, UInt64(UInt32.max - 1))))
                    pos += 8
                }
                if needComp, pos + 8 <= eOff + 4 + sz {
                    let real = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt64.self) }
                    store32(&data, compOffset, UInt32(clamping: min(real, UInt64(UInt32.max - 1))))
                    pos += 8
                }
                if needLocalOffset, let lhOff = localHeaderOffset, pos + 8 <= eOff + 4 + sz {
                    let real = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt64.self) }
                    store32(&data, lhOff, UInt32(clamping: min(real, UInt64(UInt32.max - 1))))
                }
                return
            }
            eOff += 4 + sz
        }
    }

    private static func findSignature(_ data: Data, sig: [UInt8]) -> Int? {
        for i in stride(from: data.count - 4, through: 0, by: -1) {
            if data[i] == sig[0], data[i+1] == sig[1], data[i+2] == sig[2], data[i+3] == sig[3] {
                return i
            }
        }
        return nil
    }

    private static func load16(_ data: Data, _ offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }

    private static func load32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func store32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value) { data.replaceSubrange(offset..<offset+4, with: $0) }
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
