import Foundation
import simd
import ZIPFoundation

/// Bambu Studio and OrcaSlicer keep three things a preview needs *outside* the 3MF model
/// XML, in files of their own under `Metadata/`:
///
/// - the filament palette, in `project_settings.config` (JSON)
/// - each object's filament slot, whether a part is a boolean cutting tool, and which build
///   plate an object sits on, in `model_settings.config` (XML)
///
/// None of this is part of the 3MF spec, so everything here is best-effort: a missing or
/// malformed file yields an empty value and the caller falls back to its previous behaviour.
struct SlicerProject {
    /// Filament colours indexed by `extruder - 1`.
    var filamentColors: [SIMD4<Float>] = []
    /// Object id → 1-based extruder slot.
    var objectExtruder: [Int: Int] = [:]
    /// Object ids that are subtractive — boolean cutting tools, not printed geometry.
    var negativeParts: Set<Int> = []
    /// Build plates in file order, each listing the object ids placed on it.
    var plates: [[Int]] = []

    var isEmpty: Bool {
        filamentColors.isEmpty && objectExtruder.isEmpty && negativeParts.isEmpty && plates.isEmpty
    }

    /// The filament colour assigned to an object, if the slot resolves to a known filament.
    func color(forObject id: Int) -> SIMD4<Float>? {
        guard let slot = objectExtruder[id], slot >= 1, slot <= filamentColors.count else {
            return nil
        }
        return filamentColors[slot - 1]
    }

    static func read(from archive: Archive) -> SlicerProject {
        var project = SlicerProject()
        if let data = entryData(archive, "Metadata/project_settings.config") {
            project.filamentColors = filamentColors(fromProjectSettings: data)
        }
        if let data = entryData(archive, "Metadata/model_settings.config") {
            let delegate = ModelSettingsDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            if parser.parse() {
                project.objectExtruder = delegate.objectExtruder
                project.negativeParts = delegate.negativeParts
                project.plates = delegate.plates
            }
        }
        return project
    }

    private static func entryData(_ archive: Archive, _ path: String) -> Data? {
        guard let entry = archive[path], entry.type == .file else { return nil }
        var data = Data()
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : data
    }

    /// `project_settings.config` is JSON despite the extension. Only `filament_colour` is read;
    /// it is a flat array of `#RRGGBB` strings, one per filament slot.
    private static func filamentColors(fromProjectSettings data: Data) -> [SIMD4<Float>] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["filament_colour"] as? [String] else {
            return []
        }
        // A slot we cannot parse still has to occupy its index, or every later slot shifts.
        return raw.map { ModelXMLDelegate.parseDisplayColor($0) ?? SIMD4<Float>(0.75, 0.75, 0.75, 1.0) }
    }
}

/// Reads `Metadata/model_settings.config`.
///
/// Shape, trimmed to what matters here:
/// ```xml
/// <config>
///   <object id="12">
///     <metadata key="extruder" value="1"/>
///     <part id="10" subtype="negative_part"> … </part>
///   </object>
///   <plate>
///     <metadata key="plater_id" value="1"/>
///     <model_instance><metadata key="object_id" value="2"/></model_instance>
///   </plate>
/// </config>
/// ```
/// A `<part>`'s id is the 3MF object id of the mesh it refers to, which is how a negative
/// part is matched back to geometry. Parts carry their own `extruder` key, so object-level
/// extruder is only recorded while no part is open.
final class ModelSettingsDelegate: NSObject, XMLParserDelegate {
    var objectExtruder: [Int: Int] = [:]
    var negativeParts: Set<Int> = []
    var plates: [[Int]] = []

    private var currentObjectID: Int?
    private var currentPartID: Int?
    private var inPlate = false
    private var inModelInstance = false
    private var currentPlateObjects: [Int] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "object":
            currentObjectID = attributes["id"].flatMap(Int.init)
            currentPartID = nil
        case "part":
            currentPartID = attributes["id"].flatMap(Int.init)
            if attributes["subtype"] == "negative_part", let id = currentPartID {
                negativeParts.insert(id)
            }
        case "plate":
            inPlate = true
            currentPlateObjects = []
        case "model_instance":
            inModelInstance = true
        case "metadata":
            guard let key = attributes["key"], let value = attributes["value"] else { return }
            if key == "extruder", currentPartID == nil, let id = currentObjectID {
                objectExtruder[id] = Int(value)
            }
            if key == "object_id", inPlate, inModelInstance, let id = Int(value) {
                currentPlateObjects.append(id)
            }
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
        case "object":
            currentObjectID = nil
            currentPartID = nil
        case "part":
            currentPartID = nil
        case "model_instance":
            inModelInstance = false
        case "plate":
            plates.append(currentPlateObjects)
            currentPlateObjects = []
            inPlate = false
        default:
            break
        }
    }
}
