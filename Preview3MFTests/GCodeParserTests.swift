import XCTest
import simd
@testable import Preview3MF

final class GCodeParserTests: XCTestCase {
    private func parse(_ gcode: String) throws -> GCodeToolpath {
        try GCodeParser.parse(Data(gcode.utf8))
    }

    private func segment(_ path: GCodeToolpath, _ index: Int) -> (SIMD3<Float>, SIMD3<Float>) {
        (path.points[2 * index], path.points[2 * index + 1])
    }

    // MARK: - Moves

    func testOnlyMovesThatExtrudeAreKept() throws {
        let path = try parse("""
            G90
            M83
            G1 Z0.2 F600
            G0 X10 Y10          ; travel
            G1 X20 Y10 E0.5     ; extrude
            G1 E-0.8 F2100      ; retract, no move
            G1 X30 Y30 F9000    ; travel
            G1 E0.8             ; unretract, no move
            G1 X40 Y30 E0.5
            G1 X50 Y30 E-0.2    ; wipe while retracting
            """)
        XCTAssertEqual(path.segmentCount, 2)
        XCTAssertEqual(segment(path, 0).0, SIMD3(10, 10, 0.2))
        XCTAssertEqual(segment(path, 0).1, SIMD3(20, 10, 0.2))
        XCTAssertEqual(segment(path, 1).0, SIMD3(30, 30, 0.2))
        XCTAssertEqual(segment(path, 1).1, SIMD3(40, 30, 0.2))
    }

    func testAbsoluteExtrusionCountsFromTheLastReset() throws {
        let path = try parse("""
            M82
            G1 Z0.2
            G92 E0
            G1 X10 E1.0
            G1 X20 E2.0
            G1 X20 E1.2         ; retract
            G1 X30 Y5           ; travel
            G1 X30 E2.0         ; unretract in place
            G92 E0
            G1 X40 E0.5
            """)
        XCTAssertEqual(path.segmentCount, 3)
        XCTAssertEqual(segment(path, 2).1, SIMD3(40, 5, 0.2))
    }

    func testRelativePositioning() throws {
        let path = try parse("""
            M83
            G1 X10 Y10 Z0.2
            G91
            G1 X5 E0.3
            G1 Y5 E0.3
            G90
            """)
        XCTAssertEqual(segment(path, 0).1, SIMD3(15, 10, 0.2))
        XCTAssertEqual(segment(path, 1).1, SIMD3(15, 15, 0.2))
    }

    func testInchesAreConverted() throws {
        let path = try parse("""
            G20
            M83
            G1 X1 Y0 Z0.01
            G1 X2 E0.1
            """)
        XCTAssertEqual(segment(path, 0).1.x, 50.8, accuracy: 1e-4)
    }

    func testArcIsFlattenedOntoItsCircle() throws {
        // A clockwise quarter circle about (10, 0) from (0, 0) to (10, 10): it bulges up-left.
        let path = try parse("""
            M83
            G1 X0 Y0 Z0.2
            G2 X10 Y10 I10 J0 E1.0
            """)
        XCTAssertGreaterThan(path.segmentCount, 6)
        XCTAssertEqual(segment(path, 0).0, SIMD3(0, 0, 0.2))
        XCTAssertEqual(segment(path, path.segmentCount - 1).1, SIMD3(10, 10, 0.2))
        for index in 0..<path.segmentCount {
            let point = segment(path, index).1
            XCTAssertEqual(simd_distance(SIMD2(point.x, point.y), SIMD2(10, 0)), 10, accuracy: 1e-3)
        }
        let middle = segment(path, path.segmentCount / 2).0
        XCTAssertLessThan(middle.x, 10 - 10 * Float(0.5).squareRoot() + 0.5)
        XCTAssertGreaterThan(middle.y, 5)
    }

    func testCounterclockwiseArcGoesTheOtherWay() throws {
        // The same end points anticlockwise about (10, 0) go the long way, below the x axis.
        let path = try parse("""
            M83
            G1 X0 Y0 Z0.2
            G3 X10 Y10 I10 J0 E1.0
            """)
        let lowest = path.points.map(\.y).min() ?? 0
        XCTAssertEqual(lowest, -10, accuracy: 0.1)
    }

    // MARK: - Labels, layers and tools

