import SwiftUI

/// Everything that makes the app look and read the way it does. Change it here to rebrand.
enum Brand {
    static let name = "Ezra"
    /// What the built-in assistant is called, everywhere it is shown and in what it is told about itself.
    static let assistant = "Ezra"

    enum Words {
        static let quickFind = "Quick Find"
        static let thisEvening = "This Evening"
        static let when = "When"
        static let deadline = "Deadline"
        static let newToDo = "New To-Do"
        static let notes = "Notes"
        static let save = "Save"
        static let settings = "Settings"
        static let clear = "Clear"
        static let tomorrow = "Tomorrow"

        static func showCompleted(_ count: Int) -> String {
            "Show \(count) completed to-do\(count == 1 ? "" : "s")"
        }
    }

    /// Light, dark, or whatever the Mac is set to; chosen in Settings.
    enum Appearance: String, CaseIterable, Identifiable {
        case automatic, light, dark
        static let key = "appearance"
        var id: String { rawValue }
        var title: String { self == .automatic ? "Match the Mac" : rawValue.capitalized }
        var scheme: ColorScheme? {
            switch self {
            case .automatic: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum Palette {
        static let page = Color(hex: 0xFFFFFF, dark: 0x1E1F22)
        /// The page behind an open to-do.
        static let pageOpen = Color(hex: 0xF4F5F7, dark: 0x17181A)
        static let sidebar = Color(hex: 0xF5F6F7, dark: 0x26272B)
        static let sidebarSelected = Color(hex: 0xE1E3E6, dark: 0x3A3C42)
        static let ink = Color(hex: 0x26282C, dark: 0xECECEE)
        static let secondary = Color(hex: 0x8E8E93, dark: 0x98989F)
        static let hairline = Color(hex: 0xE6E7EA, dark: 0x34363B)
        static let field = Color(hex: 0xEEEFF2, dark: 0x2E3035)
        static let inbox = Color(hex: 0x3E8DF3)
        static let today = Color(hex: 0xF8C537)
        static let upcoming = Color(hex: 0xE6455F)
        static let anytime = Color(hex: 0x2F9C8E)
        static let someday = Color(hex: 0xCDB677)
        static let logbook = Color(hex: 0x4FB35B)
        static let evening = Color(hex: 0x6E86C9)
        static let accent = Color(hex: 0x1F63D2, dark: 0x4C8DF6)
        static let deadline = Color(hex: 0xE53950, dark: 0xFF5C70)
        static let todayPill = Color(hex: 0xE8476B)
        static let tagFill = Color(hex: 0xDDF1E2, dark: 0x23402B)
        static let tagText = Color(hex: 0x3B8A51, dark: 0x7FD096)
        static let magicPlus = Color(hex: 0x4C8EF7)
        static let pickerCard = Color(hex: 0x2B2D33)
        static let pickerText = Color(hex: 0xF2F2F5)
        static let plannerDay = Color(hex: 0x1F7A3D, dark: 0x4FC37A)
        static let plannerTab = Color(hex: 0x171A2B, dark: 0x4C5578)
    }

    enum Fonts {
        static let title = Font.system(size: 24, weight: .bold)
        static let row = Font.system(size: 14)
        static let rowBold = Font.system(size: 14, weight: .semibold)
        static let subtitle = Font.system(size: 12)
        static let label = Font.system(size: 12, weight: .semibold)
    }
}

extension Color {
    /// A colour with its own value in dark mode.
    init(hex light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Bucket {
    var title: String {
        switch self {
        case .fire: "Fires"
        case .growth: "Growth"
        case .extra: "Extras"
        }
    }

    var tint: Color {
        switch self {
        case .fire: Color(hex: 0xE5484D)
        case .growth: Color(hex: 0x2FA84F)
        case .extra: Color(hex: 0x8FA6C8)
        }
    }

    var symbol: String {
        switch self {
        case .fire: "flame.fill"
        case .growth: "leaf.fill"
        case .extra: "hand.thumbsup.fill"
        }
    }
}

extension SmartList {
    var tint: Color {
        switch self {
        case .inbox: Brand.Palette.inbox
        case .today: Brand.Palette.today
        case .upcoming: Brand.Palette.upcoming
        case .anytime: Brand.Palette.anytime
        case .someday: Brand.Palette.someday
        case .logbook: Brand.Palette.logbook
        }
    }
}

extension View {
    /// One row of a to-do screen: full width, inside the page margins.
    func plainRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .padding(.horizontal, 28)
    }
}
