import SwiftUI
import ARKit

/// Renders scanned room polygons as a 2D floor plan with wall dimensions and area labels.
/// Supports pinch-to-zoom and drag-to-pan.
struct FloorPlanView: View {
    let rooms: [FloorPlanRoom]
    let onTapRoom: ((FloorPlanRoom) -> Void)?

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let fitting = fitTransform(viewSize: geo.size)

            Canvas { context, size in
                // Apply user pan + zoom on top of the fit-to-view transform
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.translateBy(x: center.x + offset.width, y: center.y + offset.height)
                context.scaleBy(x: scale * fitting.scale, y: scale * fitting.scale)
                context.translateBy(x: -fitting.center.x, y: -fitting.center.y)

                for room in rooms {
                    drawRoom(room, in: &context)
                }
            }
            .gesture(pinchGesture)
            .gesture(dragGesture)
            .simultaneousGesture(tapGesture(viewSize: geo.size, fitting: fitting))
        }
    }

    // MARK: - Drawing

    private func drawRoom(_ room: FloorPlanRoom, in context: inout GraphicsContext) {
        let polygon = room.polygonFt
        guard polygon.count >= 3 else { return }

        let points = polygon.map { CGPoint(x: $0[0], y: $0[1]) }

        // Fill
        var path = Path()
        path.move(to: points[0])
        for pt in points.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        context.fill(path, with: .color(.blue.opacity(0.08)))
        context.stroke(path, with: .color(.blue), lineWidth: 2 / (scale * 30))

        // Wall dimension labels on each edge
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            let midX = (a.x + b.x) / 2
            let midY = (a.y + b.y) / 2

            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthFt = sqrt(dx * dx + dy * dy)
            let label = formatFeetInches(lengthFt)

            let fontSize = max(0.3, 0.5 / scale)
            let text = Text(label)
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
            let resolved = context.resolve(text)

            // Offset label perpendicular to edge
            let norm = CGPoint(x: -dy, y: dx)
            let normLen = sqrt(norm.x * norm.x + norm.y * norm.y)
            let offsetDist: CGFloat = 0.4
            let labelPt = CGPoint(
                x: midX + (normLen > 0 ? norm.x / normLen * offsetDist : 0),
                y: midY + (normLen > 0 ? norm.y / normLen * offsetDist : 0)
            )

            context.draw(resolved, at: labelPt, anchor: .center)
        }

        // Area label centered in polygon
        let centroid = polygonCentroid(points)
        if let area = room.areaSqft {
            let areaText = Text("\(Int(area)) sq ft")
                .font(.system(size: max(0.5, 0.8 / scale), weight: .bold))
                .foregroundColor(.blue)
            context.draw(context.resolve(areaText), at: centroid, anchor: .center)
        }

        // Room label above centroid
        let labelText = Text(room.label)
            .font(.system(size: max(0.4, 0.6 / scale), weight: .semibold))
            .foregroundColor(.secondary)
        let labelPt = CGPoint(x: centroid.x, y: centroid.y - max(0.6, 1.0 / scale))
        context.draw(context.resolve(labelText), at: labelPt, anchor: .center)
    }

    // MARK: - Geometry

    private func polygonCentroid(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(points.count)
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        return CGPoint(x: sumX / n, y: sumY / n)
    }

    /// Compute scale + center to fit all rooms in the view with padding.
    private func fitTransform(viewSize: CGSize) -> (scale: CGFloat, center: CGPoint) {
        var allPoints: [CGPoint] = []
        for room in rooms {
            allPoints += room.polygonFt.map { CGPoint(x: $0[0], y: $0[1]) }
        }
        guard !allPoints.isEmpty else { return (30, .zero) }

        let minX = allPoints.map(\.x).min()!
        let maxX = allPoints.map(\.x).max()!
        let minY = allPoints.map(\.y).min()!
        let maxY = allPoints.map(\.y).max()!

        let polyW = maxX - minX
        let polyH = maxY - minY
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        let padding: CGFloat = 0.85
        let scaleX = polyW > 0 ? (viewSize.width * padding) / polyW : 30
        let scaleY = polyH > 0 ? (viewSize.height * padding) / polyH : 30
        return (min(scaleX, scaleY), center)
    }

    // MARK: - Formatting

    private func formatFeetInches(_ totalFeet: CGFloat) -> String {
        let feet = Int(totalFeet)
        let inches = Int((totalFeet - CGFloat(feet)) * 12 + 0.5)
        if inches == 0 {
            return "\(feet)'"
        }
        return "\(feet)' \(inches)\""
    }

    // MARK: - Gestures

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = lastScale * value.magnification
            }
            .onEnded { value in
                lastScale = scale
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func tapGesture(viewSize: CGSize, fitting: (scale: CGFloat, center: CGPoint)) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let onTapRoom else { return }
                // Convert tap location back to floor plan coordinates
                let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                let totalScale = scale * fitting.scale
                let fpX = (value.location.x - center.x - offset.width) / totalScale + fitting.center.x
                let fpY = (value.location.y - center.y - offset.height) / totalScale + fitting.center.y

                for room in rooms {
                    let points = room.polygonFt.map { CGPoint(x: $0[0], y: $0[1]) }
                    if pointInPolygon(CGPoint(x: fpX, y: fpY), polygon: points) {
                        onTapRoom(room)
                        return
                    }
                }
            }
    }

    private func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            if (polygon[i].y > point.y) != (polygon[j].y > point.y),
               point.x < (polygon[j].x - polygon[i].x) * (point.y - polygon[i].y)
                / (polygon[j].y - polygon[i].y) + polygon[i].x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

// MARK: - Data Model

struct FloorPlanRoom: Identifiable {
    let id: String          // scan_id
    let label: String       // room label
    let polygonFt: [[Double]]  // [[x, z], ...] in feet
    let areaSqft: Double?
    let scanMeshUrl: String?
}

// MARK: - Sheet Wrapper

struct FloorPlanSheet: View {
    let rooms: [FloorPlanRoom]
    let meshAnchors: [ARMeshAnchor]
    let onTapRoom: ((FloorPlanRoom) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            FloorPlanView(rooms: rooms, onTapRoom: onTapRoom)
                .navigationTitle("Floor Plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