    func testFeatureLabelsFromEachSlicer() throws {
        let path = try parse("""
            M83
            G1 Z0.2
            ;TYPE:External perimeter
            G1 X1 E0.1
            ; FEATURE: Sparse infill
            G1 X2 E0.1
            ;TYPE:WALL-INNER
            G1 X3 E0.1
            ;TYPE:Something new
            G1 X4 E0.1
            ;TYPE:Support material interface
            G1 X5 E0.1
            ; FEATURE: Floating vertical shell
            G1 X6 E0.1
            """)
        XCTAssertEqual(path.features, [.outerWall, .sparseInfill, .innerWall, .other, .supportInterface, .solidInfill])
    }

    func testLayersFollowTheSlicersMarkers() throws {
        // A z-hop between layers doesn't extrude, so it can't start a layer; the markers decide.
        let path = try parse("""
            M83
            ;LAYER_CHANGE
            G1 Z0.2
            G1 X10 E1
            G1 X20 E1
            ;LAYER_CHANGE
            G1 Z0.6
            G1 Z0.4
            G1 X10 E1
            G1 Z0.41 X0 E1     ; vase mode climbs within a layer
            """)
        XCTAssertEqual(path.layers, [.init(z: 0.2, segments: 0..<2), .init(z: 0.4, segments: 2..<4)])
    }

    func testPurgeLineBeforeTheFirstMarkerJoinsTheFirstLayer() throws {
        let path = try parse("""
            M83
            G1 Z0.2
            ;TYPE:Custom
            G1 X60 E9          ; purge
            ;LAYER_CHANGE
            ;TYPE:Skirt/Brim
            G1 X70 Y10 E1
            ;LAYER_CHANGE
            G1 Z0.4
            G1 X80 E1
            """)
        XCTAssertEqual(path.layers, [.init(z: 0.2, segments: 0..<2), .init(z: 0.4, segments: 2..<3)])
    }

    func testLayersFromHeightWithoutMarkers() throws {
        let path = try parse("""
            M83
            G1 Z0.2
            G1 X10 E1
            G1 Z0.8            ; hop
            G1 X0 Y5
            G1 Z0.2
            G1 X10 E1
            G1 Z0.4
            G1 X0 E1
            """)
        XCTAssertEqual(path.layers, [.init(z: 0.2, segments: 0..<2), .init(z: 0.4, segments: 2..<3)])
    }

    func testToolChanges() throws {
        let path = try parse("""
            M83
            G1 Z0.2
            G1 X1 E0.1
            T1
            G1 X2 E0.1
            M620 S2A
            G1 X3 E0.1
            M620 S255
            T255
            G1 X4 E0.1
            """)
        XCTAssertEqual(path.tools, [0, 1, 2, 2])
    }

    // MARK: - What the slicer says

    func testPrusaSlicerFooter() throws {
        let path = try parse("""
            ; generated by PrusaSlicer 2.4.2+win64 on 2022-10-04 at 21:13:16 UTC
            M83
            G1 Z0.2
            ;TYPE:Perimeter
            G1 X10 E1
            ; filament used [g] = 32.50
            ; total filament used [g] = 32.50
            ; estimated printing time (normal mode) = 5h 21m 52s
            ; bed_shape = 5x0,215x0,215x220,5x220
            ; extruder_colour = #FCE94F
            ; filament_colour = #DDDDDD
            ; filament_type = PLA
            ; fill_density = 20%
            ; layer_height = 0.16
            ; nozzle_diameter = 0.4
            ; printer_model = ENDER3V2
            ; printer_settings_id = Creality Ender-3 V2 - CRTouch
            ; support_material = 0
            """)
        XCTAssertEqual(path.slicer, "PrusaSlicer 2.4.2+win64")
        XCTAssertEqual(path.estimate, SliceEstimate(printSeconds: 5 * 3600 + 21 * 60 + 52, filamentGrams: 32.5))
        XCTAssertEqual(path.filamentColors, [SIMD4<Float>(0xFC, 0xE9, 0x4F, 0xFF) / 255])
        XCTAssertEqual(path.printSettings?.summary,
                       ["Creality Ender-3 V2 - CRTouch", "0.4 mm nozzle", "0.16 mm layers", "PLA", "20% infill"])
        XCTAssertEqual(path.printSettings?.bedSize, SIMD2<Float>(210, 220))
    }

