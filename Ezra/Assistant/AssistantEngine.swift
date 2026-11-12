import Foundation

/// Which model answers in the chat.
enum AssistantEngine: String, CaseIterable, Identifiable, Sendable {
    /// Apple's model on this Mac: free and private, for short questions about the user's data.
    case onDevice
    /// Claude through the user's own API key: any question, ideas, web search.
    case claude
    /// A model the user runs on this Mac with Ollama: free and private, stronger than Apple's, no web.
    case ollama

    var id: String { rawValue }

    /// The names a link may use: mac, ollama, claude.
    init?(link name: String) {
        switch name.lowercased() {
        case "mac", "apple", "ondevice": self = .onDevice
        case "ollama": self = .ollama
        case "claude": self = .claude
        default: return nil
        }
    }
    var title: String {
        switch self {
        case .onDevice: "On this Mac"
        case .ollama: "Ollama"
        case .claude: "Claude"
        }
    }
}
