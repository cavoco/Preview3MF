import Foundation
import simd

/// What a stretch of extrusion is for, from the label the slicer writes before it. Slicers
/// name the same things differently (`;TYPE:External perimeter`, `; FEATURE: Outer wall`,
/// `;TYPE:WALL-OUTER`); this is the shared set, small enough to give each its own colour.
enum GCodeFeature: UInt8, CaseIterable {
    case other, outerWall, innerWall, overhangWall, sparseInfill, solidInfill, topSurface,
         bottomSurface, bridge, gapFill, ironing, support, supportInterface, skirt, primeTower

    init(label: String) {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "external perimeter", "outer wall", "wall-outer": self = .outerWall
        case "perimeter", "inner wall", "wall-inner": self = .innerWall
        case "overhang perimeter", "overhang wall": self = .overhangWall
        case "internal infill", "sparse infill", "fill": self = .sparseInfill
        case "solid infill", "internal solid infill", "floating vertical shell", "skin": self = .solidInfill
        case "top solid infill", "top surface": self = .topSurface
        case "bottom surface": self = .bottomSurface
        case "bridge infill", "bridge", "internal bridge": self = .bridge
        case "gap fill", "gap infill": self = .gapFill
        case "ironing": self = .ironing
        case "support material", "support", "support transition": self = .support
        case "support material interface", "support interface", "support-interface": self = .supportInterface
        case "skirt/brim", "skirt", "brim": self = .skirt
        case "wipe tower", "prime tower", "prime-tower": self = .primeTower
        default: self = .other
        }
    }
}

/// A sliced print read from G-code: every move that lays down plastic, in print order and
/// grouped into layers, plus what the slicer said about the print in its comments.
struct GCodeToolpath {
    /// Each extrusion segment's start and end, in millimetres in the printer's own
    /// coordinates — two points a segment, so segment `i` is `points[2i]` to `points[2i+1]`.
    var points: [SIMD3<Float>] = []
    /// Per segment: what it prints, and with which tool (0-based).
    var features: [GCodeFeature] = []
    var tools: [UInt8] = []
    /// Layers in print order.
    var layers: [Layer] = []

    /// The slicer that wrote the file, as it names itself: "PrusaSlicer 2.4.2".
    var slicer: String?
    /// Filament colours by tool, as the slicer shows them.
    var filamentColors: [SIMD4<Float>] = []
    var printSettings: PrintSettings?
    var estimate: SliceEstimate?

    struct Layer: Equatable {
        /// Height of the layer's first extrusion.
        var z: Float
        var segments: Range<Int>
    }

    var segmentCount: Int { features.count }

    /// The smallest box holding every extrusion, or nil when there is none.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lower = points.first else { return nil }
        var upper = lower
        for point in points {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }
        return (lower, upper)
    }
}

/// Reads text G-code from any of the common slicers.
///
/// Only extrusion is kept: a move counts when it pushes filament forward while the nozzle
/// moves. Travel, retraction and the firmware's own housekeeping are followed only to know
/// where the nozzle is. Arcs (`G2`/`G3`, which Bambu Studio and OrcaSlicer write a lot of)
/// are flattened into short straight pieces.
///
/// Layers come from the slicer's layer-change comments where it writes them, since a
/// spiral-vase print climbs on every move; otherwise each new extrusion height starts one.
enum GCodeParser {
    enum ParseError: Error {
        case unreadable
        /// PrusaSlicer's binary G-code (`.bgcode`), a compressed format of its own.
        case binaryGCode
    }

