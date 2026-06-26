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

struct ModelMetadata {
    var title: String?
    var designer: String?
    var description: String?
    var copyright: String?
    var application: String?
}

struct ParseResult {
    var items: [BuildItem]
    var metadata: ModelMetadata

    var totalTriangles: Int {
        items.reduce(0) { $0 + $1.mesh.triangles.count }
    }

    var totalVertices: Int {
        items.reduce(0) { $0 + $1.mesh.vertices.count }
    }

    var objectCount: Int {
        items.count
    }

    var hasColors: Bool {
        items.contains { $0.mesh.triangleColors != nil }
    }

    /// Bounding box dimensions in model units (mm), accounting for transforms.
    var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard !items.isEmpty else { return nil }
        var bbMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bbMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for item in items {
            for vertex in item.mesh.vertices {
                let v = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                let transformed = item.transform * v
                let p = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
                bbMin = simd_min(bbMin, p)
                bbMax = simd_max(bbMax, p)
            }
        }
        return (bbMin, bbMax)
    }

    var dimensions: SIMD3<Float>? {
        guard let bb = boundingBox else { return nil }
        return bb.max - bb.min
    }
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

    static func parse(fileAt url: URL) throws -> ParseResult {
        let archive = try openArchive(fileAt: url)

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
        var allComponents: [Int: [(objectID: Int, transform: simd_float4x4)]] = [:]
        var allBuildItems: [(objectID: Int, transform: simd_float4x4)] = []
        var metadata = ModelMetadata()
        let defaultGray = SIMD4<Float>(0.75, 0.75, 0.75, 1.0)

        for entry in modelEntries {
            var xmlData = Data()
            _ = try archive.extract(entry) { chunk in
                xmlData.append(chunk)
            }

            let delegate = FastModelParser()
            guard delegate.parse(xmlData) else { continue }

            for (id, obj) in delegate.objects {
                if !obj.vertices.isEmpty {
                    allObjects[id] = MeshData(
                        vertices: obj.vertices,
                        triangles: obj.triangles,
                        triangleColors: obj.triangleColors
                    )
                }
                // Retain assembly containers even though they carry no mesh of their own.
                if !obj.components.isEmpty {
                    allComponents[id] = obj.components
                }
            }

            allBuildItems.append(contentsOf: delegate.buildItems)

            // Merge metadata (first non-nil value wins)
            if metadata.title == nil { metadata.title = delegate.metadata["Title"] }
            if metadata.designer == nil { metadata.designer = delegate.metadata["Designer"] }
            if metadata.description == nil { metadata.description = delegate.metadata["Description"] }
            if metadata.copyright == nil { metadata.copyright = delegate.metadata["Copyright"] }
            if metadata.application == nil { metadata.application = delegate.metadata["Application"] }
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

        // Objects referenced by a <component> are assembly parts, not standalone roots.
        let componentChildIDs = Set(allComponents.values.flatMap { $0.map { $0.objectID } })

        // If no build items were specified, render every top-level object — i.e. one
        // that isn't itself a component of another object — with an identity transform.
        if allBuildItems.isEmpty {
            let rootIDs = Set(allObjects.keys).union(allComponents.keys).subtracting(componentChildIDs)
            for id in rootIDs.sorted() {
                allBuildItems.append((objectID: id, transform: matrix_identity_float4x4))
            }
        }

        // Flatten an object into (mesh, world-transform) pairs, following <component>
        // references. `visited` breaks reference cycles in malformed files.
        func expand(_ objectID: Int, _ transform: simd_float4x4, _ visited: Set<Int>) -> [BuildItem] {
            guard !visited.contains(objectID), visited.count < 64 else { return [] }
            var out: [BuildItem] = []
            if let mesh = allObjects[objectID] {
                out.append(BuildItem(mesh: mesh, transform: transform))
            }
            if let components = allComponents[objectID] {
                var nextVisited = visited
                nextVisited.insert(objectID)
                for component in components {
                    // Column-vector nesting: world = parent · component (parent on the left).
                    out += expand(component.objectID, transform * component.transform, nextVisited)
                }
            }
            return out
        }

        var result: [BuildItem] = []
        for item in allBuildItems {
            result += expand(item.objectID, item.transform, [])
        }

        // Safety net: render any mesh reached by neither a build item nor a component.
        let buildItemIDs = Set(allBuildItems.map { $0.objectID })
        for id in allObjects.keys.sorted()
        where !buildItemIDs.contains(id) && !componentChildIDs.contains(id) {
            result.append(BuildItem(mesh: allObjects[id]!, transform: matrix_identity_float4x4))
        }

        guard !result.isEmpty else {
            throw ThreeMFParserError.parsingFailed("No mesh data found in any model file")
        }

        return ParseResult(items: result, metadata: metadata)
    }

    /// Extract a pre-rendered preview image embedded in the .3mf archive without parsing geometry.
    ///
    /// Slicers (Bambu Studio, OrcaSlicer, PrusaSlicer) bake a rendered PNG into the package.
    /// This is much cheaper than parsing the mesh and rendering with SceneKit, and at thumbnail
    /// sizes the slicer's render is typically nicer than what we can produce ourselves.
    ///
    /// Lookup order: OPC relationship (`_rels/.rels`) first, then known slicer paths.
    /// Returns the raw image bytes (typically PNG), or nil if no embedded thumbnail is present.
    static func extractEmbeddedThumbnail(fileAt url: URL) throws -> Data? {
        let archive = try openArchive(fileAt: url)

        var candidates: [String] = []
        if let target = thumbnailTargetFromRelationships(in: archive) {
            candidates.append(target)
        }
        // Bambu/Orca high-quality plate render comes first — bigger and prettier than the
        // OPC thumbnail when both exist.
        candidates.append(contentsOf: [
            "Metadata/plate_1.png",
            "Metadata/thumbnail.png",
            "Metadata/plate_no_light_1.png",
            "Metadata/top_1.png",
        ])

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            guard let entry = archive[path], entry.type == .file else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                continue
            }
            if !data.isEmpty { return data }
        }
        return nil
    }

    private static func openArchive(fileAt url: URL) throws -> Archive {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fileData = try Data(contentsOf: url)
        var patched = fileData
        ThreeMFParser.patchZIP64Sentinels(&patched)

        do {
            return try Archive(data: patched, accessMode: .read)
        } catch {
            throw ThreeMFParserError.cannotOpenArchive
        }
    }

    private static func thumbnailTargetFromRelationships(in archive: Archive) -> String? {
        guard let entry = archive["_rels/.rels"], entry.type == .file else { return nil }
        var data = Data()
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch {
            return nil
        }
        guard !data.isEmpty else { return nil }

        let delegate = RelationshipsXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.thumbnailTarget
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
                let realCDOffset = load64(data, zip64EOCD + 48)
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
                    let real = load64(data, pos)
                    store32(&data, uncompOffset, UInt32(clamping: min(real, UInt64(UInt32.max - 1))))
                    pos += 8
                }
                if needComp, pos + 8 <= eOff + 4 + sz {
                    let real = load64(data, pos)
                    store32(&data, compOffset, UInt32(clamping: min(real, UInt64(UInt32.max - 1))))
                    pos += 8
                }
                if needLocalOffset, let lhOff = localHeaderOffset, pos + 8 <= eOff + 4 + sz {
                    let real = load64(data, pos)
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

    // Bounds-checked readers/writer: a corrupt or truncated archive can produce
    // offsets past the end of `data`, and an unchecked loadUnaligned there would
    // crash the (already sandboxed) Quick Look extension. Out-of-range reads
    // return 0 and out-of-range writes are dropped, leaving the sentinel in place
    // so the archive simply fails to open instead of taking the process down.
    private static func load16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }

    private static func load32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func load64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    }

    private static func store32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        withUnsafeBytes(of: value) { data.replaceSubrange(offset..<offset+4, with: $0) }
    }
}

