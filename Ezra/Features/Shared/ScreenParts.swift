import SwiftUI

/// The scrolling body every to-do screen shares: one centred column. Its rows are ordinary stack children,
/// so when one opens, moves or is logged, its neighbours slide with the app's spring instead of jumping.
struct ScreenList<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            // Rows are made as they scroll into view: a list of thousands opens as fast as a list of ten.
            LazyVStack(alignment: .leading, spacing: 0) { content }
                .padding(.top, 34)
                .padding(.bottom, 60)
                .frame(maxWidth: 660)
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                // Clicking anywhere that is not a to-do closes the one that is open.
                .onTapGesture { app.closeCard() }
        }
        // Pulling a list down past its top opens Quick Find, as pulling down does on iPhone.
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top < -64 } action: { _, pulled in
            if pulled, !app.showsQuickFind, app.card == nil { app.setQuickFind(true) }
        }
    }
}

/// A screen's heading: its icon, its name, and its "···" menu when it has one.
struct ScreenTitle<Items: View>: View {
    let icon: ListIcon.Kind
    let title: String
    @ViewBuilder let menu: Items

    var body: some View {
        HStack(spacing: 10) {
            ListIcon(icon, size: 23)
            Text(title)
                .font(Brand.Fonts.title)
                .foregroundStyle(Brand.Palette.ink)
            if Items.self != EmptyView.self {
                TitleMenu { menu }
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

extension ScreenTitle where Items == EmptyView {
    init(icon: ListIcon.Kind, title: String) {
        self.init(icon: icon, title: title) { EmptyView() }
    }
}

/// The grey "···" beside a screen's title.
struct TitleMenu<Items: View>: View {
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.Palette.secondary.opacity(0.8))
                .accessibilityLabel("More")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(Brand.Palette.secondary)
        .pointerStyle(.link)
    }
}

/// "All" and the tags in use on a screen; picking one shows only the to-dos that carry it.
struct TagFilterBar: View {
    let tags: [String]
    @Binding var selection: String?

    var body: some View {
        // One line, however many tags there are: it scrolls sideways instead of squeezing the names.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip("All", isSelected: selection == nil) { selection = nil }
                ForEach(tags, id: \.self) { tag in
                    chip(tag, isSelected: selection == tag) { selection = tag }
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(AppModel.spring) { action() }
        } label: {
            Text(title)
                .lineLimit(1)
                .fixedSize()
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Brand.Palette.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(isSelected ? Brand.Palette.secondary.opacity(0.75) : .clear, in: .capsule)
                .contentShape(.rect)
        }
        .buttonStyle(.hand)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A bold label over a hairline, optionally leading to a project or area.
struct GroupHeader: View {
    let icon: ListIcon.Kind?
    let title: String
    var tint = Brand.Palette.ink
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let icon { ListIcon(icon, size: 16) }
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tint)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.Palette.secondary)
                }
                Spacer()
            }
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
        }
        .padding(.top, 26)
        .contentShape(.rect)
        .onTapGesture { action?() }
        .pointerStyle(action == nil ? .default : .link)
        .accessibilityAddTraits(action == nil ? .isHeader : [.isHeader, .isButton])
    }
}

struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Brand.Fonts.row)
            .foregroundStyle(Brand.Palette.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }
}

/// One day's calendar events: on a light grey card (Today) or as plain lines (Upcoming).
struct EventsCard: View {
    let events: [DayEvent]
    var onCard = true
    /// A busy day shows its first few events; the rest open on request.
    @State private var showsAll = false
    private let limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(showsAll ? events : Array(events.prefix(limit))) { event in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if event.isAllDay {
                        Capsule().fill(event.tint).frame(width: 3, height: 11)
                    } else {
                        Text(event.start.formatted(.dateTime.hour().minute()))
                            .foregroundStyle(event.tint)
                    }
                    Text(event.title)
                        .foregroundStyle(Brand.Palette.ink.opacity(0.62))
                }
                .opacity(event.end < .now ? 0.55 : 1)
            }
            if events.count > limit {
                Button(showsAll ? "Show fewer" : "\(events.count - limit) more event\(events.count - limit == 1 ? "" : "s")") {
                    withAnimation(AppModel.spring) { showsAll.toggle() }
                }
                .buttonStyle(.hand)
                .foregroundStyle(Brand.Palette.accent)
            }
        }
        .font(.system(size: 14))
        .padding(.vertical, onCard ? 10 : 2)
        .padding(.horizontal, onCard ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(onCard ? Brand.Palette.field.opacity(0.75) : .clear, in: .rect(cornerRadius: 7))
        .padding(.vertical, 4)
    }
}

/// A chromeless button that shows the pointing hand.
struct HandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .pointerStyle(.link)
    }
}

extension ButtonStyle where Self == HandButtonStyle {
    static var hand: HandButtonStyle { HandButtonStyle() }
}
