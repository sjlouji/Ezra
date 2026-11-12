import Foundation
import JavaScriptCore

/// The React artifact runtime that ships inside the app: React 18, Tailwind, the shadcn/ui components, lucide icons and
/// Recharts, built once from Anthropic's artifacts-builder skill (see Tools/artifact-kit). The model writes one component
/// file; this turns it into a page, with no build step and nothing fetched from the network.
enum ArtifactKit {
    static let components = [
        "accordion", "alert", "aspect-ratio", "avatar", "badge", "breadcrumb", "button", "calendar", "card", "carousel", "checkbox",
        "collapsible", "command", "context-menu", "dialog", "drawer", "dropdown-menu", "form", "hover-card", "input", "label", "menubar",
        "navigation-menu", "popover", "progress", "radio-group", "resizable", "scroll-area", "select", "separator", "sheet", "skeleton",
        "slider", "sonner", "switch", "table", "tabs", "textarea", "toast", "toaster", "toggle-group", "toggle", "tooltip",
    ]

    /// Everything a component file may import.
    static let modules: Set<String> = Set(
        ["react", "react-dom", "react-dom/client", "react/jsx-runtime", "lucide-react", "recharts", "class-variance-authority", "clsx", "tailwind-merge", "@/lib/utils"]
            + components.map { "@/components/ui/\($0)" }
    )

    enum Problem: LocalizedError, Equatable {
        case doesNotCompile(String)
        case unknownImport(String)
        case loadsData(String)
        case missingRuntime(String)

        var errorDescription: String? {
            switch self {
            case .doesNotCompile(let why):
                "The artifact was not shown: the code does not compile. \(why) Fix it and call buildArtifact again."
            case .unknownImport(let name):
                "The artifact was not shown: \"\(name)\" cannot be imported. Only react, lucide-react, recharts, @/lib/utils and @/components/ui/<name> are there. Rewrite without it and call buildArtifact again."
            case .loadsData(let how):
                "The artifact was not shown: it uses \(how), and an artifact cannot load anything. Read the data with the other tools first and write the values into the code."
            case .missingRuntime(let file):
                "The artifact runtime is missing from the app (\(file))."
            }
        }
    }

    /// Checks a component file before it is shown: it must compile, export a component, import only what the kit has,
    /// and not try to load data. A model is told exactly what is wrong so it can try again.
    @MainActor
    static func check(_ code: String) throws {
        if let loader = ["fetch(", "XMLHttpRequest", "import("].first(where: code.contains) { throw Problem.loadsData(loader) }
        guard let checker = try checker(), let result = checker.call(withArguments: [code]) else { throw Problem.missingRuntime("check.js") }
        if let error = result.objectForKeyedSubscript("error"), !error.isUndefined, let why = error.toString() {
            throw Problem.doesNotCompile(why)
        }
        let imports = result.objectForKeyedSubscript("imports")?.toArray() as? [String] ?? []
        if let stranger = imports.first(where: { !modules.contains($0.replacing(/\.(tsx?|jsx?)$/, with: "")) }) { throw Problem.unknownImport(stranger) }
    }

    @MainActor private static var compiled: JSValue?

    @MainActor
    private static func checker() throws -> JSValue? {
        if let compiled { return compiled }
        guard let context = JSContext() else { return nil }
        context.evaluateScript(try text("check", "js"))
        compiled = context.objectForKeyedSubscript("EzraCheck")?.objectForKeyedSubscript("check")
        return compiled
    }

    /// The page for one component file: the runtime, the theme, the file, and the call that mounts it.
    static func document(for code: String) -> String {
        do {
            return """
                <!doctype html><html><head><meta charset="utf-8">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; \
                script-src 'unsafe-inline' 'unsafe-eval'; img-src data: blob:; font-src data:">
                <style>\(try text("theme", "css"))</style>
                <script>\(try script("tailwind"))</script><script>\(try script("tailwind-config"))</script>
                </head><body><div id="root"></div>
                <script>\(try script("kit"))</script>
                <script type="text/plain" id="source">\(inline(code))</script>
                <script>EzraKit.run(document.getElementById("source").textContent)</script>
                </body></html>
                """
        } catch {
            Log.assistant.error("The artifact runtime could not be loaded: \(String(describing: error), privacy: .public)")
            return "<!doctype html><html><body><p style=\"font:13px -apple-system;color:#b3261e;margin:12px\">\(error.localizedDescription)</p></body></html>"
        }
    }

    private static func text(_ name: String, _ type: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: type) else { throw Problem.missingRuntime("\(name).\(type)") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func script(_ name: String) throws -> String { inline(try text(name, "js")) }

    /// Text placed inside a script element must not contain the tag that would end it.
    private static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
    }
}