// MARK: - XML Parsing

/// Parsed data for a single `<object>` element.
///
/// An object is either a `<mesh>` (vertices/triangles) or a `<components>`
/// container that references other objects by id with a transform — slicers use
/// the latter for assemblies. Both can be empty; `components` drives expansion.
struct ParsedObject {
    var vertices: [SIMD3<Float>] = []
    var triangles: [(UInt32, UInt32, UInt32)] = []
    var triangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?
    var components: [(objectID: Int, transform: simd_float4x4)] = []
}

final class ModelXMLDelegate: NSObject, XMLParserDelegate {
    /// Objects keyed by their `id` attribute.
    var objects: [Int: ParsedObject] = [:]
    /// Build items parsed from `<build><item>`.
    var buildItems: [(objectID: Int, transform: simd_float4x4)] = []
    /// Metadata entries keyed by name (e.g. "Title", "Designer").
    var metadata: [String: String] = [:]

    // Material groups: keyed by basematerials group id
    private var materialGroups: [Int: [SIMD4<Float>]] = [:]
    private var currentGroupID: Int?
    private var currentGroupColors: [SIMD4<Float>] = []

    // Current object tracking
    private var currentObjectID: Int?
    private var currentVertices: [SIMD3<Float>] = []
    private var currentTriangles: [(UInt32, UInt32, UInt32)] = []
    private var currentTriangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?
    private var currentComponents: [(objectID: Int, transform: simd_float4x4)] = []

