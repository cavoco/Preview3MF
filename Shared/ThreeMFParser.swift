import Foundation
import simd
import ZIPFoundation

struct MeshData {
    var vertices: [SIMD3<Float>]
    var triangles: [(UInt32, UInt32, UInt32)]
    /// Per-triangle vertex colors (one RGBA tuple per triangle, three colors per vertex).
    /// `nil` means no color data — use default gray.
    var triangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?
}

struct BuildItem {
    var mesh: MeshData
    var transform: simd_float4x4
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

    static func parse(fileAt url: URL) throws -> [BuildItem] {
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

        // Parse all model files, collecting objects keyed by id and build items
        var allObjects: [Int: MeshData] = [:]
        var allBuildItems: [(objectID: Int, transform: simd_float4x4)] = []
        let defaultGray = SIMD4<Float>(0.75, 0.75, 0.75, 1.0)

        for entry in modelEntries {
            var xmlData = Data()
            _ = try archive.extract(entry) { chunk in
                xmlData.append(chunk)
            }

            let delegate = ModelXMLDelegate()
            let parser = XMLParser(data: xmlData)
            parser.delegate = delegate
            guard parser.parse() else { continue }

            for (id, obj) in delegate.objects {
                guard !obj.vertices.isEmpty else { continue }
                allObjects[id] = MeshData(
                    vertices: obj.vertices,
                    triangles: obj.triangles,
                    triangleColors: obj.triangleColors
                )
            }

            allBuildItems.append(contentsOf: delegate.buildItems)
        }

        // If no build items were specified, create one per object with identity transform
        if allBuildItems.isEmpty {
            for id in allObjects.keys.sorted() {
                allBuildItems.append((objectID: id, transform: matrix_identity_float4x4))
            }
        }

        // Merge color data across objects: if any object has colors, backfill others with gray
        let anyHasColors = allObjects.values.contains { $0.triangleColors != nil }
        if anyHasColors {
            for id in allObjects.keys {
                if allObjects[id]!.triangleColors == nil {
                    let count = allObjects[id]!.triangles.count
                    allObjects[id]!.triangleColors = Array(
                        repeating: (defaultGray, defaultGray, defaultGray), count: count
                    )
                }
            }
        }

        // Assemble build items with their meshes
        var result: [BuildItem] = []
        var referencedIDs = Set<Int>()

        for item in allBuildItems {
            guard let mesh = allObjects[item.objectID] else { continue }
            result.append(BuildItem(mesh: mesh, transform: item.transform))
            referencedIDs.insert(item.objectID)
        }

        // Include any objects with mesh data not referenced by build items
        // (e.g., component meshes referenced indirectly via <component>)
        for id in allObjects.keys.sorted() where !referencedIDs.contains(id) {
            result.append(BuildItem(mesh: allObjects[id]!, transform: matrix_identity_float4x4))
        }

        guard !result.isEmpty else {
            throw ThreeMFParserError.parsingFailed("No mesh data found in any model file")
        }

        return result
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

/// Parsed data for a single `<object>` element.
struct ParsedObject {
    var vertices: [SIMD3<Float>] = []
    var triangles: [(UInt32, UInt32, UInt32)] = []
    var triangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?
}

final class ModelXMLDelegate: NSObject, XMLParserDelegate {
    /// Objects keyed by their `id` attribute.
    var objects: [Int: ParsedObject] = [:]
    /// Build items parsed from `<build><item>`.
    var buildItems: [(objectID: Int, transform: simd_float4x4)] = []

    // Material groups: keyed by basematerials group id
    private var materialGroups: [Int: [SIMD4<Float>]] = [:]
    private var currentGroupID: Int?
    private var currentGroupColors: [SIMD4<Float>] = []

    // Current object tracking
    private var currentObjectID: Int?
    private var currentVertices: [SIMD3<Float>] = []
    private var currentTriangles: [(UInt32, UInt32, UInt32)] = []
    private var currentTriangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?

    // Object-level default material
    private var objectPID: Int?
    private var objectPIndex: Int?

    private var inBuild = false

    private let defaultGray = SIMD4<Float>(0.75, 0.75, 0.75, 1.0)

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "basematerials":
            if let idStr = attributes["id"], let id = Int(idStr) {
                currentGroupID = id
                currentGroupColors = []
            }

        case "base":
            if let colorStr = attributes["displaycolor"],
               let color = Self.parseDisplayColor(colorStr) {
                currentGroupColors.append(color)
            }

        case "object":
            if let idStr = attributes["id"], let id = Int(idStr) {
                currentObjectID = id
                currentVertices = []
                currentTriangles = []
                currentTriangleColors = nil
            }
            if let pidStr = attributes["pid"], let pid = Int(pidStr) {
                objectPID = pid
            }
            if let pindexStr = attributes["pindex"], let pindex = Int(pindexStr) {
                objectPIndex = pindex
            }

        case "vertex":
            guard
                let xStr = attributes["x"], let x = Float(xStr),
                let yStr = attributes["y"], let y = Float(yStr),
                let zStr = attributes["z"], let z = Float(zStr)
            else { return }
            currentVertices.append(SIMD3<Float>(x, y, z))

        case "triangle":
            guard
                let v1Str = attributes["v1"], let v1 = UInt32(v1Str),
                let v2Str = attributes["v2"], let v2 = UInt32(v2Str),
                let v3Str = attributes["v3"], let v3 = UInt32(v3Str)
            else { return }
            currentTriangles.append((v1, v2, v3))

            // Only track colors if this file has material definitions
            guard !materialGroups.isEmpty else { break }

            // Backfill previous triangles with default gray if this is the first color entry
            if currentTriangleColors == nil {
                currentTriangleColors = Array(repeating: (defaultGray, defaultGray, defaultGray),
                                              count: currentTriangles.count - 1)
            }

            // Resolve colors for this triangle
            let triPID = attributes["pid"].flatMap { Int($0) } ?? objectPID
            let c0: SIMD4<Float>
            let c1: SIMD4<Float>
            let c2: SIMD4<Float>

            if let pid = triPID, let group = materialGroups[pid] {
                let p1 = attributes["p1"].flatMap { Int($0) } ?? objectPIndex
                let p2 = attributes["p2"].flatMap { Int($0) } ?? p1
                let p3 = attributes["p3"].flatMap { Int($0) } ?? p1

                c0 = (p1 != nil && p1! < group.count) ? group[p1!] : defaultGray
                c1 = (p2 != nil && p2! < group.count) ? group[p2!] : defaultGray
                c2 = (p3 != nil && p3! < group.count) ? group[p3!] : defaultGray
            } else {
                c0 = defaultGray
                c1 = defaultGray
                c2 = defaultGray
            }

            currentTriangleColors!.append((c0, c1, c2))

        case "build":
            inBuild = true

        case "item":
            guard inBuild,
                  let idStr = attributes["objectid"],
                  let objectID = Int(idStr)
            else { break }

            let transform: simd_float4x4
            if let transformStr = attributes["transform"] {
                transform = Self.parseTransform(transformStr)
            } else {
                transform = matrix_identity_float4x4
            }
            buildItems.append((objectID: objectID, transform: transform))

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "basematerials":
            if let id = currentGroupID {
                materialGroups[id] = currentGroupColors
            }
            currentGroupID = nil
            currentGroupColors = []

        case "object":
            if let id = currentObjectID {
                objects[id] = ParsedObject(
                    vertices: currentVertices,
                    triangles: currentTriangles,
                    triangleColors: currentTriangleColors
                )
            }
            currentObjectID = nil
            currentVertices = []
            currentTriangles = []
            currentTriangleColors = nil
            objectPID = nil
            objectPIndex = nil

        case "build":
            inBuild = false

        default:
            break
        }
    }

