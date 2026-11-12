import SwiftData
import SwiftUI

/// One thing the assistant did: a line saying what, with how long it took. Opens to show exactly what was sent and what came back.
struct StepRow: View {
    let step: ChatStep
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var expanded = false

    private var isRunning: Bool { step.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    switch step.state {
                    case .running: ProgressView().controlSize(.mini)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.Palette.deadline)
                    case .done: Image(systemName: step.symbol).foregroundStyle(step.changed ? Brand.Palette.logbook : Brand.Palette.secondary)
                    }
                }
                .frame(width: 16)
                Text(step.label).fontWeight(.medium).foregroundStyle(Brand.Palette.ink)
                Text(step.subject ?? step.detail).foregroundStyle(Brand.Palette.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if step.todos.count == 1, step.changed, step.state == .done {
                    Button("Open") { open(step.todos[0]) }
                        .foregroundStyle(Brand.Palette.accent)
                        .help("Open this to-do")
                }
                // A clock while it runs; how long it took once it is done.
                if isRunning, let started = step.started {
                    Text(started, style: .timer).monospacedDigit().foregroundStyle(Brand.Palette.secondary)
                } else if let seconds = step.seconds, seconds >= 0.1 {
                    Text(seconds < 60 ? String(format: "%.1f s", seconds) : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s")
                        .monospacedDigit()
                        .foregroundStyle(Brand.Palette.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Brand.Palette.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(.rect)
            .onTapGesture { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } }
            .pointerStyle(.link)
            .help(expanded ? "Hide the details" : "Show what was sent and what came back")
            if expanded { details }
        }
        .font(Brand.Fonts.subtitle)
        .buttonStyle(.hand)
        .background(Brand.Palette.page, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(isRunning ? Brand.Palette.accent : Brand.Palette.hairline, lineWidth: isRunning ? 1.5 : 1)
        }
    }

    /// The call laid open: its arguments, what it returned, any pages a search found, and whether it is still going.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let input = step.input, input != "{}", input != "{\n\n}" {
                section("Sent") {
                    ScrollView {
                        Text(input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Brand.Palette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            } else if step.input == nil, !step.detail.isEmpty {
                section("Sent") { Text(step.detail).foregroundStyle(Brand.Palette.ink).textSelection(.enabled) }
            }
            if !step.result.isEmpty {
                section(step.state == .failed ? "Went wrong" : "Came back") {
                    ScrollView {
                        Text(step.result)
                            .foregroundStyle(step.state == .failed ? Brand.Palette.deadline : Brand.Palette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                }
            }
            if !step.sources.isEmpty {
                section("Pages found") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(step.sources, id: \.url) { source in
                            Button(source.title) { if let url = URL(string: source.url) { openURL(url) } }
                                .foregroundStyle(Brand.Palette.accent)
                                .lineLimit(1)
                                .help(source.url)
                        }
                    }
                }
            }
            Text(isRunning ? "Running" : step.state == .failed ? "Failed" : "Done")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(step.state == .failed ? Brand.Palette.deadline : Brand.Palette.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Brand.Palette.secondary)
            content()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.Palette.field.opacity(0.6), in: .rect(cornerRadius: 6))
        }
    }

    private func open(_ id: UUID) {
        Alerts.shared.attempt("open the to-do") {
            guard let todo = try Workspace(context: context).todo(withID: id) else {
                throw WorkspaceError.notFound(kind: "task", query: step.subject ?? step.detail)
            }
            app.jump(to: todo)
        }
    }
}

/// The steps the assistant set itself for a longer request: done ones ticked, the one in hand turning, the rest waiting.
struct PlanCard: View {
    let plan: [PlanLine]
    /// Whether the reply this belongs to is still being made.
    let isWorking: Bool

    var body: some View {
        let current = isWorking ? plan.firstIndex { !$0.done } : nil
        VStack(alignment: .leading, spacing: 7) {
            ForEach(plan.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Group {
                        if plan[index].done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.Palette.secondary)
                        } else if index == current {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "circle").foregroundStyle(Brand.Palette.secondary.opacity(0.6))
                        }
                    }
                    .frame(width: 16)
                    Text(plan[index].title)
                        .foregroundStyle(plan[index].done ? Brand.Palette.secondary : Brand.Palette.ink)
                        .fontWeight(index == current ? .medium : .regular)
                }
            }
        }
        .font(Brand.Fonts.row)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Palette.page, in: .rect(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Brand.Palette.hairline) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan: \(plan.count { $0.done }) of \(plan.count) steps done")
    }
}
