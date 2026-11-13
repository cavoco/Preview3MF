import XCTest
import SceneKit
import Metal
import simd
@testable import Preview3MF

final class ToolpathGeometryTests: XCTestCase {

    private func parse(_ gcode: String) throws -> GCodeToolpath {
        try GCodeParser.parse(Data(gcode.utf8))
    }

    private func tubes(_ path: GCodeToolpath) -> [(SIMD3<Float>, SIMD3<Float>)] {
        var result: [(SIMD3<Float>, SIMD3<Float>)] = []
        ToolpathGeometry.forEachTube(in: path, segments: 0..<path.segmentCount, dropping: []) { _, a, b in
            result.append((a, b))
        }
        return result
    }

    /// `layers` layers, each one square perimeter of outer wall and `infillLines` lines of
    /// sparse infill, 0.2 mm apart.
    private func squares(layers: Int, infillLines: Int = 0) throws -> GCodeToolpath {
        var gcode = "G90\nM83\n"
        for layer in 0..<layers {
            let z = Double(layer + 1) * 0.2
            gcode += ";LAYER_CHANGE\nG1 Z\(z)\nG1 X0 Y0\n;TYPE:External perimeter\n"
            gcode += "G1 X10 Y0 E1\nG1 X10 Y10 E1\nG1 X0 Y10 E1\nG1 X0 Y0 E1\n"
            gcode += ";TYPE:Internal infill\n"
            for line in 0..<infillLines {
                let y = 1 + Double(line) * 8 / Double(max(infillLines, 1))
                gcode += "G1 X1 Y\(y)\nG1 X9 Y\(y) E1\n"
            }
        }
        return try parse(gcode)
    }

    // MARK: - Merging

