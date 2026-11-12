import SwiftData
import SwiftUI

/// The toolbar under every to-do screen: new to-do, new heading, When, move, search.
struct BottomBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var plusProbe: ProbeView?

    var body: some View {
        let open = app.card?.todo
        VStack(spacing: 0) {
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
            if !app.selection.isEmpty {
                SelectionBar()
            } else {
            HStack(spacing: 0) {
                tool("New To-Do (⌘N)", "plus") { app.newToDo() }
                    .keyboardShortcut("n")
                    // Drag the plus to a list, a day or a bucket to put the new to-do exactly there.
                    .background { Probe { plusProbe = $0 } }
                    .opacity(app.drag?.item == .magicPlus ? 0 : 1)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { _ in
                                guard let pointer = AppModel.pointer(), let origin = plusProbe?.windowFrame() else { return }
                                app.dragChanged(.magicPlus, at: pointer, from: origin)
                            }
                            .onEnded { _ in app.dragEnded() }
                    )
                tool("New Heading", "plus.rectangle", enabled: currentProject != nil) {
                    guard let project = currentProject else { return }
                    Alerts.shared.attempt("add the heading") { try Workspace(context: context).addHeading(title: "New Heading", to: project) }
                }
                tool("\(Brand.Words.when) (⌘S)", "calendar", enabled: open != nil) {
                    if let open { app.pick(.when, for: open) }
                }
                tool("Move (⇧⌘M)", "arrow.right", enabled: open != nil) { app.moving = open }
                tool("\(Brand.Words.quickFind) (⌘F)", "magnifyingglass") { app.setQuickFind(true) }
                    .keyboardShortcut("f")
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            }
        }
        .background(Brand.Palette.page)
    }

    private var currentProject: Project? {
        if case .project(let project) = app.destination { return project }
        return nil
    }

    private func tool(_ label: String, _ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.hand)
            .font(.system(size: 14))
            .foregroundStyle(Brand.Palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(.rect)
            .opacity(enabled ? 1 : 0.35)
            .disabled(!enabled)
            .help(label)
    }
}
