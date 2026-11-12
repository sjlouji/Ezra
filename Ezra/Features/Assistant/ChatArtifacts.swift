import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// An assistant reply as rendered Markdown: headings, lists, paragraphs, tables and code.
struct ReplyText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let blocks = ReplyMarkdown.blocks(text)
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .table(let header, let rows):
                    ReplyTable(header: header, rows: rows)
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(code).font(.system(size: 12, design: .monospaced)).padding(8)
                    }
                    .background(Brand.Palette.page, in: .rect(cornerRadius: 6))
                case .line(.heading(let level, let text)):
                    Text(NoteMarkdown.inline(text))
                        .font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 14, weight: .bold))
                        .padding(.top, index == 0 ? 0 : 5)
                case .line(.bullet(let text)), .line(.checkbox(_, let text)):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(Brand.Palette.secondary)
                        Text(NoteMarkdown.inline(text))
                    }
                case .line(.paragraph(let text)):
                    Text(NoteMarkdown.inline(text))
                case .line(.blank):
                    Spacer().frame(height: 3)
                }
            }
        }
        .font(Brand.Fonts.row)
        .foregroundStyle(Brand.Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

/// A Markdown table from a reply. It scrolls sideways when it is wider than the chat.
private struct ReplyTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        Text(NoteMarkdown.inline(header[column])).fontWeight(.semibold).padding(.vertical, 6)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    Divider().overlay(Brand.Palette.hairline)
                    GridRow {
                        // A short row is padded, so a model's missing cell does not shift the ones after it.
                        ForEach(header.indices, id: \.self) { column in
                            Text(NoteMarkdown.inline(column < rows[row].count ? rows[row][column] : "")).padding(.vertical, 6)
                        }
                    }
                }
            }
            .font(Brand.Fonts.subtitle)
            .padding(.horizontal, 10)
        }
        .background(Brand.Palette.page, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.Palette.hairline))
    }
}

/// An interactive page in the chat, with a button to see it large.
struct ChatPageView: View {
    let page: ChatPage
    @State private var enlarged = false
    @State private var exporting = false
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(page.title, systemImage: "chart.bar.xaxis").font(Brand.Fonts.rowBold).foregroundStyle(Brand.Palette.ink)
                Spacer()
                Menu("Save", systemImage: "square.and.arrow.down") {
                    Button("Save to Notes") { saveToNotes() }
                    Button("Save as HTML File…") { exporting = true }
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Keep this page")
                Button("Enlarge", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hand)
                    .foregroundStyle(Brand.Palette.secondary)
                    .help("Open this page larger")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().overlay(Brand.Palette.hairline)
            PageWebView(document: page.document).frame(height: 460)
        }
        .background(Brand.Palette.page, in: .rect(cornerRadius: 9))
        .clipShape(.rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Brand.Palette.hairline))
        .fileExporter(
            isPresented: $exporting, document: HTMLFile(text: page.document), contentType: .html, defaultFilename: page.title
        ) { result in
            if case .failure(let error) = result { Alerts.shared.report("save the page", error) }
        }
        .sheet(isPresented: $enlarged) {
            VStack(spacing: 0) {
                HStack {
                    Text(page.title).font(Brand.Fonts.rowBold)
                    Spacer()
                    Button("Done") { enlarged = false }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                PageWebView(document: page.document)
            }
            .frame(minWidth: 860, minHeight: 620)
        }
    }
}

extension ChatPageView {
    /// Keeps the page as a note with the HTML attached, and opens that note.
    private func saveToNotes() {
        Alerts.shared.attempt("save the page to Notes") {
            let note = try Workspace(context: context).savePage(page)
            (app.noteToOpen, app.destination) = (note, .notes(nil))
        }
    }
}

/// A page as a file the user can save anywhere.
struct HTMLFile: FileDocument {
    static let readableContentTypes = [UTType.html]
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension Workspace {
    /// A note named after the page, with the page attached as an HTML file that opens in the browser.
    @discardableResult
    func savePage(_ page: ChatPage, store: AttachmentStore = .shared) throws -> Note {
        let note = try addNote(title: page.title, body: "A page \(Brand.assistant) made on \(Date.now.formatted(date: .abbreviated, time: .omitted)). Click the attachment to open it.")
        let file = FileManager.default.temporaryDirectory.appending(path: "\(page.title.replacingOccurrences(of: "/", with: "-")).html")
        try Data(page.document.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) } // the store has its own copy by now
        try store.attach(fileAt: file, to: note, in: context)
        return note
    }
}

/// Shows HTML the assistant wrote. The page's own policy blocks every network load; a clicked web link opens in the browser instead.
private struct PageWebView: NSViewRepresentable {
    let document: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(document, baseURL: nil)
        context.coordinator.loaded = document
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != document else { return }
        view.loadHTMLString(document, baseURL: nil)
        context.coordinator.loaded = document
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated else { return .allow }
            if let url = action.request.url, ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            return .cancel
        }
    }
}
