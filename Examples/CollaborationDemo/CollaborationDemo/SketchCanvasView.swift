import SwiftUI

/// A drawing surface backed by ``DemoSketch``. The user can draw freehand
/// strokes; the assistant can add/remove shapes and change the background
/// through the ``DemoSketch`` collaboration tools.
struct SketchCanvasView: View {
    @Bindable var sketch: DemoSketch

    @State private var brushColor: SketchColor = .black
    @State private var brushWidth: Double = 0.006
    @State private var inProgress: [SketchPoint] = []

    var body: some View {
        VStack(spacing: 0) {
            palette
            Divider()
            canvas
        }
    }

    // MARK: - Palette

    @ViewBuilder private var palette: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(SketchColor.allCases, id: \.self) { color in
                    Button {
                        brushColor = color
                    } label: {
                        Circle()
                            .fill(swatch(for: color))
                            .overlay(
                                Circle().stroke(
                                    color == brushColor ? Color.accentColor : .secondary.opacity(0.4),
                                    lineWidth: color == brushColor ? 2 : 0.5
                                )
                            )
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(color.rawValue.capitalized)
                }
            }

            Slider(value: $brushWidth, in: 0.001...0.03) {
                Text("Brush width")
            }
            .frame(width: 120)

            Button {
                if !sketch.shapes.isEmpty { sketch.shapes.removeLast() }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(sketch.shapes.isEmpty)

            Button(role: .destructive) {
                sketch.shapes.removeAll()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(sketch.shapes.isEmpty && inProgress.isEmpty)

            Spacer()

            Picker("Background", selection: $sketch.background) {
                ForEach(SketchColor.allCases, id: \.self) { color in
                    Text(color.rawValue.capitalized).tag(color)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Canvas

    @ViewBuilder private var canvas: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let rect = squareRect(in: size)
                context.fill(Path(rect), with: .color(swatch(for: sketch.background)))
                context.stroke(Path(rect), with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                for shape in sketch.shapes {
                    draw(shape, into: &context, in: rect)
                }
                if !inProgress.isEmpty {
                    draw(
                        SketchShape(
                            id: "__preview",
                            kind: .freehand,
                            color: brushColor,
                            width: brushWidth,
                            points: inProgress
                        ),
                        into: &context,
                        in: rect
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(canvasSize: proxy.size))
        }
        .padding(12)
    }

    private func drawGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let point = unitize(value.location, in: canvasSize) {
                    inProgress.append(point)
                }
            }
            .onEnded { _ in
                let points = inProgress
                inProgress = []
                guard points.count >= 2 else { return }
                let id: SketchShape.ID = "s\(sketch.nextID)"
                sketch.nextID += 1
                sketch.shapes.append(
                    SketchShape(
                        id: id,
                        kind: .freehand,
                        color: brushColor,
                        width: brushWidth,
                        points: points
                    )
                )
            }
    }

    // MARK: - Geometry

    private func squareRect(in size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        let originX = (size.width - side) / 2
        let originY = (size.height - side) / 2
        return CGRect(x: originX, y: originY, width: side, height: side)
    }

    private func unitize(_ location: CGPoint, in canvasSize: CGSize) -> SketchPoint? {
        let rect = squareRect(in: canvasSize)
        guard rect.width > 0 else { return nil }
        return SketchPoint(
            x: (location.x - rect.minX) / rect.width,
            y: (location.y - rect.minY) / rect.height
        )
    }

    private func project(_ point: SketchPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }

    // MARK: - Drawing

    private func draw(_ shape: SketchShape, into context: inout GraphicsContext, in rect: CGRect) {
        var path = Path()
        switch shape.kind {
        case .freehand:
            guard let first = shape.points.first else { return }
            path.move(to: project(first, in: rect))
            for point in shape.points.dropFirst() {
                path.addLine(to: project(point, in: rect))
            }

        case .line:
            guard shape.points.count >= 2 else { return }
            path.move(to: project(shape.points[0], in: rect))
            path.addLine(to: project(shape.points[1], in: rect))

        case .rectangle:
            guard shape.points.count >= 2 else { return }
            path.addRect(box(from: shape.points, in: rect))

        case .ellipse:
            guard shape.points.count >= 2 else { return }
            path.addEllipse(in: box(from: shape.points, in: rect))
        }
        let lineWidth = max(1, shape.width * rect.width)
        context.stroke(
            path,
            with: .color(swatch(for: shape.color)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func box(from points: [SketchPoint], in rect: CGRect) -> CGRect {
        let a = project(points[0], in: rect)
        let b = project(points[1], in: rect)
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    // MARK: - Color mapping

    private func swatch(for color: SketchColor) -> Color {
        switch color {
        case .black:
            .black

        case .gray:
            .gray

        case .white:
            .white

        case .red:
            .red

        case .orange:
            .orange

        case .yellow:
            .yellow

        case .green:
            .green

        case .blue:
            .blue

        case .purple:
            .purple

        case .pink:
            .pink
        }
    }
}

#Preview("Empty") {
    SketchCanvasView(sketch: DemoSketch())
        .frame(width: 520, height: 520)
}

#Preview("Populated") {
    let sketch = DemoSketch()
    _ = sketch.addRectangle(x: 0.1, y: 0.1, width: 0.8, height: 0.8, color: .blue, strokeWidth: 0.006)
    _ = sketch.addEllipse(x: 0.2, y: 0.2, width: 0.6, height: 0.6, color: .red, strokeWidth: 0.006)
    _ = sketch.addLine(x1: 0.1, y1: 0.1, x2: 0.9, y2: 0.9, color: .green, width: 0.004)
    return SketchCanvasView(sketch: sketch)
        .frame(width: 520, height: 520)
}