    static func parse(fileAt url: URL) throws -> GCodeToolpath {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            throw ParseError.unreadable
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> GCodeToolpath {
        if data.starts(with: Array("GCDE".utf8)) { throw ParseError.binaryGCode }
        var reader = Reader()
        data.withUnsafeBytes { raw in
            reader.read(raw.bindMemory(to: UInt8.self))
        }
        return reader.finish()
    }

    /// Seconds in a slicer duration: "1d 2h 3m 4s", "40m 26s", "33s".
    static func parseDuration(_ text: String) -> Int? {
        var total = 0
        var found = false
        for token in text.split(separator: " ") {
            guard let unit = token.last, let value = Int(token.dropLast()) else { continue }
            switch unit {
            case "d": total += value * 86_400
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: continue
            }
            found = true
        }
        return found ? total : nil
    }

    private struct Reader {
        var path = GCodeToolpath()

        // Machine state.
        var position = SIMD3<Float>(0, 0, 0)
        var extruder: Double = 0
        var absolutePositions = true
        var absoluteExtrusion = true
        var unitScale: Float = 1
        var feature = GCodeFeature.other
        var tool: UInt8 = 0

        // Layering.
        var usesLayerMarkers = false
        var layerPending = true
        var layerStart = 0
        var layerZ: Float = 0

        // What the comments said.
        var settings: [String: String] = [:]
        var printSeconds: Int?
        var filamentGrams: Double?

        mutating func read(_ bytes: UnsafeBufferPointer<UInt8>) {
            guard let base = bytes.baseAddress else { return }
            let n = bytes.count
            var start = 0
            while start < n {
                var end = n
                if let hit = memchr(base + start, 0x0A, n - start) {
                    end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                }
                line(bytes, start, end)
                start = end + 1
            }
        }

        // MARK: Lines

        mutating func line(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
            var i = start
            while i < end, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
            guard i < end else { return }
            if b[i] == 0x3B { comment(b, i + 1, end); return }   // ';'

            let letter = b[i] | 0x20                               // lower-case
            i += 1
            var number = 0
            var digits = 0
            while i < end, b[i] >= 0x30, b[i] <= 0x39 {
                number = number &* 10 &+ Int(b[i] - 0x30)
                digits += 1
                i += 1
            }
            guard digits > 0 else { return }
            if i < end, b[i] == 0x2E { return }                    // G29.1 and the like

            switch (letter, number) {
            case (0x67, 0), (0x67, 1): move(b, i, end, arc: nil)   // g
            case (0x67, 2): move(b, i, end, arc: .clockwise)
            case (0x67, 3): move(b, i, end, arc: .counterclockwise)
            case (0x67, 20): unitScale = 25.4
            case (0x67, 21): unitScale = 1
            case (0x67, 28): home(b, i, end)
            case (0x67, 90): absolutePositions = true; absoluteExtrusion = true
            case (0x67, 91): absolutePositions = false; absoluteExtrusion = false
            case (0x67, 92): setPosition(b, i, end)
            case (0x6D, 82): absoluteExtrusion = true              // m
            case (0x6D, 83): absoluteExtrusion = false
            case (0x6D, 620):
                // Bambu's filament change, `M620 S1A`; S255 is an unload, not a tool.
                if let slot = parameters(b, i, end).s, slot >= 0, slot < 64 { tool = UInt8(slot) }
            case (0x74, _):                                        // t
                // Firmware reserves big numbers (T255, T1000) for its own uses.
                if number < 64 { tool = UInt8(number) }
            default:
                break
            }
        }

        struct Parameters {
            var x, y, z, e, i, j, s: Double?
        }

        func parameters(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Parameters {
            var p = Parameters()
            var k = start
            while k < end {
                let c = b[k] | 0x20
                if b[k] == 0x3B { break }                          // trailing comment
                k += 1
                guard c >= 0x61, c <= 0x7A else { continue }
                let (value, next) = Self.number(b, k, end)
                k = next
                guard let value else { continue }
                switch c {
                case 0x78: p.x = value
                case 0x79: p.y = value
                case 0x7A: p.z = value
                case 0x65: p.e = value
                case 0x69: p.i = value
                case 0x6A: p.j = value
                case 0x73: p.s = value
                default: break
                }
            }
            return p
        }

        /// A decimal number at `start`, and where it ends. Hand-rolled because `strtod`
        /// needs a terminator the mapped file doesn't have. No exponents: G-code has none,
        /// and in packed words like `Y0E1.5` the `E` is the next axis.
        static func number(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> (Double?, Int) {
            var k = start
            var negative = false
            if k < end, b[k] == 0x2D || b[k] == 0x2B { negative = b[k] == 0x2D; k += 1 }
            var value: Double = 0
            var digits = 0
            while k < end, b[k] >= 0x30, b[k] <= 0x39 {
                value = value * 10 + Double(b[k] - 0x30); digits += 1; k += 1
            }
            if k < end, b[k] == 0x2E {
                k += 1
                var scale = 0.1
                while k < end, b[k] >= 0x30, b[k] <= 0x39 {
                    value += Double(b[k] - 0x30) * scale; scale *= 0.1; digits += 1; k += 1
                }
            }
            guard digits > 0 else { return (nil, k) }
            return (negative ? -value : value, k)
        }

        // MARK: Moves

        enum ArcDirection { case clockwise, counterclockwise }

        mutating func move(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, arc: ArcDirection?) {
            let p = parameters(b, start, end)
            var target = position
            func axis(_ value: Double?, _ current: Float) -> Float {
                guard let value else { return current }
                let v = Float(value) * unitScale
                return absolutePositions ? v : current + v
            }
            target.x = axis(p.x, position.x)
            target.y = axis(p.y, position.y)
            target.z = axis(p.z, position.z)
            var pushed: Double = 0
            if let e = p.e {
                pushed = absoluteExtrusion ? e - extruder : e
                extruder = absoluteExtrusion ? e : extruder + e
            }
            let from = position
            position = target
            guard pushed > 1e-9, from != target else { return }

            guard let arc, p.i != nil || p.j != nil else {
                add(from, target)
                return
            }
            // Arc about a centre given relative to the start; flatten to ~1 mm pieces.
            let centre = SIMD2(from.x + Float(p.i ?? 0) * unitScale, from.y + Float(p.j ?? 0) * unitScale)
            let a = SIMD2(from.x, from.y) - centre
            let c = SIMD2(target.x, target.y) - centre
            let radius = simd_length(a)
            guard radius > 1e-4 else { add(from, target); return }
            let startAngle = atan2(a.y, a.x)
            var sweep = atan2(c.y, c.x) - startAngle
            switch arc {
            case .clockwise: if sweep >= 0 { sweep -= 2 * .pi }
            case .counterclockwise: if sweep <= 0 { sweep += 2 * .pi }
            }
            let pieces = min(max(Int((abs(sweep) * radius).rounded(.up)), Int((abs(sweep) / (.pi / 12)).rounded(.up)), 1), 720)
            var previous = from
            for step in 1...pieces {
                let t = Float(step) / Float(pieces)
                let next: SIMD3<Float>
                if step == pieces {
                    next = target
                } else {
                    let angle = startAngle + sweep * t
                    next = SIMD3(centre.x + radius * cos(angle), centre.y + radius * sin(angle),
                                 from.z + (target.z - from.z) * t)
                }
                add(previous, next)
                previous = next
            }
        }

        mutating func add(_ from: SIMD3<Float>, _ to: SIMD3<Float>) {
            let index = path.features.count
            let newLayer = index == 0 || (usesLayerMarkers ? layerPending : abs(to.z - layerZ) > 1e-3)
            if newLayer {
                closeLayer(at: index)
                layerStart = index
                layerZ = to.z
                layerPending = false
            }
            path.points.append(from)
            path.points.append(to)
            path.features.append(feature)
            path.tools.append(tool)
        }

        mutating func closeLayer(at index: Int) {
            guard index > layerStart else { return }
            path.layers.append(.init(z: layerZ, segments: layerStart..<index))
        }

        mutating func home(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
            // `G28` homes every axis, `G28 X Y` only those named.
            var named = false
            var k = start
            while k < end, b[k] != 0x3B {
                switch b[k] | 0x20 {
                case 0x78: position.x = 0; named = true
                case 0x79: position.y = 0; named = true
                case 0x7A: position.z = 0; named = true
                default: break
                }
                k += 1
            }
            if !named { position = .zero }
        }

        mutating func setPosition(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
            let p = parameters(b, start, end)
            if let x = p.x { position.x = Float(x) * unitScale }
            if let y = p.y { position.y = Float(y) * unitScale }
            if let z = p.z { position.z = Float(z) * unitScale }
            if let e = p.e { extruder = e }
        }

        // MARK: Comments

        mutating func comment(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
            var i = start
            while i < end, b[i] == 0x20 { i += 1 }
            var stop = end
            while stop > i, b[stop - 1] == 0x0D || b[stop - 1] == 0x20 { stop -= 1 }
            guard i < stop else { return }
            func hasPrefix(_ s: StaticString) -> Bool {
                let count = s.utf8CodeUnitCount
                guard stop - i >= count else { return false }
                return memcmp(b.baseAddress! + i, s.utf8Start, count) == 0
            }
            func text(from offset: Int) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: b[(i + offset)..<stop]), as: UTF8.self)
            }

            // The common cases first: these arrive thousands of times a print.
            if hasPrefix("TYPE:") { feature = GCodeFeature(label: text(from: 5)); return }
            if hasPrefix("FEATURE:") { feature = GCodeFeature(label: text(from: 8)); return }
            if hasPrefix("LAYER_CHANGE") || hasPrefix("CHANGE_LAYER") || hasPrefix("LAYER:") {
                // Start G-code's purge line comes before the first marker; it belongs to the
                // first layer rather than being a layer of its own.
                layerPending = usesLayerMarkers || path.features.isEmpty
                usesLayerMarkers = true
                return
            }
            if hasPrefix("WIDTH:") || hasPrefix("HEIGHT:") || hasPrefix("Z:") || hasPrefix("Z_HEIGHT:")
                || hasPrefix("LAYER_HEIGHT:") || hasPrefix("WIPE_") { return }

            if path.slicer == nil {
                if hasPrefix("generated by ") {
                    let rest = text(from: 13)
                    path.slicer = rest.components(separatedBy: " on ").first ?? rest
                    return
                }
                if hasPrefix("Generated with ") { path.slicer = text(from: 15); return }
                if hasPrefix("BambuStudio ") { path.slicer = text(from: 0); return }
            }
            if hasPrefix("TIME:") {                                // Cura, in seconds
                printSeconds = printSeconds ?? Int(text(from: 5))
                return
            }
            if hasPrefix("model printing time:") {                 // Bambu header
                if let total = text(from: 0).components(separatedBy: "total estimated time:").dropFirst().first {
                    printSeconds = GCodeParser.parseDuration(total)
                }
                return
            }
            if hasPrefix("total filament weight [g] :") {          // Bambu header
                filamentGrams = Double(text(from: 27).trimmingCharacters(in: .whitespaces))
                return
            }

            // `key = value`, the way PrusaSlicer, Bambu Studio and OrcaSlicer list settings.
            guard let eq = memchr(b.baseAddress! + i, 0x3D, stop - i) else { return }
            let eqIndex = b.baseAddress!.distance(to: eq.assumingMemoryBound(to: UInt8.self))
            guard eqIndex > i, b[eqIndex - 1] == 0x20 else { return }
            let key = String(decoding: UnsafeBufferPointer(rebasing: b[i..<(eqIndex - 1)]), as: UTF8.self)
            var valueStart = eqIndex + 1
            while valueStart < stop, b[valueStart] == 0x20 { valueStart += 1 }
            settings[key] = String(decoding: UnsafeBufferPointer(rebasing: b[valueStart..<stop]), as: UTF8.self)
        }

        // MARK: Finish

        mutating func finish() -> GCodeToolpath {
            closeLayer(at: path.features.count)

            let slicer = path.slicer ?? ""
            let prusaFamily = ["PrusaSlicer", "SuperSlicer", "Slic3r"].contains { slicer.contains($0) }
            if prusaFamily {
                path.filamentColors = SlicerProject.filamentColors(fromPrusaConfig: settings)
            } else {
                // Bambu Studio and OrcaSlicer also write an `extruder_colour`, but for the
                // printer's one nozzle, not per filament.
                path.filamentColors = SlicerProject.prusaStrings(settings["filament_colour"]).map {
                    FastModelParser.parseDisplayColor($0) ?? SIMD4<Float>(0.75, 0.75, 0.75, 1.0)
                }
            }

            let profile = PrintSettings(keyValues: settings)
            path.printSettings = profile.isEmpty ? nil : profile

            if let normal = settings["estimated printing time (normal mode)"] {
                printSeconds = GCodeParser.parseDuration(normal) ?? printSeconds
            }
            if filamentGrams == nil {
                if let total = settings["total filament used [g]"] {
                    filamentGrams = Double(total)
                } else if let perTool = settings["filament used [g]"] {
                    let grams = perTool.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if !grams.isEmpty { filamentGrams = grams.reduce(0, +) }
                }
            }
            let estimate = SliceEstimate(printSeconds: printSeconds, filamentGrams: filamentGrams)
            path.estimate = estimate.isEmpty ? nil : estimate
            return path
        }
    }
}
