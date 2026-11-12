import AppKit
import SwiftData
import SwiftUI

/// Two-finger swipes on the trackpad, as on Things for iPhone and iPad: right on a to-do opens When, left selects it,
/// left on a checklist item deletes it. Anywhere else a swipe goes back or forward through the lists visited.
enum Swipe: Equatable {
    case right, left

    /// How far the fingers must travel for a swipe to count, in points.
    static let threshold: CGFloat = 70

    /// The swipe a finished two-finger movement amounts to; nil when it was a scroll or too short.
    static func from(dx: CGFloat, dy: CGFloat) -> Swipe? {
        guard abs(dx) >= threshold, abs(dx) > abs(dy) * 2 else { return nil }
        return dx > 0 ? .right : .left
    }
}

extension AppModel {
    /// How far the row under a swipe in progress has slid, for the to-do it belongs to.
    func swipeOffset(for todo: ToDo) -> CGFloat {
        guard let swiping, swiping.todo == todo else { return 0 }
        // The row follows the fingers a little way, enough to show which way it is going.
        return max(min(swiping.distance * 0.5, 46), -46)
    }

    /// The to-do row under a point in the window, if any.
    func todoRow(at location: CGPoint) -> ToDo? {
        slots.values.first { $0.frame.contains(location) }?.todo
    }

    /// Carries out a finished swipe at a point in the window.
    func swiped(_ swipe: Swipe, at location: CGPoint) {
        if let todo = todoRow(at: location), !todo.isCompleted, card?.todo != todo {
            switch swipe {
            case .right:
                clearSelection()
                pick(.when, for: todo)
            case .left:
                toggleSelection(todo)
            }
        } else if swipe == .left, let line = sortSlots.values.first(where: { $0.frame.contains(location) }), case .checklist(let item) = line.item {
            guard let context else { return Log.store.error("Swipe before the store was attached") }
            Alerts.shared.attempt("delete the checklist item") {
                try withAnimation(Self.spring) {
                    context.delete(item)
                    try context.save()
                }
            }
        } else if swipe == .left, !sidebarHidden, location.x < Self.sidebarWidth {
            // A swipe left over the sidebar pushes it off the edge.
            setSidebar(hidden: true)
        } else if swipe == .right, sidebarHidden, location.x < 160 {
            // A swipe right from the window's left side pulls it back.
            setSidebar(hidden: false)
        } else if card == nil {
            // Fingers moving right pull the previous screen back in, as in Safari and Finder.
            swipe == .right ? goBack() : goForward()
        }
    }

    /// Slides the sidebar away or back.
    func setSidebar(hidden: Bool) {
        withAnimation(.spring(duration: 0.42, bounce: 0.12)) {
            sidebarDrag = nil
            sidebarHidden = hidden
        }
    }

    /// The sidebar's edge is being dragged to `width`.
    func dragSidebar(to width: CGFloat) {
        sidebarDrag = max(0, min(width, Self.sidebarWidth))
    }

    /// The drag ended: the sidebar settles open or shut, whichever it is nearer, or the way a quick flick was heading.
    func endSidebarDrag(predicted width: CGFloat) {
        guard sidebarDrag != nil else { return }
        setSidebar(hidden: width < Self.sidebarWidth / 2)
    }

    /// Notes a screen as visited. Going back and forward moves along this trail without adding to it.
    func visited(_ destination: Destination?) {
        guard let destination, !isRetracing, trail.isEmpty || trail[trailIndex] != destination else { return }
        trail = Array(trail.prefix(trailIndex + 1)) + [destination]
        trailIndex = trail.count - 1
    }

    var canGoBack: Bool { trailIndex > 0 }
    var canGoForward: Bool { trailIndex < trail.count - 1 }

    func goBack() { retrace(to: trailIndex - 1) }
    func goForward() { retrace(to: trailIndex + 1) }

    private func retrace(to index: Int) {
        guard trail.indices.contains(index) else { return }
        closeCard()
        isRetracing = true
        defer { isRetracing = false }
        trailIndex = index
        withAnimation(.easeOut(duration: 0.16)) { destination = trail[index] }
    }
}

/// Watches the trackpad for two-finger sideways swipes in the main window.
@MainActor
enum SwipeMonitor {
    private static var monitor: Any?
    private static var travelled = CGSize.zero
    private static var fired = false

    static func install(for app: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only a finger gesture has phases; a mouse wheel and the glide after a flick do not count.
            guard event.window == NSApp.mainWindow, event.momentumPhase.isEmpty, !event.phase.isEmpty else { return event }
            if event.phase.contains(.began) { (travelled, fired) = (.zero, false) }
            // Reported as the content's movement; flip it where "natural" scrolling is off so it always means the fingers'.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            travelled.width += event.scrollingDeltaX * sign
            travelled.height += event.scrollingDeltaY * sign
            let pointer = AppModel.pointer()
            let sideways = abs(travelled.width) > abs(travelled.height) * 2
            if !fired, sideways, let pointer, let todo = app.todoRow(at: pointer) {
                app.swiping = (todo, travelled.width)
            }
            if !fired, let swipe = Swipe.from(dx: travelled.width, dy: travelled.height), let pointer {
                fired = true
                withAnimation(AppModel.spring) { app.swiping = nil }
                app.swiped(swipe, at: pointer)
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                withAnimation(AppModel.spring) { app.swiping = nil }
            }
            // A sideways swipe is ours; everything else scrolls as usual.
            return sideways && abs(travelled.width) > 8 ? nil : event
        }
    }
}

/// What shows beside a to-do while it is being swiped: where the swipe leads.
struct SwipeHint: View {
    let todo: ToDo
    @Environment(AppModel.self) private var app

    var body: some View {
        let offset = app.swipeOffset(for: todo)
        HStack {
            if offset > 0 {
                Label(Brand.Words.when, systemImage: "calendar").foregroundStyle(Brand.Palette.accent)
            }
            Spacer()
            if offset < 0 {
                Label(app.isSelected(todo) ? "Deselect" : "Select", systemImage: "checkmark.circle").foregroundStyle(Brand.Palette.accent)
            }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 14, weight: .semibold))
        .opacity(min(abs(offset) / 30, 1))
        .padding(.horizontal, -34)
        .allowsHitTesting(false)
    }
}
