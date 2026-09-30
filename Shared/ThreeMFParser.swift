import Foundation
import simd
import ZIPFoundation

struct MeshData {
    var vertices: [SIMD3<Float>]
    var triangles: [(UInt32, UInt32, UInt32)]
    /// Per-triangle vertex colors (one RGBA tuple per triangle, three colors per vertex).
    /// `nil` means no color data — use default gray.
    var triangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?
    /// One colour for the whole mesh, used when `triangleColors` is nil. Slicer filament
    /// colours arrive this way, and spelling one out per triangle cost 48 bytes a triangle —
    /// 180 MB for a 3.8M-triangle plate.
    var uniformColor: SIMD4<Float>? = nil

    var hasColors: Bool { triangleColors != nil || uniformColor != nil }

    /// The colours of triangle `index`'s three vertices, or nil for an uncoloured mesh.
    func colors(ofTriangle index: Int) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)? {
        if let triangleColors { return triangleColors[index] }
        return uniformColor.map { ($0, $0, $0) }
    }
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

/// One build plate's worth of geometry, ready to render.
struct PlateContents {
    /// The name given in the slicer, when the user set one ("Coin Lid").
    var name: String?
    var items: [BuildItem]
    /// Print time and filament weight, once the plate has been sliced.
    var estimate: SliceEstimate?
    /// Package paths of the model files holding this plate's geometry, sorted — the root
    /// model plus whichever `3D/Objects/*.model` files its objects reference.
    var modelPaths: [String] = []
    /// False until the plate's model files are parsed; `items` stays empty until then.
    /// Only the plate on screen is kept loaded in a multi-file slicer project.
    var isLoaded = true
    /// Whether the plate has anything to show. Exact once loaded; before that, a plate that
    /// places anything at all counts, so paging doesn't skip over it.
    var hasGeometry: Bool
}

struct ParseResult {
    /// Geometry for the plate currently being shown — or everything, for a file that has
    /// no plates.
    var items: [BuildItem]
    var metadata: ModelMetadata
    /// Every plate in the project, in slicer order. Empty when the file is not a
    /// multi-plate slicer project.
    var plates: [PlateContents] = []
    /// Index into `plates` that `items` came from.
    var plateIndex: Int?
    /// The slicer print profile, for Bambu Studio / OrcaSlicer projects.
    var printSettings: PrintSettings?
    /// The slicer's estimate for the plate being shown, if it has been sliced.
    var sliceEstimate: SliceEstimate?
    /// The open package, kept for parsing plates that aren't loaded yet. Nil when every
    /// plate was loaded up front.
    var package: ThreeMFPackage?

    var plateCount: Int { plates.count }

    /// The same result showing a different plate, parsing that plate's model files first
    /// if they aren't loaded — which can take seconds for a big plate, so call this off the
    /// main thread. It may unload other plates, so page onward from the returned result.
    /// Returns nil for an out-of-range index.
    func loadingPlate(_ index: Int) throws -> ParseResult? {
        guard plates.indices.contains(index) else { return nil }
        guard !plates[index].isLoaded, let package else { return showingPlate(index) }
        return try package.result(showingPlate: index)
    }

    /// The same result showing a different, already loaded plate. Returns nil for an
    /// out-of-range index, so callers can wrap or clamp as they prefer.
    func showingPlate(_ index: Int) -> ParseResult? {
        guard plates.indices.contains(index) else { return nil }
        var copy = self
        copy.items = plates[index].items
        copy.plateIndex = index
        copy.sliceEstimate = plates[index].estimate
        return copy
    }

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
        items.contains { $0.mesh.hasColors }
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

