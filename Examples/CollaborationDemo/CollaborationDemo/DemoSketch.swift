import CollaborationKit
import Foundation
import Observation

/// A palette of named colors both the user and the assistant can reference.
enum SketchColor: String, Codable, CollaborationSchemaConvertible, CaseIterable, Sendable {
    case black, gray, white, red, orange, yellow, green, blue, purple, pink

    static let collaborationSchema: JSONValue = .object([
        "type": .string("string"),
        "enum": .array(allCases.map { .string($0.rawValue) })
    ])
}

/// A point in the canvas's 0–1 unit square. The origin is the top-left; the
/// canvas is drawn square so `x == y` traces the diagonal.
struct SketchPoint: Codable, Sendable, Equatable, CollaborationSchemaConvertible {
    var x: Double
    var y: Double

    static let collaborationSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "x": .object(["type": .string("number")]),
            "y": .object(["type": .string("number")])
        ]),
        "required": .array([.string("x"), .string("y")])
    ])
}

enum SketchShapeKind: String, Codable, CaseIterable, Sendable {
    case freehand, line, rectangle, ellipse
}

struct SketchShape: Identifiable, Codable, Sendable, Equatable {
    typealias ID = String // swiftlint:disable:this type_name
    let id: ID
    var kind: SketchShapeKind
    var color: SketchColor
    var width: Double
    var points: [SketchPoint]
}

@MainActor
@Observable
@CollaborationTools
final class DemoSketch {
    var shapes: [SketchShape] = []
    var background: SketchColor = .white
    var nextID: Int = 1

    /// List every shape on the canvas, oldest first.
    @CollaborationTool
    func list() -> [SketchShape] {
        shapes
    }

    /// Set the canvas background color.
    @CollaborationTool
    func setBackground(color: SketchColor) {
        background = color
    }

    /// Draw a straight line from (x1, y1) to (x2, y2). Coordinates are in the
    /// 0–1 unit square (top-left origin). Returns the new shape's id.
    @CollaborationTool
    func addLine(
        x1: Double, y1: Double,
        x2: Double, y2: Double,
        color: SketchColor,
        width: Double
    ) -> SketchShape.ID {
        addShape(kind: .line, color: color, width: width, points: [
            SketchPoint(x: x1, y: y1),
            SketchPoint(x: x2, y: y2)
        ])
    }

    /// Draw a rectangle outline whose top-left is (x, y) with the given size.
    /// Coordinates are in the 0–1 unit square. Returns the new shape's id.
    @CollaborationTool
    func addRectangle(
        x: Double, y: Double,
        width: Double, height: Double,
        color: SketchColor,
        strokeWidth: Double
    ) -> SketchShape.ID {
        addShape(kind: .rectangle, color: color, width: strokeWidth, points: [
            SketchPoint(x: x, y: y),
            SketchPoint(x: x + width, y: y + height)
        ])
    }

    /// Draw an ellipse inscribed in the box with top-left (x, y) and the
    /// given size. Coordinates are in the 0–1 unit square. Returns the new
    /// shape's id.
    @CollaborationTool
    func addEllipse(
        x: Double, y: Double,
        width: Double, height: Double,
        color: SketchColor,
        strokeWidth: Double
    ) -> SketchShape.ID {
        addShape(kind: .ellipse, color: color, width: strokeWidth, points: [
            SketchPoint(x: x, y: y),
            SketchPoint(x: x + width, y: y + height)
        ])
    }

    /// Draw a freehand path connecting the given points in order.
    /// Coordinates are in the 0–1 unit square. Returns the new shape's id.
    @CollaborationTool
    func addPath(
        points: [SketchPoint],
        color: SketchColor,
        width: Double
    ) -> SketchShape.ID {
        addShape(kind: .freehand, color: color, width: width, points: points)
    }

    /// Remove the most recently added shape.
    @CollaborationTool
    func undo() throws {
        guard !shapes.isEmpty else {
            throw ToolError("Canvas is empty.")
        }
        shapes.removeLast()
    }

    /// Delete one shape by id.
    @CollaborationTool
    func delete(id: SketchShape.ID) throws {
        guard let index = shapes.firstIndex(where: { $0.id == id }) else {
            throw ToolError("No shape with id \(id).")
        }
        shapes.remove(at: index)
    }

    /// Erase every shape on the canvas.
    @CollaborationTool(requiresApproval: true)
    func clear() {
        shapes.removeAll()
    }

    @discardableResult
    private func addShape(
        kind: SketchShapeKind,
        color: SketchColor,
        width: Double,
        points: [SketchPoint]
    ) -> SketchShape.ID {
        let id: SketchShape.ID = "s\(nextID)"
        nextID += 1
        shapes.append(SketchShape(id: id, kind: kind, color: color, width: width, points: points))
        return id
    }
}
