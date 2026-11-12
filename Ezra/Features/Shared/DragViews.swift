import AppKit
import SwiftUI

/// An invisible AppKit view that reports where it is in its window. SwiftUI's own coordinate spaces are
/// relative to each pane (sidebar, main area), so they cannot place a pointer from one pane over a target in another.
final class ProbeView: NSView {
    /// This view's rectangle in window coordinates with the origin at the window's top-left; nil while off screen.
    func windowFrame() -> CGRect? {
        guard let window else { return nil }
        let rect = convert(bounds, to: nil)
        return CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct Probe: NSViewRepresentable {
    let found: (ProbeView) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        // After this layout pass, so the view that owns the probe is not changed while it is being built.
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {}
}

/// Registers a view as a place drags can end, and lights it up while one hovers over it.
private struct DropTargetModifier: ViewModifier {
    let target: DropTarget
    @Environment(AppModel.self) private var app
    @State private var id = UUID()
    @State private var probe: ProbeView?

    func body(content: Content) -> some View {
        // Registered on every pass, so the zone always carries the target this view stands for now.
        let _ = probe.map { app.zones[id] = DropZone(probe: $0, target: target) }
        content
            .background {
                RoundedRectangle(cornerRadius: 7).fill(Brand.Palette.accent.opacity(app.hoverZone == id ? 0.18 : 0))
            }
            .overlay {
                // While something is dragged, the places that will take it show a faint outline; the one under the pointer a strong one.
                if let item = app.drag?.item, item.accepts(target) {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Brand.Palette.accent.opacity(app.hoverZone == id ? 0.9 : 0.22), lineWidth: app.hoverZone == id ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
            }
            .background { Probe { probe = $0 } }
            .onDisappear { app.zones[id] = nil }
    }
}

extension View {
    func dropTarget(_ target: DropTarget) -> some View {
        modifier(DropTargetModifier(target: target))
    }
}

/// Covers the window and draws the dragged item on top of everything, exactly under the pointer.
struct DragLayer: View {
    @Environment(AppModel.self) private var app
    @State private var probe: ProbeView?
    @State private var releaseMonitor: Any?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Probe { probe = $0 }
            if let line = app.insertion, let origin = probe?.windowFrame()?.origin {
                Capsule().fill(Brand.Palette.accent)
                    .frame(width: line.width, height: line.height)
                    .offset(x: line.minX - origin.x, y: line.minY - origin.y)
            }
            if let session = app.drag {
                DragGhost(session: session, hint: app.dropHint, origin: probe?.windowFrame()?.origin ?? .zero)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .onAppear {
            // A drag's own gesture ends with the view it started on. If that row is rebuilt mid-drag, its release is never
            // reported and the item would hang in the air, so every mouse release ends whatever drag is still open.
            guard releaseMonitor == nil else { return }
            releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [app] event in
                DispatchQueue.main.async { app.dragEnded() }
                return event
            }
        }
        .onDisappear {
            if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
            releaseMonitor = nil
        }
    }
}

/// The dragged item itself, lifted off the page and following the pointer.
struct DragGhost: View {
    let session: DragSession
    /// What dropping here will do; nil when the pointer is over nothing that takes the item.
    var hint: String?
    /// Where the layer this is drawn in starts, in the same space as the drag's positions.
    let origin: CGPoint

    var body: some View {
        Group {
            switch session.item {
            case .todo(let todo):
                HStack(spacing: 10) {
                    CheckBox(checked: false)
                    Text(todo.title).font(Brand.Fonts.row).foregroundStyle(Brand.Palette.ink).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(width: session.size.width + 24, height: max(session.size.height, 36))
                .background(Brand.Palette.page, in: .rect(cornerRadius: 9))
                .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
                .offset(x: -12)
            case .magicPlus:
                Circle().fill(Brand.Palette.magicPlus)
                    .frame(width: 44, height: 44)
                    .overlay { Image(systemName: "plus").font(.system(size: 20, weight: .light)).foregroundStyle(.white) }
                    .shadow(color: Brand.Palette.magicPlus.opacity(0.5), radius: 14, y: 6)
            case .note, .project, .area, .heading, .checklist, .chat:
                HStack(spacing: 8) {
                    Image(systemName: session.item.symbol)
                        .foregroundStyle(Brand.Palette.secondary)
                    Text(session.item.title.isEmpty ? "Untitled" : session.item.title)
                        .font(Brand.Fonts.row).foregroundStyle(Brand.Palette.ink).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(width: session.size.width, height: min(max(session.size.height, 30), 44))
                .background(Brand.Palette.page, in: .rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let hint {
                Text(hint)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Brand.Palette.accent, in: .capsule)
                    .fixedSize()
                    .offset(x: 8, y: 26)
                    .transition(.opacity)
            }
        }
        .scaleEffect(1.03)
        .offset(
            x: session.location.x - session.grabOffset.width - origin.x,
            y: session.location.y - session.grabOffset.height - origin.y
        )
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}