    func testBambuStudioHeaderAndConfig() throws {
        let path = try parse("""
            ; HEADER_BLOCK_START
            ; BambuStudio 02.08.02.61
            ; model printing time: 1h 23m 27s; total estimated time: 1h 29m 37s
            ; total filament weight [g] : 41.36
            ; HEADER_BLOCK_END
            ; CONFIG_BLOCK_START
            ; enable_support = 1
            ; extruder_colour = #018001
            ; filament_colour = #FFFF00;#F6F6F2
            ; filament_type = PLA;PETG
            ; layer_height = 0.16
            ; nozzle_diameter = 0.4
            ; printable_area = 0x0,256x0,256x256,0x256
            ; printer_model = Bambu Lab P1S
            ; printer_settings_id = Bambu Lab P1S 0.4HS nozzle - My copy
            ; sparse_infill_density = 15%
            ; CONFIG_BLOCK_END
            M83
            ; CHANGE_LAYER
            G1 Z0.2
            ; FEATURE: Outer wall
            G1 X10 E1
            """)
        XCTAssertEqual(path.slicer, "BambuStudio 02.08.02.61")
        XCTAssertEqual(path.estimate, SliceEstimate(printSeconds: 3600 + 29 * 60 + 37, filamentGrams: 41.36))
        XCTAssertEqual(path.filamentColors, [SIMD4<Float>(1, 1, 0, 1), SIMD4<Float>(0xF6, 0xF6, 0xF2, 0xFF) / 255],
                       "the filaments, not the nozzle's extruder_colour")
        XCTAssertEqual(path.printSettings?.summary,
                       ["Bambu Lab P1S", "0.4 mm nozzle", "0.16 mm layers", "PLA, PETG", "15% infill", "Supports"])
        XCTAssertEqual(path.printSettings?.bedSize, SIMD2<Float>(256, 256))
    }

    func testCuraTime() throws {
        let path = try parse("""
            ;FLAVOR:Marlin
            ;TIME:6023
            ;Generated with Cura_SteamEngine 5.4.0
            M83
            ;LAYER:0
            G1 Z0.2
            ;TYPE:WALL-OUTER
            G1 X10 E1
            """)
        XCTAssertEqual(path.slicer, "Cura_SteamEngine 5.4.0")
        XCTAssertEqual(path.estimate?.printSeconds, 6023)
        XCTAssertNil(path.printSettings)
    }

    func testBinaryGCodeIsRefused() {
        XCTAssertThrowsError(try GCodeParser.parse(Data("GCDE\u{1}\0\0\0".utf8))) { error in
            XCTAssertEqual(error as? GCodeParser.ParseError, .binaryGCode)
        }
    }

    func testDurations() {
        XCTAssertEqual(GCodeParser.parseDuration("1d 2h 3m 4s"), 93_784)
        XCTAssertEqual(GCodeParser.parseDuration("40m 26s"), 2426)
        XCTAssertEqual(GCodeParser.parseDuration(" 33s"), 33)
        XCTAssertNil(GCodeParser.parseDuration("soon"))
    }

    func testCarriageReturnsAndTightlyPackedWords() throws {
        let path = try parse("M83\r\nG1Z0.2\r\nG1X10Y0E1.5\r\n;TYPE:Gap fill\r\nG1X20E.5\r\n")
        XCTAssertEqual(path.segmentCount, 2)
        XCTAssertEqual(path.features.last, .gapFill)
        XCTAssertEqual(segment(path, 1).1, SIMD3(20, 0, 0.2))
    }

    // MARK: - Embedded thumbnails

    /// A thumbnail block holding `bytes`, its base64 split over lines the way slicers wrap it.
    private func thumbnailBlock(_ format: String, _ size: String, _ bytes: String) -> String {
        let base64 = Data(bytes.utf8).base64EncodedString()
        var lines = ["; thumbnail\(format) begin \(size) \(base64.count)"]
        var rest = Substring(base64)
        while !rest.isEmpty {
            lines.append("; " + rest.prefix(8))
            rest = rest.dropFirst(8)
        }
        lines.append("; thumbnail\(format) end")
        return lines.joined(separator: "\n")
    }

    private func thumbnail(_ gcode: String) -> GCodeParser.EmbeddedThumbnail? {
        GCodeParser.embeddedThumbnail(in: Data(gcode.utf8))
    }

    func testLargestReadableThumbnailIsChosen() throws {
        let gcode = [
            "; generated by PrusaSlicer 2.9.0 on 2026-11-13",
            thumbnailBlock("", "16x16", "tiny png"),
            thumbnailBlock("_QOI", "640x480", "qoi is unreadable"),
            thumbnailBlock("_JPG", "300x300", "a jpeg, the biggest readable one"),
            thumbnailBlock("", "220x124", "medium png"),
            "G1 X0 Y0",
        ].joined(separator: "\n")
        let found = try XCTUnwrap(thumbnail(gcode))
        XCTAssertEqual(found.width, 300)
        XCTAssertEqual(found.height, 300)
        XCTAssertEqual(String(decoding: found.data, as: UTF8.self), "a jpeg, the biggest readable one")
    }

