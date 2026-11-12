import AppKit

/// The app's icon in the Dock while it runs: a day or night scene on a light or dark tile.
/// The icon in Finder, and in the Dock when the app is closed, is fixed by macOS to the light day one.
@MainActor
enum DockIcon {
    /// What the user chose in Settings.
    enum Scene: String, CaseIterable, Identifiable {
        case automatic, day, night
        var id: String { rawValue }
        var title: String { self == .automatic ? "Follows the time of day" : rawValue.capitalized }
    }

    static let sceneKey = "icon.scene"
    private static var timer: Timer?

    /// The asset for a given appearance, choice and hour. Day runs from 6 in the morning to 6 in the evening.
    static func assetName(dark: Bool, scene: Scene, hour: Int) -> String {
        let night = switch scene {
        case .automatic: !(6..<18).contains(hour)
        case .day: false
        case .night: true
        }
        return "Icon-\(dark ? "dark" : "light")-\(night ? "night" : "day")"
    }

    /// Sets the icon now, and again whenever the hour, the choice or the Mac's appearance could have changed.
    static func start() {
        apply()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in apply() } }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in Task { @MainActor in apply() } }
    }

    static func apply(defaults: UserDefaults = .standard, now: Date = .now) {
        let name = assetName(
            dark: defaults.string(forKey: "AppleInterfaceStyle") == "Dark",
            scene: defaults.string(forKey: sceneKey).flatMap(Scene.init) ?? .automatic,
            hour: Calendar.current.component(.hour, from: now)
        )
        guard let image = NSImage(named: name) else {
            return Log.store.error("The icon \(name, privacy: .public) is missing from the app")
        }
        NSApp.applicationIconImage = image
    }
}
