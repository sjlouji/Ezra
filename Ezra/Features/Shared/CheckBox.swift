import SwiftUI

/// The rounded-square checkbox of a to-do, or the circle of a checklist item.
struct CheckBox: View {
    let checked: Bool
    var circle = false
    var size: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : size * 0.26, style: .continuous)
        ZStack {
            // A to-do's box is a thin grey outline; a checklist item's circle is blue.
            shape.strokeBorder(circle ? Brand.Palette.accent.opacity(checked ? 0 : 1) : Brand.Palette.secondary.opacity(checked ? 0 : 0.6), lineWidth: circle ? 1.5 : 1)
            shape.fill(Brand.Palette.accent)
                .scaleEffect(checked ? 1 : 0.4)
                .opacity(checked ? 1 : 0)
            // The tick is drawn in, as if by pen.
            Path { path in
                path.move(to: CGPoint(x: size * 0.26, y: size * 0.52))
                path.addLine(to: CGPoint(x: size * 0.43, y: size * 0.69))
                path.addLine(to: CGPoint(x: size * 0.75, y: size * 0.32))
            }
            .trim(from: 0, to: checked ? 1 : 0)
            .stroke(.white, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: checked)
        .contentShape(.rect)
        .accessibilityLabel(checked ? "Completed" : "Not completed")
    }
}

/// Shows a view for one half of the open animation only. The read-only title and its editor swap at
/// the midpoint, both riding the same motion, rather than fading through each other.
struct StepOpacity: ViewModifier, Animatable {
    var progress: Double
    let visibleWhenOpen: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity((progress > 0.5) == visibleWhenOpen ? 1 : 0)
    }
}