    func testStraightPiecesBecomeOneTube() throws {
        let path = try parse("""
            G90
            M83
            G1 X0 Y0 Z0.2
            G1 X1 E0.1
            G1 X2 E0.1
            G1 X3 E0.1
            """)
        XCTAssertEqual(path.segmentCount, 3)
        let merged = tubes(path)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.0, SIMD3(0, 0, 0.2))
        XCTAssertEqual(merged.first?.1, SIMD3(3, 0, 0.2))
    }

    func testCornersFeaturesAndGapsAreNotMerged() throws {
        let path = try parse("""
            G90
            M83
            G1 X0 Y0 Z0.2
            ;TYPE:External perimeter
            G1 X1 E0.1
            G1 X1 Y1 E0.1
            ;TYPE:Perimeter
            G1 X1 Y2 E0.1
            G1 X1 Y3
            G1 X1 Y4 E0.1
            """)
        // Corner; then a feature change; then a travel gap.
        XCTAssertEqual(tubes(path).count, 4)
    }

    func testFlattenedArcStaysCurved() throws {
        // A 20 mm quarter circle: its pieces bend far more than the merge tolerance.
        let path = try parse("""
            G90
            M83
            G1 X20 Y0 Z0.2
            G3 X0 Y20 I-20 J0 E5
            """)
        XCTAssertGreaterThan(path.segmentCount, 10)
        XCTAssertGreaterThan(tubes(path).count, path.segmentCount / 2)
    }

    func testDroppedFeaturesAreSkipped() throws {
        let path = try squares(layers: 1, infillLines: 3)
        var kept = 0
        ToolpathGeometry.forEachTube(in: path, segments: 0..<path.segmentCount,
                                     dropping: [.sparseInfill]) { first, _, _ in
            XCTAssertEqual(path.features[first], .outerWall)
            kept += 1
        }
        XCTAssertEqual(kept, 4)
    }

    // MARK: - Thinning

    func testSmallPrintIsDrawnWhole() throws {
        let path = try squares(layers: 5, infillLines: 4)
        let plan = ToolpathGeometry.plan(path)
        XCTAssertEqual(plan, .init(droppedFeatures: [], layerStride: 1, tubeCount: 5 * 8))
    }

    func testInfillGoesFirstWhenOverBudget() throws {
        let path = try squares(layers: 5, infillLines: 4)
        let plan = ToolpathGeometry.plan(path, budget: 25)
        XCTAssertEqual(plan.droppedFeatures, [.sparseInfill])
        XCTAssertEqual(plan.layerStride, 1)
        XCTAssertEqual(plan.tubeCount, 20)
    }

    func testLayersAreSkippedWhenDroppingFeaturesIsNotEnough() throws {
        let path = try squares(layers: 10, infillLines: 4)
        let plan = ToolpathGeometry.plan(path, budget: 15)
        XCTAssertEqual(plan.droppedFeatures, [.sparseInfill, .innerWall])
        // Every third layer would still be 16 tubes; every fourth is layers 10, 6 and 2
        // counting from the bottom. The top one is always kept.
        XCTAssertEqual(plan.layerStride, 4)
        XCTAssertEqual(plan.tubeCount, 3 * 4)
    }

    func testThinnedPrintKeepsItsTopLayerAndHeight() throws {
        let path = try squares(layers: 10, infillLines: 4)
        let geometry = try XCTUnwrap(ToolpathGeometry.build(path, budget: 15))
        let (lower, upper) = geometry.boundingBox
        // Top of the top layer is the nozzle height; the stretched beads reach the bed but
        // not through it.
        XCTAssertEqual(Float(upper.z), 2.0, accuracy: 1e-4)
        XCTAssertEqual(Float(lower.z), 0, accuracy: 1e-4)
    }

    func testOneLayerOverBudgetIsThinnedWithinTheLayer() throws {
        // Every layer skipped but the top still leaves too much; this used to never return.
        let path = try squares(layers: 1)
        let plan = ToolpathGeometry.plan(path, budget: 3)
        XCTAssertEqual(plan.layerStride, 1)
        XCTAssertEqual(plan.tubeStride, 2)
        XCTAssertEqual(plan.tubeCount, 2)
        let geometry = try XCTUnwrap(ToolpathGeometry.build(path, budget: 3))
        XCTAssertEqual(geometry.elements.first?.primitiveCount, 2 * 8)
    }

    func testStrideStopsAtTheLayerCount() throws {
        let path = try squares(layers: 3)
        let plan = ToolpathGeometry.plan(path, budget: 2)
        XCTAssertEqual(plan.layerStride, 3)
        XCTAssertEqual(plan.tubeStride, 2)
        XCTAssertEqual(plan.tubeCount, 2)
    }

    // MARK: - Geometry

    func testEachTubeIsEightVerticesAndEightTriangles() throws {
        let path = try squares(layers: 2)
        let geometry = try XCTUnwrap(ToolpathGeometry.build(path))
        XCTAssertEqual(geometry.sources(for: .vertex).first?.vectorCount, 8 * 8)
        XCTAssertEqual(geometry.sources(for: .normal).first?.vectorCount, 8 * 8)
        XCTAssertEqual(geometry.sources(for: .color).first?.vectorCount, 8 * 8)
        XCTAssertEqual(geometry.elements.first?.primitiveCount, 8 * 8)
    }

    func testBeadHangsBelowTheNozzleAndIsALineWide() throws {
        let path = try parse("""
            ; layer_height = 0.3
            ; nozzle_diameter = 0.6
            G90
            M83
            G1 X0 Y0 Z0.3
            G1 X10 E1
            """)
        let (width, height) = ToolpathGeometry.beadSize(of: path)
        XCTAssertEqual(height, 0.3, accuracy: 1e-5)
        XCTAssertEqual(width, 0.675, accuracy: 1e-5)

        let geometry = try XCTUnwrap(ToolpathGeometry.build(path))
        let (lower, upper) = geometry.boundingBox
        XCTAssertEqual(Float(upper.z), 0.3, accuracy: 1e-4)
        XCTAssertEqual(Float(lower.z), 0, accuracy: 1e-4)
        XCTAssertEqual(Float(upper.y - lower.y), width, accuracy: 1e-4)
        // Runs half a width past each end, so corners close.
        XCTAssertEqual(Float(lower.x), -width / 2, accuracy: 1e-4)
        XCTAssertEqual(Float(upper.x), 10 + width / 2, accuracy: 1e-4)
    }

    func testLayerHeightFromLayersWithoutSettings() throws {
        // A thicker first layer, then 0.15 mm layers.
        var gcode = "G90\nM83\n;LAYER_CHANGE\nG1 Z0.3\nG1 X0 Y0\nG1 X5 E1\n"
        for layer in 1...4 {
            gcode += ";LAYER_CHANGE\nG1 Z\(0.3 + Double(layer) * 0.15)\nG1 X0 Y0\nG1 X5 E1\n"
        }
        XCTAssertEqual(ToolpathGeometry.beadSize(of: try parse(gcode)).height, 0.15, accuracy: 1e-5)
    }

    func testFacesPointOutwards() throws {
        let path = try parse("G90\nM83\nG1 X0 Y0 Z0.2\nG1 X10 E1\n")
        let geometry = try XCTUnwrap(ToolpathGeometry.build(path))
        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first).data
        let indices = try XCTUnwrap(geometry.elements.first).data
        let vertices: [SIMD3<Float>] = positions.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            return (0..<8).map { SIMD3(floats[$0 * 3], floats[$0 * 3 + 1], floats[$0 * 3 + 2]) }
        }
        let centre = vertices.reduce(.zero, +) / 8
        indices.withUnsafeBytes { raw in
            let index = raw.bindMemory(to: UInt32.self)
            for t in 0..<8 {
                let a = vertices[Int(index[t * 3])], b = vertices[Int(index[t * 3 + 1])]
                let c = vertices[Int(index[t * 3 + 2])]
                let normal = simd_cross(b - a, c - a)
                XCTAssertGreaterThan(simd_dot(normal, (a + b + c) / 3 - centre), 0, "triangle \(t)")
            }
        }
    }

    func testNothingToDrawGivesNoGeometry() throws {
        XCTAssertNil(ToolpathGeometry.build(try parse("G90\nG1 X10 Y10\n")))
    }

    // MARK: - Colour

    func testSingleFilamentIsColouredByFeature() throws {
        let path = try parse("""
            ; extruder_colour = ""
            ; filament_colour = #FF0000
            G90
            M83
            G1 X0 Y0 Z0.2
            G1 X10 E1
            """)
        XCTAssertEqual(ToolpathGeometry.coloring(for: path), .feature)
    }

    func testFilamentChangesAreColouredByFilament() throws {
        let path = try parse("""
            ; filament_colour = #FF0000;#0000FF
            ; generated by PrusaSlicer 2.9.0 on 2026-11-13
            G90
            M83
            G1 X0 Y0 Z0.2
            T0
            G1 X10 E1
            T1
            G1 Y10 E1
            """)
        XCTAssertEqual(ToolpathGeometry.coloring(for: path), .filament)
    }

    func testThinFirstLayerStaysAboveTheBed() throws {
        // A 0.2 mm first layer under 0.28 mm layers.
        let path = try parse("""
            ; layer_height = 0.28
            G90
            M83
            ;LAYER_CHANGE
            G1 X0 Y0 Z0.2
            G1 X10 E1
            ;LAYER_CHANGE
            G1 Z0.48
            G1 X0 E1
            """)
        let geometry = try XCTUnwrap(ToolpathGeometry.build(path))
        XCTAssertEqual(Float(geometry.boundingBox.min.z), 0, accuracy: 1e-4)
    }

    func testFilamentColoursFollowTheTool() throws {
        let path = try parse("""
            ; filament_colour = #FF0000;#0000FF
            ; generated by PrusaSlicer 2.9.0 on 2026-11-13
            G90
            M83
            G1 X0 Y0 Z0.2
            T0
            G1 X10 E1
            T1
            G1 Y10 E1
            T5
            G1 X0 E1
            """)
        let geometry = try XCTUnwrap(ToolpathGeometry.build(path))
        let source = try XCTUnwrap(geometry.sources(for: .color).first)
        let colors: [SIMD4<Float>] = source.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: SIMD4<Float>.self))
        }
        XCTAssertEqual(colors.count, 3 * 8)
        // Linear, like all vertex colours; a tool with no colour of its own is grey.
        XCTAssertEqual(colors[0], SIMD4(1, 0, 0, 1))
        XCTAssertEqual(colors[8], SIMD4(0, 0, 1, 1))
        XCTAssertEqual(colors[16], SceneBuilder.linearComponents(SIMD4(0.75, 0.75, 0.75, 1)))
    }

    func testFeatureColourShowsInTheRender() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        // A solid patch of outer wall, filling the view from above.
        var gcode = "G90\nM83\n;TYPE:External perimeter\n"
        for row in 0...50 {
            gcode += "G1 X0 Y\(Double(row) * 0.4) Z0.2\nG1 X20 E1\n"
        }
        let scene = SceneBuilder.buildScene(from: try parse(gcode), showBuildPlate: false)
        scene.rootNode.enumerateChildNodes { node, _ in node.removeAllActions() }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 64, height: 64), antialiasingMode: .none)
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map(NSBitmapImageRep.init(cgImage:)))
        let centre = try XCTUnwrap(bitmap.colorAt(x: 32, y: 32)?.usingColorSpace(.sRGB))
        // #FF7D38: orange, whatever the lighting does to its brightness.
        XCTAssertGreaterThan(centre.redComponent, centre.greenComponent + 0.15)
        XCTAssertGreaterThan(centre.greenComponent, centre.blueComponent + 0.1)
    }

    // MARK: - Scene

    func testSceneUsesTheBedFromTheSettings() throws {
        let path = try parse("""
            ; bed_shape = 0x0,250x0,250x210,0x210
            G90
            M83
            G1 X100 Y100 Z0.2
            G1 X110 E1
            """)
        XCTAssertEqual(path.printSettings?.bedSize, SIMD2(250, 210))
        let scene = SceneBuilder.buildScene(from: path)
        let turntable = try XCTUnwrap(scene.rootNode.childNode(withName: SceneBuilder.turntableNodeName,
                                                               recursively: false))
        XCTAssertEqual(turntable.childNodes.count, 2, "model and bed")
    }
}
