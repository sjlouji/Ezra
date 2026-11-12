import SwiftUI

/// The morning summary at the top of Today. It shows once a day until dismissed.
struct BriefingCard: View {
    let briefing: DailyBriefing
    @Environment(AppModel.self) private var app
    /// The day (as its start, in seconds) on which the card was last dismissed.
    @AppStorage("briefing.dismissedDay") private var dismissedDay = 0.0

    private var today: Double { Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate }

    var body: some View {
        if dismissedDay != today {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(greeting, systemImage: "sun.max.fill")
                        .font(Brand.Fonts.rowBold)
                        .foregroundStyle(Brand.Palette.ink)
                        .symbolRenderingMode(.multicolor)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") {
                        withAnimation(AppModel.spring) { dismissedDay = today }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Brand.Palette.secondary)
                    .help("Hide the briefing until tomorrow")
                }
                ForEach(briefing.lines, id: \.self) { line in
                    Text(line).font(Brand.Fonts.subtitle).foregroundStyle(Brand.Palette.ink)
                }
                Button("Plan my day with \(Brand.assistant)") {
                    app.assistantDraft = briefing.prompt
                    app.destination = .assistant
                }
                .font(Brand.Fonts.label)
                .foregroundStyle(Brand.Palette.accent)
            }
            .buttonStyle(.hand)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.Palette.today.opacity(0.12), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.Palette.today.opacity(0.35)) }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case ..<12: "Good morning"
        case ..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}
