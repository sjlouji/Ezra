import SwiftUI

/// Every list icon, drawn in code so it scales and recolours with the theme.
struct ListIcon: View {
    enum Kind: Equatable {
        case list(SmartList)
        /// A project: an outlined circle whose inside fills as its to-dos get done.
        case pie(progress: Double, tint: Color)
        case cube
        case moon
        case star
    }

    let kind: Kind
    var size: CGFloat = 20

    init(_ kind: Kind, size: CGFloat = 20) {
        self.kind = kind
        self.size = size
    }

    init(_ list: SmartList, size: CGFloat = 20) {
        self.init(.list(list), size: size)
    }

    var body: some View {
        if case .pie(let progress, let tint) = kind {
            ZStack {
                Circle().strokeBorder(tint, lineWidth: size * 0.09).padding(size * 0.06)
                PieSector(progress: min(max(progress, 0), 1)).fill(tint).padding(size * 0.25)
            }
            .frame(width: size, height: size)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: progress)
            .accessibilityHidden(true)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        Canvas { context, canvasSize in
            let box = CGRect(origin: .zero, size: canvasSize).insetBy(dx: canvasSize.width * 0.06, dy: canvasSize.height * 0.06)
            switch kind {
            case .list(.inbox): Self.tray(&context, box)
            case .list(.today), .star: Self.star(&context, box, Brand.Palette.today)
            case .list(.upcoming): Self.calendar(&context, box)
            case .list(.anytime): Self.stack(&context, box)
            case .list(.someday): Self.archiveBox(&context, box)
            case .list(.logbook): Self.book(&context, box)
            case .pie: break // drawn with shapes above, so it can animate
            case .cube: Self.cube(&context, box)
            case .moon: Self.moon(&context, box)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func point(_ box: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + box.width * x, y: box.minY + box.height * y)
    }

    private static func polygon(_ box: CGRect, _ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        path.addLines(points.map { point(box, $0.0, $0.1) })
        path.closeSubpath()
        return path
    }

    private static func rounded(_ box: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat) -> Path {
        let rect = CGRect(x: box.minX + box.width * x, y: box.minY + box.height * y, width: box.width * w, height: box.height * h)
        return Path(roundedRect: rect, cornerRadius: box.width * radius, style: .continuous)
    }

    private static func tray(_ context: inout GraphicsContext, _ box: CGRect) {
        context.fill(rounded(box, 0.02, 0.1, 0.96, 0.8, radius: 0.2), with: .color(Brand.Palette.inbox))
        var lip = Path()
        lip.move(to: point(box, 0.02, 0.56))
        lip.addLine(to: point(box, 0.32, 0.56))
        lip.addQuadCurve(to: point(box, 0.68, 0.56), control: point(box, 0.5, 0.86))
        lip.addLine(to: point(box, 0.98, 0.56))
        context.stroke(lip, with: .color(.white), style: StrokeStyle(lineWidth: box.width * 0.09, lineCap: .round, lineJoin: .round))
    }

    static func starPath(in box: CGRect) -> Path {
        let center = CGPoint(x: box.midX, y: box.midY + box.height * 0.04)
        let outer = box.width * 0.52
        var path = Path()
        for index in 0..<10 {
            let radius = index.isMultiple(of: 2) ? outer : outer * 0.46
            let angle = Double(index) * .pi / 5 - .pi / 2
            let vertex = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            index == 0 ? path.move(to: vertex) : path.addLine(to: vertex)
        }
        path.closeSubpath()
        return path
    }

    private static func star(_ context: inout GraphicsContext, _ box: CGRect, _ color: Color) {
        let path = starPath(in: box)
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: box.width * 0.1, lineJoin: .round))
    }