    /// Parse a 3MF `transform` attribute (12 space-separated floats) into a 4x4 matrix.
    /// Format: "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32"
    /// Maps to the affine matrix:
    /// | m00 m01 m02 0 |
    /// | m10 m11 m12 0 |
    /// | m20 m21 m22 0 |
    /// | m30 m31 m32 1 |
    static func parseTransform(_ str: String) -> simd_float4x4 {
        let values = str.split(separator: " ").compactMap { Float($0) }
        guard values.count == 12 else { return matrix_identity_float4x4 }

        return simd_float4x4(
            SIMD4(values[0], values[3], values[6], values[9]),   // column 0
            SIMD4(values[1], values[4], values[7], values[10]),  // column 1
            SIMD4(values[2], values[5], values[8], values[11]),  // column 2
            SIMD4(0, 0, 0, 1)                                    // column 3
        )
    }

    /// Parse a `#RRGGBB` or `#RRGGBBAA` hex color string into RGBA floats.
    static func parseDisplayColor(_ hex: String) -> SIMD4<Float>? {
        var str = hex
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6 || str.count == 8 else { return nil }
        guard let value = UInt64(str, radix: 16) else { return nil }

        if str.count == 6 {
            let r = Float((value >> 16) & 0xFF) / 255.0
            let g = Float((value >> 8) & 0xFF) / 255.0
            let b = Float(value & 0xFF) / 255.0
            return SIMD4(r, g, b, 1.0)
        } else {
            let r = Float((value >> 24) & 0xFF) / 255.0
            let g = Float((value >> 16) & 0xFF) / 255.0
            let b = Float((value >> 8) & 0xFF) / 255.0
            let a = Float(value & 0xFF) / 255.0
            return SIMD4(r, g, b, a)
        }
    }
}