    /// Parses a package for display. A multi-file slicer project only has its first
    /// populated plate parsed; the rest load on demand through `ParseResult.loadingPlate`.
    static func parse(fileAt url: URL) throws -> ParseResult {
        try ThreeMFPackage(fileAt: url).firstResult()
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

    fileprivate static func openArchive(fileAt url: URL) throws -> Archive {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // Mapped, not read: checking for ZIP64 sentinels touches only the headers' pages.
        // The mapping is read-only, so it must never be patched in place.
        var mapped = try Data(contentsOf: url, options: .alwaysMapped)
        do {
            if ThreeMFParser.patchZIP64Sentinels(&mapped, checkOnly: true) {
                var data = mapped.withUnsafeBytes { Data($0) }
                ThreeMFParser.patchZIP64Sentinels(&data)
                return try Archive(data: data, accessMode: .read)
            }
            // Nothing to patch: read from disk as needed, so the package isn't held in
            // memory for as long as it is previewed.
            return try Archive(url: url, accessMode: .read)
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
    /// ZIPFoundation's Data-backed provider can process the file correctly. Returns whether
    /// anything needed rewriting; with `checkOnly`, stops at the first such value without
    /// writing, so it is safe on a read-only mapping.
    @discardableResult
    private static func patchZIP64Sentinels(_ data: inout Data, checkOnly: Bool = false) -> Bool {
        let sentinel32: UInt32 = 0xFFFF_FFFF
        var patchedAny = false

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
                if checkOnly { return true }
                patchedAny = true
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
        guard let eocdOffset = findSignature(data, sig: [0x50, 0x4B, 0x05, 0x06]) else { return patchedAny }
        var cdOffset = Int(load32(data, eocdOffset + 16))

        if cdOffset == Int(sentinel32) {
            // Read real offset from ZIP64 EOCD record (PK\x06\x06)
            if let zip64EOCD = findSignature(data, sig: [0x50, 0x4B, 0x06, 0x06]) {
                if checkOnly { return true }
                let realCDOffset = load64(data, zip64EOCD + 48)
                cdOffset = Int(realCDOffset)
                let patched = UInt32(clamping: min(realCDOffset, UInt64(UInt32.max - 1)))
                store32(&data, eocdOffset + 16, patched)
                patchedAny = true
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
                if checkOnly { return true }
                patchedAny = true
                patchZIP64Extra(&data, extraStart: cdExtraStart, extraLen: cdExtraLen,
                                compOffset: cdOff + 20, uncompOffset: cdOff + 24,
                                localHeaderOffset: cdOff + 42,
                                needComp: cdCompSize == sentinel32,
                                needUncomp: cdUncompSize == sentinel32,
                                needLocalOffset: cdLocalOffset == sentinel32)
            }

            cdOff += 46 + cdNameLen + cdExtraLen + cdCommentLen
        }
        return patchedAny
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

    // MARK: - Metadata sanitisation

    /// Cleans a raw metadata value to plain text, returning nil if nothing is left.
    static func cleanMetadata(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = sanitizeMetadataText(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Strips HTML tags and decodes entities (including double-encoded ones like
    /// `&amp;#39;`) so slicer descriptions read as plain text.
    static func sanitizeMetadataText(_ raw: String) -> String {
        var text = raw

        // Turn line/paragraph breaks into newlines before removing the rest of the markup.
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</P>", "</div>", "</li>"] {
            text = text.replacingOccurrences(of: tag, with: "\n")
        }
        // Remove any remaining tags.
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode entities, repeating to unwind double-encoding (e.g. "&amp;#39;" -> "'").
        for _ in 0..<3 {
            let decoded = decodeHTMLEntities(text)
            if decoded == text { break }
            text = decoded
        }

        // Collapse whitespace: runs of spaces/tabs to one space, blank lines to one break.
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n[ \\n]*", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes the common named entities plus numeric (`&#39;`) and hex (`&#x27;`) forms.
    private static func decodeHTMLEntities(_ s: String) -> String {
        var result = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return decodeNumericEntities(result)
    }

    /// Replaces `&#nnn;` / `&#xhhh;` character references with their Unicode scalars.
    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let isHex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result += String(scalar)
            } else {
                result += ns.substring(with: match.range)   // leave invalid refs untouched
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

// MARK: - XML Parsing

/// An open .3mf package that parses model files on demand.
///
/// Bambu Studio and OrcaSlicer keep each object's geometry in a file of its own under
/// `3D/Objects/`, and only one plate is on screen at a time. So only the root model and the
/// shown plate's files are parsed; paging parses the next plate's and drops the last's.
/// Memory then follows the plate on screen rather than the whole project, which matters in
/// Quick Look, where an extension over its memory limit is killed and the preview is blank.
///
/// Anything that can't be split safely — no plates, no root model, a reference that doesn't
/// say which file its object is in — has every file parsed, as before.
final class ThreeMFPackage {
    private static let rootPath = "3D/3dmodel.model"

    let project: SlicerProject
    private let archive: Archive
    /// Every `.model` entry by package path, and the paths in archive order.
    private let entries: [String: Entry]
    private let order: [String]
    /// The model files currently parsed.
    private var files: [String: ModelFile] = [:]
    private var assembly: Assembly
    private var metadata = ModelMetadata()
    /// Plates found to hold nothing once parsed. Remembered after their files are dropped,
    /// so paging keeps skipping them.
    private var emptyPlates = Set<Int>()
    /// Paging parses on a background queue; this keeps two pages from interleaving.
    private let lock = NSLock()

    /// Uncompressed model XML a prefetch may take on: about 65 MB once parsed, next to the
    /// few hundred MB the plate on screen can take as a scene.
    var prefetchBudget: UInt64 = 256 << 20
    private let prefetchQueue = DispatchQueue(label: "Preview3MF.prefetch", qos: .utility)
    /// Bumped by paging, which abandons any prefetch in flight. Guarded by its own lock
    /// because a running prefetch holds `lock`.
    private var prefetchGeneration = 0
    private let generationLock = NSLock()
    /// Model files parsed so far, for tests to tell a prefetched plate from a parsed one.
    private(set) var filesParsed = 0

    init(fileAt url: URL) throws {
        archive = try ThreeMFParser.openArchive(fileAt: url)
        // Bambu/Orca keep colour, plate layout and boolean-part roles in their own files
        // under Metadata/. Absent for spec-only 3MFs, in which case this is all no-ops.
        project = SlicerProject.read(from: archive)

        // Mesh may be in 3D/3dmodel.model or 3D/Objects/*.model
        var entries: [String: Entry] = [:]
        var order: [String] = []
        for entry in archive where entry.path.hasSuffix(".model") && entry.type == .file {
            let path = ObjectReference.normalizedPath(entry.path)
            entries[path] = entry
            order.append(path)
        }
        guard !order.isEmpty else {
            throw ThreeMFParserError.modelEntryNotFound
        }
        self.entries = entries
        self.order = order
        assembly = Assembly(project: project, files: [], allPaths: Set(order))
    }

    /// The result to open on: the first plate with anything on it, having parsed only what
    /// that plate needs — or, for a package without plates, everything.
    func firstResult() throws -> ParseResult {
        lock.lock()
        defer { lock.unlock() }

        if !project.plates.isEmpty, entries[Self.rootPath] != nil {
            try load([Self.rootPath])
            for index in project.plates.indices where assembly.needs(of: project.plates[index]).mayHaveGeometry {
                try loadPlate(index)
                if !plateItems(index).isEmpty {
                    metadata = mergedMetadata()
                    return try result(showing: index, lazy: true)
                }
                emptyPlates.insert(index)
            }
        }

        try load(Set(order))
        metadata = mergedMetadata()
        let first = project.plates.indices.first { !plateItems($0).isEmpty }
        return try result(showing: first, lazy: false)
    }

    /// A result showing plate `index`, parsing its model files if they aren't already.
    func result(showingPlate index: Int) throws -> ParseResult {
        cancelPrefetch()
        lock.lock()
        defer { lock.unlock() }
        try loadPlate(index)
        // Drop what this plate doesn't need — the last plate's files, or a prefetch that
        // guessed the wrong way.
        try load(assembly.needs(of: project.plates[index]).paths.union([Self.rootPath]))
        if plateItems(index).isEmpty { emptyPlates.insert(index) }
        return try result(showing: index, lazy: true)
    }

    /// Parse plate `index`'s model files in the background, keeping the shown plate's, so
    /// paging to it only has to build the scene. Skipped when the files would run past
    /// `prefetchBudget`, and abandoned as soon as a page is asked for.
    func prefetchPlate(_ index: Int) {
        let generation = generationLock.withLock { prefetchGeneration }
        prefetchQueue.async { [self] in
            let cancelled = { self.generationLock.withLock { self.prefetchGeneration != generation } }
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled(), project.plates.indices.contains(index) else { return }
            // Cancellation surfaces as a thrown error; whatever finished parsing is kept.
            try? loadPlate(index, prefetching: cancelled)
        }
    }

    /// Blocks until any prefetch already asked for has finished. For tests.
    func waitForPrefetch() {
        prefetchQueue.sync {}
    }

    private func cancelPrefetch() {
        generationLock.withLock { prefetchGeneration += 1 }
    }

    /// Parse whatever plate `index` needs. Repeats because a file can only be looked inside
    /// once parsed, and it may reference further files. Paging drops files the plate
    /// doesn't need as it goes; a prefetch keeps them, and stays within its budget.
    private func loadPlate(_ index: Int, prefetching cancelled: (() -> Bool)? = nil) throws {
        let plate = project.plates[index]
        for _ in 0..<8 {
            let needs = assembly.needs(of: plate)
            if needs.isComplete { return }
            guard let cancelled else {
                try load(needs.paths.union([Self.rootPath]))
                continue
            }
            let missing = needs.paths.subtracting(files.keys)
            let size = missing.reduce(UInt64(0)) { $0 + (entries[$1]?.uncompressedSize ?? 0) }
            guard size <= prefetchBudget else { return }
            try load(needs.paths.union(files.keys), cancelled: cancelled)
        }
    }

    /// Make `paths` exactly the set of parsed files: parse the missing, drop the rest.
    /// `cancelled` is checked as each chunk streams in; a file cut short is discarded.
    private func load(_ paths: Set<String>, cancelled: (() -> Bool)? = nil) throws {
        guard Set(files.keys) != paths else { return }
        files = files.filter { paths.contains($0.key) }
        defer {
            assembly = Assembly(
                project: project,
                files: order.compactMap { path in files[path].map { (path, $0) } },
                allPaths: Set(order)
            )
        }
        for path in paths where files[path] == nil {
            guard let entry = entries[path] else { continue }
            // Streamed straight from the zip into the parser; the XML is never held whole.
            let parser = FastModelParser()
            _ = try archive.extract(entry, bufferSize: 256 * 1024) { chunk in
                if let cancelled, cancelled() { throw CancellationError() }
                parser.feed(chunk)
            }
            files[path] = ModelFile(parser)
            filesParsed += 1
        }
    }

    private func plateItems(_ index: Int) -> [BuildItem] {
        let members = Set(project.plates[index].objectIDs)
        return assembly.expanded.filter { members.contains($0.object.id) }.flatMap { $0.items }
    }

    /// First non-nil value wins, in archive order. Slicer descriptions often arrive as
    /// (sometimes double-encoded) HTML, so every field is cleaned to plain text.
    private func mergedMetadata() -> ModelMetadata {
        var metadata = ModelMetadata()
        for path in order {
            guard let raw = files[path]?.metadata else { continue }
            if metadata.title == nil { metadata.title = ThreeMFParser.cleanMetadata(raw["Title"]) }
            if metadata.designer == nil { metadata.designer = ThreeMFParser.cleanMetadata(raw["Designer"]) }
            if metadata.description == nil { metadata.description = ThreeMFParser.cleanMetadata(raw["Description"]) }
            if metadata.copyright == nil { metadata.copyright = ThreeMFParser.cleanMetadata(raw["Copyright"]) }
            if metadata.application == nil { metadata.application = ThreeMFParser.cleanMetadata(raw["Application"]) }
        }
        return metadata
    }

    private func result(showing index: Int?, lazy: Bool) throws -> ParseResult {
        // Every plate shares one coordinate space, laid out side by side, so rendering them
        // together scatters the model across the bed and makes the dimensions meaningless.
        // Group by plate and show one; the caller can page through the rest. Plates the
        // slicer declared but left empty are kept, so plate numbering matches the slicer's.
        let plates: [PlateContents] = project.plates.enumerated().map { position, plate in
            let needs = assembly.needs(of: plate)
            let items = needs.isComplete ? plateItems(position) : []
            return PlateContents(
                name: plate.name,
                items: items,
                estimate: project.estimate(forPlateAt: position),
                modelPaths: needs.paths.sorted(),
                isLoaded: needs.isComplete,
                hasGeometry: needs.isComplete ? !items.isEmpty : needs.mayHaveGeometry && !emptyPlates.contains(position)
            )
        }

        let items: [BuildItem]
        if let index {
            items = plates[index].items
        } else {
            items = assembly.everything()
            guard !items.isEmpty else {
                throw ThreeMFParserError.parsingFailed("No mesh data found in any model file")
            }
        }
        // A file without plate assignments but with exactly one sliced plate still gets it.
        let estimate = index.flatMap { plates[$0].estimate }
            ?? (plates.isEmpty && project.sliceEstimates.count == 1 ? project.sliceEstimates.first?.value : nil)

        return ParseResult(
            items: items,
            metadata: metadata,
            plates: plates,
            plateIndex: index,
            printSettings: project.printSettings.isEmpty ? nil : project.printSettings,
            sliceEstimate: estimate,
            package: lazy ? self : nil
        )
    }
}

/// One parsed `.model` file, before its objects are assembled into build items.
private struct ModelFile {
    var meshes: [Int: MeshData] = [:]
    var components: [Int: [ObjectReference]] = [:]
    var buildItems: [ObjectReference] = []
    var metadata: [String: String] = [:]

    /// From a parser that has been fed the whole file.
    init(_ parser: FastModelParser) {
        for (id, object) in parser.objects {
            if !object.vertices.isEmpty {
                meshes[id] = MeshData(
                    vertices: object.vertices,
                    triangles: object.triangles,
                    triangleColors: object.triangleColors
                )
            }
            // Retain assembly containers even though they carry no mesh of their own.
            if !object.components.isEmpty {
                components[id] = object.components
            }
        }
        buildItems = parser.buildItems
        metadata = parser.metadata
    }
}

/// An object's identity: ids are only unique within the model file that defines them.
private struct ObjectKey: Hashable, Comparable {
    let path: String
    let id: Int

    /// By id first, so a single-file package keeps the id order it always had.
    static func < (a: ObjectKey, b: ObjectKey) -> Bool {
        (a.id, a.path) < (b.id, b.path)
    }
}

/// The parsed model files assembled into renderable geometry. Built over whichever files
/// are parsed: a reference into a file that isn't is left dangling, not followed.
private struct Assembly {
    let project: SlicerProject
    /// Every model file in the package, parsed or not.
    let allPaths: Set<String>
    let loadedPaths: Set<String>
    private(set) var meshes: [ObjectKey: MeshData] = [:]
    private(set) var components: [ObjectKey: [ObjectReference]] = [:]
    private var keysByID: [Int: ObjectKey] = [:]
    private var buildItemKeys = Set<ObjectKey>()
    private var componentChildKeys = Set<ObjectKey>()
    /// Each build item expanded exactly once; plates are then just groupings of these.
    private(set) var expanded: [(object: ObjectKey, items: [BuildItem])] = []

    /// `files` in archive order, which sets the order build items render in.
    init(project: SlicerProject, files: [(path: String, file: ModelFile)], allPaths: Set<String>) {
        self.project = project
        self.allPaths = allPaths
        loadedPaths = Set(files.map { $0.path })

        // Object ids are scoped to the file that defines them, so objects are keyed by
        // (file, id): two files may both hold an object 1.
        var buildReferences: [(reference: ObjectReference, file: String)] = []
        for (path, file) in files {
            for (id, mesh) in file.meshes { meshes[ObjectKey(path: path, id: id)] = mesh }
            for (id, references) in file.components { components[ObjectKey(path: path, id: id)] = references }
            buildReferences += file.buildItems.map { ($0, path) }
        }

        // Merge color data across objects: if any object has colors, the rest are gray
        if meshes.values.contains(where: { $0.triangleColors != nil }) {
            for key in meshes.keys where meshes[key]!.triangleColors == nil {
                meshes[key]!.uniformColor = SIMD4<Float>(0.75, 0.75, 0.75, 1.0)
            }
        }

        for key in Set(meshes.keys).union(components.keys).sorted() where keysByID[key.id] == nil {
            keysByID[key.id] = key
        }

        var buildItems = buildReferences.map {
            (object: resolve($0.reference, in: $0.file), transform: $0.reference.transform)
        }
        buildItemKeys = Set(buildItems.map { $0.object })

        // Objects referenced by a <component> are assembly parts, not standalone roots.
        componentChildKeys = Set(components.flatMap { parent, references in
            references.map { resolve($0, in: parent.path) }
        })

        // If no build items were specified, render every top-level object — i.e. one
        // that isn't itself a component of another object — with an identity transform.
        if buildItems.isEmpty {
            let rootKeys = Set(meshes.keys).union(components.keys).subtracting(componentChildKeys)
            for key in rootKeys.sorted() {
                buildItems.append((object: key, transform: matrix_identity_float4x4))
            }
        }

        expanded = buildItems.map { ($0.object, expand($0.object, $0.transform, [], nil)) }
    }

    /// Some writers reference an object in another file without naming the file. When the
    /// id isn't in the referencing file, match it anywhere in the package, first file in
    /// path order winning. An explicit `p:path` is always taken at its word.
    func resolve(_ reference: ObjectReference, in path: String) -> ObjectKey {
        let key = ObjectKey(path: reference.path ?? path, id: reference.objectID)
        guard reference.path == nil, meshes[key] == nil, components[key] == nil else { return key }
        return keysByID[reference.objectID] ?? key
    }

    /// Flatten an object into (mesh, world-transform) pairs, following <component>
    /// references. `visited` breaks reference cycles in malformed files.
    /// `inheritedColor` carries an object's filament colour down to the component meshes
    /// that actually hold its geometry — the slicer records the filament slot on the
    /// container object, one level above the mesh.
    func expand(
        _ key: ObjectKey,
        _ transform: simd_float4x4,
        _ visited: Set<ObjectKey>,
        _ inheritedColor: SIMD4<Float>?
    ) -> [BuildItem] {
        guard !visited.contains(key), visited.count < 64 else { return [] }
        // Negative parts are boolean cutting tools. They shape other geometry and are
        // never printed, so rendering them puts solid blocks through the model.
        // Slicer metadata names objects by bare id; Bambu keeps ids unique package-wide.
        guard !project.negativeParts.contains(key.id) else { return [] }

        let color = project.color(forObject: key.id) ?? inheritedColor
        var out: [BuildItem] = []
        if var mesh = meshes[key] {
            // Only where the model XML carried no colour of its own — the standard
            // material extensions outrank the slicer's sidecar metadata.
            if !mesh.hasColors, let color {
                mesh.uniformColor = color
            }
            out.append(BuildItem(mesh: mesh, transform: transform))
        }
        if let references = components[key] {
            var nextVisited = visited
            nextVisited.insert(key)
            for reference in references {
                // Column-vector nesting: world = parent · component (parent on the left).
                out += expand(resolve(reference, in: key.path), transform * reference.transform, nextVisited, color)
            }
        }
        return out
    }

    /// Everything, as for a package without plates: each build item, plus any mesh that
    /// neither a build item nor a component reaches.
    func everything() -> [BuildItem] {
        var result = expanded.flatMap { $0.items }
        for key in meshes.keys.sorted() where !buildItemKeys.contains(key) && !componentChildKeys.contains(key) {
            result += expand(key, matrix_identity_float4x4, [], nil)
        }
        return result
    }

    struct PlateNeeds {
        /// Model files the plate's geometry is spread across, as far as can be seen.
        var paths = Set<String>()
        /// Every file the plate needs is parsed, so its items are final.
        var isComplete = true
        /// Reaches a mesh, or a file not yet parsed that might hold one.
        var mayHaveGeometry = false
    }

    /// What it takes to show `plate`, walking its objects' components through the parsed
    /// files. A file not yet parsed can't be looked inside, so its own references only
    /// come to light once it is.
    func needs(of plate: SlicerProject.Plate) -> PlateNeeds {
        let members = Set(plate.objectIDs)
        let allLoaded = loadedPaths.isSuperset(of: allPaths)
        var needs = PlateNeeds()
        var visited = Set<ObjectKey>()

        func walk(_ key: ObjectKey) {
            // Negative parts aren't rendered, so their files needn't be parsed.
            guard !project.negativeParts.contains(key.id), visited.insert(key).inserted else { return }
            guard loadedPaths.contains(key.path) else {
                if allPaths.contains(key.path) {
                    needs.paths.insert(key.path)
                    needs.isComplete = false
                    needs.mayHaveGeometry = true
                }
                return
            }
            needs.paths.insert(key.path)
            if meshes[key] != nil { needs.mayHaveGeometry = true }
            for reference in components[key] ?? [] {
                let named = ObjectKey(path: reference.path ?? key.path, id: reference.objectID)
                if reference.path == nil, !allLoaded, meshes[named] == nil, components[named] == nil {
                    // In another file that the reference doesn't name: only parsing
                    // everything can say which.
                    needs.paths.formUnion(allPaths)
                    needs.isComplete = false
                    needs.mayHaveGeometry = true
                    continue
                }
                walk(resolve(reference, in: key.path))
            }
        }

        for entry in expanded where members.contains(entry.object.id) {
            walk(entry.object)
        }
        return needs
    }
}

/// Parsed data for a single `<object>` element.
///
/// An object is either a `<mesh>` (vertices/triangles) or a `<components>`
/// container that references other objects by id with a transform — slicers use
/// the latter for assemblies. Both can be empty; `components` drives expansion.
struct ParsedObject {
    var vertices: [SIMD3<Float>] = []
    var triangles: [(UInt32, UInt32, UInt32)] = []
    var triangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?
    var components: [ObjectReference] = []
}

/// A `<component>` or build `<item>`: a placement of an object, which may live in another
/// model file.
struct ObjectReference {
    var objectID: Int
    /// Package path of the model file holding the object — the production extension's
    /// `p:path`, without its leading slash. `nil` means the file the reference sits in.
    var path: String?
    var transform: simd_float4x4

    static func normalizedPath(_ raw: String) -> String {
        raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }
}

/// Attribute parsing shared with the slicer sidecar readers.
extension FastModelParser {
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

/// A hand-written scanner for 3MF `<model>` XML.
///
/// Foundation's `XMLParser` builds a bridged `[String: String]` attribute dictionary
/// for every element; with millions of `<vertex>`/`<triangle>` elements that allocation
/// dominates parse time. This walks the raw UTF-8 bytes and reads numbers directly with
/// `strtod`/`strtol`, allocating nothing per element. (3MF always uses `.` as the decimal
/// separator, matching the process's default C numeric locale.)
///
/// Input can arrive in chunks through `feed`, straight from the zip, so a model file is
/// never held whole — the largest in a big Bambu project runs past 100 MB of XML.
final class FastModelParser {
    var objects: [Int: ParsedObject] = [:]
    var buildItems: [ObjectReference] = []
    var metadata: [String: String] = [:]

    private var materialGroups: [Int: [SIMD4<Float>]] = [:]
    private var currentGroupID: Int?
    private var currentGroupColors: [SIMD4<Float>] = []

    private var currentObjectID: Int?
    private var currentVertices: [SIMD3<Float>] = []
    private var currentTriangles: [(UInt32, UInt32, UInt32)] = []
    private var currentTriangleColors: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)]?
    private var currentComponents: [ObjectReference] = []
    private var objectPID: Int?
    private var objectPIndex: Int?
    private var inBuild = false

    /// The open `<metadata>` element's name, and its text so far from earlier chunks.
    private var metaName: String?
    private var metaCarriedText: [UInt8] = []
    /// Input after the last complete tag, waiting for the rest of it.
    private var pending = Data()

    private let defaultGray = SIMD4<Float>(0.75, 0.75, 0.75, 1.0)

    /// Parses a whole document at once.
    func parse(_ data: Data) -> Bool {
        feed(data)
        return true
    }

    /// Parses the next chunk of the document. Everything up to the last `>` is made of
    /// complete tags and is scanned now; the tail waits for the next chunk.
    func feed(_ chunk: Data) {
        pending.append(chunk)
        let end: Int? = pending.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var e = bytes.count - 1
            while e >= 0, bytes[e] != UInt8(ascii: ">") { e -= 1 }
            guard e >= 0 else { return nil }
            scan(UnsafeRawBufferPointer(rebasing: raw[0...e]))
            return e + 1
        }
        if let end {
            pending = pending.subdata(in: pending.startIndex + end..<pending.endIndex)
        }
    }

    private func scan(_ raw: UnsafeRawBufferPointer) {
        do {
            let bytes = raw.bindMemory(to: UInt8.self)
            let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            let n = bytes.count

            let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
            let quote = UInt8(ascii: "\""), eq = UInt8(ascii: "="), colon = UInt8(ascii: ":")
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
            // The production extension's `p:path`. The prefix is the writer's choice, so match
            // any prefixed attribute whose local name is `path`; the core spec has none.
            @inline(__always) func isPathAttribute(_ an: Int, _ al: Int) -> Bool {
                guard al > 5, bytes[an + al - 5] == colon else { return false }
                return nameIs(an + al - 4, 4, "path")
            }
            @inline(__always) func str(_ vs: Int, _ ve: Int) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: bytes[vs..<ve]), as: UTF8.self)
            }
            @inline(__always) func valueEnd(_ vs: Int) -> Int {
                var e = vs; while e < n, bytes[e] != quote { e += 1 }; return e
            }

            var i = 0
            // Text of a <metadata> opened in an earlier chunk resumes at the start of this one.
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
                var ns = isClose ? after + 1 : after
                var j = ns
                while j < n {
                    let b = bytes[j]
                    if b == gt || b == slash || isSpace(b) { break }
                    j += 1
                }
                // Match on the local name. The Materials & Properties extension is written
                // with a namespace prefix (<m:colorgroup>) whose spelling is up to the writer,
                // so skip past any prefix before comparing.
                var localStart = ns
                while localStart < j, bytes[localStart] != colon { localStart += 1 }
                if localStart < j { ns = localStart + 1 }
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
                    } else if nameIs(ns, nl, "basematerials") || nameIs(ns, nl, "colorgroup") {
                        if let id = currentGroupID { materialGroups[id] = currentGroupColors }
                        currentGroupID = nil; currentGroupColors = []
                    } else if nameIs(ns, nl, "metadata") {
                        if let name = metaName {
                            metaCarriedText.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[metaTextStart..<i]))
                            let text = String(decoding: metaCarriedText, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { metadata[name] = Self.decodeEntities(text) }
                        }
                        metaName = nil
                        metaCarriedText = []
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
                } else if nameIs(ns, nl, "component") || nameIs(ns, nl, "item") {
                    // Both place an object, optionally one in another model file.
                    let isItem = nameIs(ns, nl, "item")
                    if isItem ? inBuild : currentObjectID != nil {
                        var objectID: Int? = nil
                        var path: String? = nil
                        var transform = matrix_identity_float4x4
                        forEachAttr(j, attrEnd) { an, al, vs in
                            if nameIs(an, al, "objectid") { objectID = d(vs) }
                            else if nameIs(an, al, "transform") { transform = Self.parseTransform(str(vs, valueEnd(vs))) }
                            else if isPathAttribute(an, al) { path = ObjectReference.normalizedPath(str(vs, valueEnd(vs))) }
                        }
                        if let objectID {
                            let reference = ObjectReference(objectID: objectID, path: path, transform: transform)
                            if isItem { buildItems.append(reference) } else { currentComponents.append(reference) }
                        }
                    }
                } else if nameIs(ns, nl, "build") {
                    inBuild = true
                } else if nameIs(ns, nl, "base") {
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "displaycolor"),
                           let color = Self.parseDisplayColor(str(vs, valueEnd(vs))) {
                            currentGroupColors.append(color)
                        }
                    }
                } else if nameIs(ns, nl, "basematerials") {
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "id") { currentGroupID = d(vs); currentGroupColors = [] }
                    }
                } else if nameIs(ns, nl, "colorgroup") {
                    // Materials & Properties extension — the standard way to carry
                    // per-triangle colour, used by 3D Builder, Fusion and anything exporting
                    // conformant 3MF. (Bambu Studio and OrcaSlicer instead paint via a
                    // proprietary `paint_color` triangle attribute, which this does not read.)
                    // Resource ids share a single space with <basematerials>, so triangles
                    // resolve to these through the same pid / p1..p3 lookup, no special casing.
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "id") { currentGroupID = d(vs); currentGroupColors = [] }
                    }
                } else if nameIs(ns, nl, "color"), currentGroupID != nil {
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "color"),
                           let color = Self.parseDisplayColor(str(vs, valueEnd(vs))) {
                            currentGroupColors.append(color)
                        }
                    }
                } else if nameIs(ns, nl, "metadata") {
                    var name: String?
                    forEachAttr(j, attrEnd) { an, al, vs in
                        if nameIs(an, al, "name") { name = str(vs, valueEnd(vs)) }
                    }
                    // Self-closing (<metadata .../>) carries no text.
                    if attrEnd > j, bytes[attrEnd - 1] != slash {
                        metaName = name
                        metaCarriedText = []
                        metaTextStart = k + 1
                    }
                }

                i = k + 1
            }

            // Metadata text running on into the next chunk.
            if metaName != nil, metaTextStart < n {
                metaCarriedText.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[metaTextStart..<n]))
            }
        }
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