    // Object-level default material
    private var objectPID: Int?
    private var objectPIndex: Int?

    // Metadata tracking
    private var currentMetadataName: String?
    private var currentMetadataText: String?

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
                currentComponents = []
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

        case "component":
            // A reference, inside an object's <components>, to another object by id.
            guard currentObjectID != nil,
                  let idStr = attributes["objectid"],
                  let objectID = Int(idStr)
            else { break }
            let transform = attributes["transform"].map(Self.parseTransform) ?? matrix_identity_float4x4
            currentComponents.append((objectID: objectID, transform: transform))

        case "metadata":
            if let name = attributes["name"] {
                currentMetadataName = name
                currentMetadataText = ""
            }

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
                    triangleColors: currentTriangleColors,
                    components: currentComponents
                )
            }
            currentObjectID = nil
            currentVertices = []
            currentTriangles = []
            currentTriangleColors = nil
            currentComponents = []
            objectPID = nil
            objectPIndex = nil

        case "metadata":
            if let name = currentMetadataName,
               let text = currentMetadataText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                metadata[name] = text
            }
            currentMetadataName = nil
            currentMetadataText = nil

        case "build":
            inBuild = false

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentMetadataName != nil {
            currentMetadataText?.append(string)
        }
    }

    /// Parse a 3MF `transform` attribute (12 space-separated floats) into a 4x4 matrix.
    /// Format: "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32".
    ///
    /// 3MF uses a row-vector convention — a point is transformed as `p · M`, so the
    /// translation lives in the bottom row (m30 m31 m32). SceneKit's `simdTransform`
    /// is column-major and applies `M · p`, with translation in the last column.
    /// We therefore transpose into:
    /// | m00 m10 m20 m30 |
    /// | m01 m11 m21 m31 |
    /// | m02 m12 m22 m32 |
    /// |  0   0   0   1  |
    /// so the matrix can be assigned directly to a node's transform.
    static func parseTransform(_ str: String) -> simd_float4x4 {
        let values = str.split(separator: " ").compactMap { Float($0) }
        guard values.count == 12 else { return matrix_identity_float4x4 }

        return simd_float4x4(
            SIMD4(values[0], values[1], values[2], 0),       // column 0
            SIMD4(values[3], values[4], values[5], 0),       // column 1
            SIMD4(values[6], values[7], values[8], 0),       // column 2
            SIMD4(values[9], values[10], values[11], 1)      // column 3 (translation)
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

/// A hand-written scanner for 3MF `<model>` XML that produces the same output as
/// `ModelXMLDelegate` but far faster on large files.
///
/// Foundation's `XMLParser` builds a bridged `[String: String]` attribute dictionary
/// for every element; with millions of `<vertex>`/`<triangle>` elements that allocation
/// dominates parse time. This walks the raw UTF-8 bytes and reads numbers directly with
/// `strtod`/`strtol`, allocating nothing per element. (3MF always uses `.` as the decimal
/// separator, matching the process's default C numeric locale.)
final class FastModelParser {
    var objects: [Int: ParsedObject] = [:]
    var buildItems: [(objectID: Int, transform: simd_float4x4)] = []
    var metadata: [String: String] = [:]

    private var materialGroups: [Int: [SIMD4<Float>]] = [:]
    private var currentGroupID: Int?
    private var currentGroupColors: [SIMD4<Float>] = []

    private var currentObjectID: Int?
    private var currentVertices: [SIMD3<Float>] = []
    private var currentTriangles: [(UInt32, UInt32, UInt32)] = []
    private var currentTriangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?
    private var currentComponents: [(objectID: Int, transform: simd_float4x4)] = []
    private var objectPID: Int?
    private var objectPIndex: Int?
    private var inBuild = false

    private let defaultGray = SIMD4<Float>(0.75, 0.75, 0.75, 1.0)

    func parse(_ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            let n = bytes.count

            let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
            let quote = UInt8(ascii: "\""), eq = UInt8(ascii: "=")
            @inline(__always) func isSpace(_ b: UInt8) -> Bool {
                b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
            }
            @inline(__always) func f(_ vs: Int) -> Float { Float(strtod(base + vs, nil)) }
            @inline(__always) func d(_ vs: Int) -> Int { strtol(base + vs, nil, 10) }
            @inline(__always) func nameIs(_ ns: Int, _ nl: Int, _ s: StaticString) -> Bool {
                guard nl == s.utf8CodeUnitCount else { return false }
                let p = s.utf8Start
                var k = 0
                while k < nl { if bytes[ns + k] != p[k] { return false }; k += 1 }
                return true
            }

            // Visit each `name="value"` in the attribute region [start, end).
            @inline(__always) func forEachAttr(_ start: Int, _ end: Int, _ body: (Int, Int, Int) -> Void) {
                var p = start
                while p < end {
                    while p < end, isSpace(bytes[p]) { p += 1 }
                    if p >= end || bytes[p] == slash || bytes[p] == gt { break }
                    let ns = p
                    while p < end, bytes[p] != eq, !isSpace(bytes[p]) { p += 1 }
                    let nl = p - ns
                    while p < end, bytes[p] != quote { p += 1 }
                    if p >= end { break }
                    p += 1
                    let vs = p
                    while p < end, bytes[p] != quote { p += 1 }
                    body(ns, nl, vs)
                    p += 1
                }
            }
            @inline(__always) func str(_ vs: Int, _ ve: Int) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: bytes[vs..<ve]), as: UTF8.self)
            }
            @inline(__always) func valueEnd(_ vs: Int) -> Int {
                var e = vs; while e < n, bytes[e] != quote { e += 1 }; return e
            }

            var i = 0
            var metaName: String?
            var metaTextStart = 0

            while i < n {
                if bytes[i] != lt { i += 1; continue }
                let after = i + 1
                if after >= n { break }
                let c0 = bytes[after]
                if c0 == UInt8(ascii: "!") || c0 == UInt8(ascii: "?") {
                    var k = after; while k < n, bytes[k] != gt { k += 1 }; i = k + 1; continue
                }
                let isClose = c0 == slash
                let ns = isClose ? after + 1 : after
                var j = ns
                while j < n {
                    let b = bytes[j]
                    if b == gt || b == slash || isSpace(b) { break }
                    j += 1
                }
                let nl = j - ns
                var k = j
                while k < n, bytes[k] != gt { k += 1 }   // k at '>'
                let attrEnd = k

                if isClose {
                    if nameIs(ns, nl, "object") {
                        if let id = currentObjectID {
                            objects[id] = ParsedObject(vertices: currentVertices,
                                                       triangles: currentTriangles,
                                                       triangleColors: currentTriangleColors,
                                                       components: currentComponents)
                        }
                        currentObjectID = nil; currentVertices = []; currentTriangles = []
                        currentTriangleColors = nil; currentComponents = []
                        objectPID = nil; objectPIndex = nil
                    } else if nameIs(ns, nl, "basematerials") {
                        if let id = currentGroupID { materialGroups[id] = currentGroupColors }
                        currentGroupID = nil; currentGroupColors = []
                    } else if nameIs(ns, nl, "metadata") {
                        if let name = metaName {
                            let text = str(metaTextStart, i).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { metadata[name] = Self.decodeEntities(text) }
                        }
                        metaName = nil
                    } else if nameIs(ns, nl, "build") {
                        inBuild = false
                    }
                    i = k + 1
                    continue
                }

                if nameIs(ns, nl, "vertex") {
                    var x: Float = 0, y: Float = 0, z: Float = 0
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if al == 1 {
                            switch bytes[an] {
                            case 0x78: x = f(vs); case 0x79: y = f(vs); case 0x7A: z = f(vs)
                            default: break
                            }
                        }
                    }
                    currentVertices.append(SIMD3(x, y, z))
                } else if nameIs(ns, nl, "triangle") {
                    var v1 = -1, v2 = -1, v3 = -1
                    var pid: Int? = nil, p1: Int? = nil, p2: Int? = nil, p3: Int? = nil
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if al == 2, bytes[an] == 0x76 {           // v1/v2/v3
                            switch bytes[an + 1] { case 0x31: v1 = d(vs); case 0x32: v2 = d(vs); case 0x33: v3 = d(vs); default: break }
                        } else if al == 2, bytes[an] == 0x70 {    // p1/p2/p3
                            switch bytes[an + 1] { case 0x31: p1 = d(vs); case 0x32: p2 = d(vs); case 0x33: p3 = d(vs); default: break }
                        } else if al == 3, nameIs(an, al, "pid") {
                            pid = d(vs)
                        }
                    }
                    if v1 >= 0, v2 >= 0, v3 >= 0 {
                        currentTriangles.append((UInt32(v1), UInt32(v2), UInt32(v3)))
                        if !materialGroups.isEmpty {
                            if currentTriangleColors == nil {
                                currentTriangleColors = Array(repeating: (defaultGray, defaultGray, defaultGray),
                                                              count: currentTriangles.count - 1)
                            }
                            let triPID = pid ?? objectPID
                            var c0 = defaultGray, c1 = defaultGray, c2 = defaultGray
                            if let pid = triPID, let group = materialGroups[pid] {
                                let i1 = p1 ?? objectPIndex
                                let i2 = p2 ?? i1
                                let i3 = p3 ?? i1
                                if let idx = i1, idx >= 0, idx < group.count { c0 = group[idx] }
                                if let idx = i2, idx >= 0, idx < group.count { c1 = group[idx] }
                                if let idx = i3, idx >= 0, idx < group.count { c2 = group[idx] }
                            }
                            currentTriangleColors!.append((c0, c1, c2))
                        }
                    }
                } else if nameIs(ns, nl, "object") {
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "id") { currentObjectID = d(vs) }
                        else if nameIs(an, al, "pid") { objectPID = d(vs) }
                        else if nameIs(an, al, "pindex") { objectPIndex = d(vs) }
                    }
                    currentVertices = []; currentTriangles = []; currentTriangleColors = nil; currentComponents = []
                } else if nameIs(ns, nl, "component") {
                    if currentObjectID != nil {
                        var objectID: Int? = nil
                        var transform = matrix_identity_float4x4
                        forEachAttr(j, attrEnd) { an, al, vs in
                            if nameIs(an, al, "objectid") { objectID = d(vs) }
                            else if nameIs(an, al, "transform") { transform = ModelXMLDelegate.parseTransform(str(vs, valueEnd(vs))) }
                        }
                        if let objectID { currentComponents.append((objectID: objectID, transform: transform)) }
                    }
                } else if nameIs(ns, nl, "item") {
                    if inBuild {
                        var objectID: Int? = nil
                        var transform = matrix_identity_float4x4
                        forEachAttr(j, attrEnd) { an, al, vs in
                            if nameIs(an, al, "objectid") { objectID = d(vs) }
                            else if nameIs(an, al, "transform") { transform = ModelXMLDelegate.parseTransform(str(vs, valueEnd(vs))) }
                        }
                        if let objectID { buildItems.append((objectID: objectID, transform: transform)) }
                    }
                } else if nameIs(ns, nl, "build") {
                    inBuild = true
                } else if nameIs(ns, nl, "base") {
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "displaycolor"),
                           let color = ModelXMLDelegate.parseDisplayColor(str(vs, valueEnd(vs))) {
                            currentGroupColors.append(color)
                        }
                    }
                } else if nameIs(ns, nl, "basematerials") {
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "id") { currentGroupID = d(vs); currentGroupColors = [] }
                    }
                } else if nameIs(ns, nl, "metadata") {
                    var name: String?
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "name") { name = str(vs, valueEnd(vs)) }
                    }
                    // Self-closing (<metadata .../>) carries no text.
                    if attrEnd > j, bytes[attrEnd - 1] != slash { metaName = name; metaTextStart = k + 1 }
                }

                i = k + 1
            }
        }
        return true
    }

    /// Minimal XML entity decode for metadata text (not in the hot path).
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var r = s
        for (e, c) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                       ("&apos;", "'"), ("&#34;", "\""), ("&#39;", "'")] {
            r = r.replacingOccurrences(of: e, with: c)
        }
        return r
    }
}

/// Parses an OPC `_rels/.rels` file looking for the package-level thumbnail relationship.
final class RelationshipsXMLDelegate: NSObject, XMLParserDelegate {
    var thumbnailTarget: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        guard elementName == "Relationship" else { return }
        guard let type = attributes["Type"], type.hasSuffix("/thumbnail") else { return }
        guard var target = attributes["Target"] else { return }
        if target.hasPrefix("/") { target.removeFirst() }
        thumbnailTarget = target
    }
}