    private static func calendar(_ context: inout GraphicsContext, _ box: CGRect) {
        context.fill(rounded(box, 0.04, 0.06, 0.92, 0.88, radius: 0.2), with: .color(Brand.Palette.upcoming))
        context.fill(rounded(box, 0.04, 0.06, 0.92, 0.2, radius: 0.1), with: .color(.black.opacity(0.14)))
        for row in 0..<2 {
            for column in 0..<3 {
                let dot = CGRect(
                    x: box.minX + box.width * (0.22 + 0.22 * CGFloat(column)),
                    y: box.minY + box.height * (0.42 + 0.24 * CGFloat(row)),
                    width: box.width * 0.13, height: box.width * 0.13
                )
                context.fill(Path(ellipseIn: dot), with: .color(.white))
            }
        }
    }

    private static func stack(_ context: inout GraphicsContext, _ box: CGRect) {
        let tint = Brand.Palette.anytime
        for (index, opacity) in [0.35, 0.6, 1.0].enumerated() {
            let lift = 0.24 * CGFloat(2 - index)
            let layer = polygon(box, [(0.5, 0.08 + lift), (0.98, 0.3 + lift), (0.5, 0.52 + lift), (0.02, 0.3 + lift)])
            context.fill(layer, with: .color(.white))
            context.fill(layer, with: .color(tint.opacity(opacity)))
            context.stroke(layer, with: .color(.white), style: StrokeStyle(lineWidth: box.width * 0.05, lineJoin: .round))
        }
    }

    private static func archiveBox(_ context: inout GraphicsContext, _ box: CGRect) {
        let tint = Brand.Palette.someday
        context.fill(rounded(box, 0.08, 0.32, 0.84, 0.6, radius: 0.12), with: .color(tint))
        context.fill(rounded(box, 0.0, 0.1, 1.0, 0.26, radius: 0.1), with: .color(tint))
        context.fill(rounded(box, 0.0, 0.3, 1.0, 0.06, radius: 0), with: .color(.white.opacity(0.55)))
        context.fill(rounded(box, 0.34, 0.5, 0.32, 0.1, radius: 0.05), with: .color(.white))
    }

    private static func book(_ context: inout GraphicsContext, _ box: CGRect) {
        context.fill(rounded(box, 0.06, 0.04, 0.88, 0.92, radius: 0.16), with: .color(Brand.Palette.logbook))
        context.fill(rounded(box, 0.06, 0.04, 0.16, 0.92, radius: 0.08), with: .color(.black.opacity(0.16)))
        var check = Path()
        check.move(to: point(box, 0.36, 0.52))
        check.addLine(to: point(box, 0.5, 0.66))
        check.addLine(to: point(box, 0.78, 0.34))
        context.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: box.width * 0.11, lineCap: .round, lineJoin: .round))
    }

    private static func cube(_ context: inout GraphicsContext, _ box: CGRect) {
        let grey = Brand.Palette.secondary
        let faces: [([(CGFloat, CGFloat)], Double)] = [
            ([(0.5, 0.04), (0.94, 0.27), (0.5, 0.5), (0.06, 0.27)], 0.55),
            ([(0.06, 0.27), (0.5, 0.5), (0.5, 0.98), (0.06, 0.75)], 1.0),
            ([(0.94, 0.27), (0.5, 0.5), (0.5, 0.98), (0.94, 0.75)], 0.78),
        ]
        for (points, opacity) in faces {
            let face = polygon(box, points)
            context.fill(face, with: .color(grey.opacity(opacity)))
            context.stroke(face, with: .color(.white), style: StrokeStyle(lineWidth: box.width * 0.05, lineJoin: .round))
        }
    }

    private static func moon(_ context: inout GraphicsContext, _ box: CGRect) {
        let disc = Path(ellipseIn: box.insetBy(dx: box.width * 0.06, dy: box.height * 0.06))
        let bite = Path(ellipseIn: box.insetBy(dx: box.width * 0.1, dy: box.height * 0.1).offsetBy(dx: box.width * 0.3, dy: -box.height * 0.2))
        context.fill(disc.subtracting(bite), with: .color(Brand.Palette.evening))
    }
}

/// The filled part of a project's pie; `progress` animates.
private struct PieSector: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard progress > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * progress), clockwise: false)
        path.closeSubpath()
        return path
    }
}
