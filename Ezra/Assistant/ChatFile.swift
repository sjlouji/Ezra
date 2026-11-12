import AppKit
import PDFKit
import Vision

/// A file the user attached to a chat message: the text read from it, and for a picture, the picture itself.
struct ChatFile: Sendable, Equatable, Identifiable {
    let id = UUID()
    let name: String
    let text: String
    /// A picture, as a JPEG small enough to save and sync with the message. Only Claude looks at it; the other models get `text`.
    var image: Data?

    static func == (lhs: ChatFile, rhs: ChatFile) -> Bool {
        lhs.name == rhs.name && lhs.text == rhs.text && lhs.image == rhs.image
    }
}

enum ChatFileError: LocalizedError, Equatable {
    case unreadable(String)
    case empty(String)
    case tooLong(name: String, characters: Int)
    case tooLongForThisMac(characters: Int)
    case tooManyPictures

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            "\(name) could not be read. Text, Markdown, transcripts (.vtt, .srt), CSV, JSON, PDF, Word, RTF and pictures work."
        case .empty(let name):
            "\(name) has no text in it, and none could be read from its pages."
        case .tooLong(let name, let characters):
            "\(name) is too long to attach (\(characters.formatted()) characters; the limit is \(ChatFileReader.limit.formatted())). Split it and attach a part."
        case .tooLongForThisMac(let characters):
            "The attached text is too long for the model on this Mac (\(characters.formatted()) characters; it can take about \(ChatFileReader.onDeviceLimit.formatted())). Switch to Ollama or Claude to use it."
        case .tooManyPictures:
            "A message can carry \(ChatFileReader.pictureLimit) pictures. Send these first, then attach more."
        }
    }
}

/// Reads a file for the chat, off the main thread. Nothing is cut: a file that is too long is refused with the reason.
/// Scanned PDFs and pictures are read with on-device text recognition.
enum ChatFileReader {
    /// A message with its files is saved as one synced item, which may not exceed 1 MB.
    static let limit = 400_000
    /// The on-device model's whole context is a few thousand words.
    static let onDeviceLimit = 6_000
    static let pictureLimit = 2
    /// What one picture may weigh once shrunk, so two of them still fit in a synced message.
    static let pictureBytes = 160_000
    private static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"]

    static func read(_ url: URL) async throws -> ChatFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        var picture: Data?
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw ChatFileError.unreadable(name) }
            let typed = document.string ?? ""
            // A scan holds pictures of pages; read the words off them.
            text = typed.trimmed.isEmpty ? try recognise(pagesOf: document) : typed
        case let type where pictureTypes.contains(type):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw ChatFileError.unreadable(name) }
            picture = try shrunk(image, name: name)
            let words = try recognise(image)
            text = words.trimmed.isEmpty ? "(A picture. No text was found in it.)" : "Text read from the picture:\n\(words)"
        case "rtf", "rtfd", "doc", "docx", "odt":
            do {
                text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            } catch {
                Log.assistant.error("Could not read \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                throw ChatFileError.unreadable(name)
            }
        default:
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                Log.assistant.error("Could not read \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                throw ChatFileError.unreadable(name)
            }
        }
        guard !text.trimmed.isEmpty else { throw ChatFileError.empty(name) }
        guard text.count <= limit else { throw ChatFileError.tooLong(name: name, characters: text.count) }
        return ChatFile(name: name, text: text, image: picture)
    }

    /// The words in a picture, top to bottom.
    static func recognise(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func recognise(pagesOf document: PDFDocument) throws -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // About 200 dots per inch: enough for print-sized type.
            let scale = 200.0 / 72.0
            let picture = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            pages.append(try recognise(image))
        }
        return pages.joined(separator: "\n\n")
    }

    /// The picture as a JPEG no heavier than `pictureBytes`, made smaller step by step until it fits.
    static func shrunk(_ image: CGImage, name: String) throws -> Data {
        var side = 1400.0
        while side >= 300 {
            let scale = min(1, side / Double(max(image.width, image.height)))
            let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            guard let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { break }
            // On white, so a transparent picture does not turn black as a JPEG.
            context.setFillColor(.white)
            context.fill(CGRect(origin: .zero, size: size))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            if let small = context.makeImage(),
               let data = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.7]),
               data.count <= pictureBytes {
                return data
            }
            side *= 0.75
        }
        throw ChatFileError.unreadable(name)
    }
}