    func testBambuThumbnailBlock() throws {
        let gcode = """
            ; HEADER_BLOCK_START
            ; BambuStudio 02.08.02.61
            ; HEADER_BLOCK_END

            ; THUMBNAIL_BLOCK_START
            \(thumbnailBlock("", "512x512", "bambu png"))
            ; THUMBNAIL_BLOCK_END
            """
        XCTAssertEqual(thumbnail(gcode)?.width, 512)
    }

    func testNoThumbnail() {
        XCTAssertNil(thumbnail("; generated by PrusaSlicer\nG28\nG1 X10 E1\n"))
        XCTAssertNil(thumbnail("GCDE binary"))
    }

    func testThumbnailAfterTheMovesBeginIsIgnored() {
        XCTAssertNil(thumbnail("G28\n" + thumbnailBlock("", "300x300", "too late")))
    }

    func testThumbnailWithWindowsLineEndings() throws {
        let gcode = ("; generated by PrusaSlicer\n" + thumbnailBlock("", "300x300", "a png") + "\nG28\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let found = try XCTUnwrap(thumbnail(gcode))
        XCTAssertEqual(String(decoding: found.data, as: UTF8.self), "a png")
    }

    func testOnlyQOIThumbnailIsNone() {
        XCTAssertNil(thumbnail(thumbnailBlock("_QOI", "480x272", "qoi") + "\nG28\n"))
    }

    func testUnfinishedThumbnailIsIgnored() {
        let block = thumbnailBlock("", "300x300", "cut off by the search limit")
        XCTAssertNil(thumbnail(String(block.split(separator: "\n").dropLast().joined(separator: "\n"))))
    }

    func testGCodeFileExtensions() {
        XCTAssertTrue(GCodeParser.isGCode(URL(fileURLWithPath: "/tmp/Benchy.gcode")))
        XCTAssertTrue(GCodeParser.isGCode(URL(fileURLWithPath: "/tmp/BENCHY.GCO")))
        XCTAssertFalse(GCodeParser.isGCode(URL(fileURLWithPath: "/tmp/Benchy.3mf")))
        XCTAssertFalse(GCodeParser.isGCode(URL(fileURLWithPath: "/tmp/Benchy.bgcode")))
    }

    func testPrimingLineIsNotPartOfThePrint() throws {
        let path = try parse("""
            G90
            M83
            ;TYPE:Custom
            G1 X0 Y-3 Z0.3
            G1 X100 E10 ; prime the nozzle
            ;LAYER_CHANGE
            ;TYPE:External perimeter
            G1 X40 Y40 Z0.2
            G1 X50 E1
            G1 Y50 E1
            """)
        XCTAssertEqual(path.segmentCount, 3)
        XCTAssertEqual(path.printStart, 1)
        XCTAssertEqual(path.printedSegments(of: path.layers[0]), 1..<3)
        // The layer takes its height from the print, not the priming line at Z0.3.
        XCTAssertEqual(path.layers[0].z, 0.2)
        // Nor is the priming line drawn: two tubes, one for each wall line.
        XCTAssertEqual(ToolpathGeometry.plan(path).tubeCount, 2)
        let bounds = try XCTUnwrap(path.bounds)
        XCTAssertEqual(bounds.min, SIMD3(40, 40, 0.2))
        XCTAssertEqual(bounds.max, SIMD3(50, 50, 0.2))
    }

    func testUnlabelledPrintIsAllPrinted() throws {
        let path = try parse("G90\nM83\nG1 X0 Y0 Z0.2\nG1 X10 E1\n")
        XCTAssertEqual(path.printStart, 0)
        XCTAssertEqual(path.bounds?.max, SIMD3(10, 0, 0.2))
    }

    // MARK: - Size limit

    func testReadingStopsPastTheSegmentLimit() throws {
        let gcode = "M83\nG1 Z0.2\nG1 X10 E1\nG1 Y10 E1\nG1 X0 E1\n"
        XCTAssertThrowsError(try GCodeParser.parse(Data(gcode.utf8), segmentLimit: 2)) { error in
            XCTAssertEqual(error as? GCodeParser.ParseError, .tooLarge)
        }
        XCTAssertEqual(try GCodeParser.parse(Data(gcode.utf8), segmentLimit: 3).segmentCount, 3)
    }
}
