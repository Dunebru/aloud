import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

struct ExtractedText {
    var title: String
    var source: String
    var text: String
}

enum ExtractError: LocalizedError {
    case unsupported(String), empty, network(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): "Aloud can't read .\(ext) files yet. Try PDF, EPUB, TXT, Markdown, RTF, DOCX or HTML."
        case .empty: "No readable text was found. Scanned PDFs need OCR first."
        case .network(let m): m
        }
    }
}

enum TextExtractor {
    static let readableTypes: [UTType] = [.pdf, .epub, .plainText, .rtf, .html, UTType("org.openxmlformats.wordprocessingml.document") ?? .data, UTType("net.daringfireball.markdown") ?? .text]

    static func extract(from url: URL) throws -> ExtractedText {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw ExtractError.empty }
            var pages: [String] = []
            for i in 0..<pdf.pageCount { if let s = pdf.page(at: i)?.string { pages.append(s) } }
            let text = pages.joined(separator: "\n\n")
            guard text.contains(where: \.isLetter) else { throw ExtractError.empty }
            let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return ExtractedText(title: title, source: "PDF · \(pdf.pageCount) pages", text: text)
        case "epub":
            return try extractEPUB(url, fallbackTitle: name)
        case "txt", "md", "markdown", "text":
            let raw = try String(contentsOf: url, encoding: .utf8)
            let heading = raw.firstMatch(of: #"(?m)^#\s+(.+)$"#)?.trimmingCharacters(in: .whitespaces)
            var body = stripMarkdown(raw)
            if let heading, let r = body.range(of: heading) , body.distance(from: body.startIndex, to: r.lowerBound) < 4 { body.removeSubrange(r) }
            return ExtractedText(title: heading ?? name, source: ext == "txt" ? "Text file" : "Markdown", text: body)
        case "rtf", "rtfd":
            let attr = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return ExtractedText(title: name, source: "Rich text", text: attr.string)
        case "html", "htm":
            let data = try Data(contentsOf: url)
            return ExtractedText(title: name, source: "HTML", text: readableText(fromHTML: data).text)
        case "docx":
            return try extractDOCX(url, fallbackTitle: name)
        default:
            throw ExtractError.unsupported(ext)
        }
    }

    // MARK: web

    static func extract(webURL: URL) async throws -> ExtractedText {
        var req = URLRequest(url: webURL)
        req.setValue("Mozilla/5.0 (Macintosh) Aloud/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw ExtractError.network("The page returned HTTP \(http.statusCode).") }
        let r = readableText(fromHTML: data)
        guard r.text.count > 200 else { throw ExtractError.empty }
        return ExtractedText(title: r.title ?? webURL.host ?? "Web page", source: webURL.host ?? "Web", text: r.text)
    }

    /// Cheap readability: prefer <article>/<main>, drop script/style/nav/header/footer/aside, then let
    /// AppKit's HTML importer turn what is left into text.
    static func readableText(fromHTML data: Data) -> (title: String?, text: String) {
        var html = String(decoding: data, as: UTF8.self)
        let title = html.firstMatch(of: #"<title[^>]*>([^<]{1,200})</title>"#).map { decodeEntities($0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["script", "style", "nav", "header", "footer", "aside", "noscript", "svg", "form", "iframe"] {
            html = html.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        if let article = html.firstMatch(of: #"(?is)<article\b[^>]*>(.*?)</article>"#) ?? html.firstMatch(of: #"(?is)<main\b[^>]*>(.*?)</main>"#), article.count > 500 {
            html = article
        }
        let attr = try? NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        var text = attr?.string ?? html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // collapse whitespace but keep paragraph breaks
        text = text.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return (title, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: epub / docx (both are zip files)

    private static func unzip(_ url: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aloud-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try ZipArchive.extract(url, to: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }

    private static func extractEPUB(_ url: URL, fallbackTitle: String) throws -> ExtractedText {
        let dir = try unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try String(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = container.firstMatch(of: #"full-path="([^"]+)""#) else { throw ExtractError.empty }
        let opfURL = dir.appendingPathComponent(opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        let base = opfURL.deletingLastPathComponent()
        let title = opf.firstMatch(of: #"<dc:title[^>]*>([^<]+)</dc:title>"#).map(decodeEntities) ?? fallbackTitle
        // manifest id → href
        var hrefs: [String: String] = [:]
        for m in opf.matches(of: #"<item\b[^>]*>"#) {
            if let id = m.firstMatch(of: #"\bid="([^"]+)""#), let href = m.firstMatch(of: #"\bhref="([^"]+)""#) { hrefs[id] = href }
        }
        let spine = opf.matches(of: #"<itemref\b[^>]*idref="([^"]+)""#).compactMap { $0.firstMatch(of: #"idref="([^"]+)""#) }
        var chapters: [String] = []
        for id in spine {
            guard let href = hrefs[id]?.removingPercentEncoding, let data = try? Data(contentsOf: base.appendingPathComponent(href)) else { continue }
            let t = readableText(fromHTML: data).text
            if t.count > 20 { chapters.append(t) }
        }
        let text = chapters.joined(separator: "\n\n")
        guard !text.isEmpty else { throw ExtractError.empty }
        return ExtractedText(title: title, source: "EPUB · \(chapters.count) chapters", text: text)
    }

    private static func extractDOCX(_ url: URL, fallbackTitle: String) throws -> ExtractedText {
        let dir = try unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        var xml = try String(contentsOf: dir.appendingPathComponent("word/document.xml"), encoding: .utf8)
        xml = xml.replacingOccurrences(of: "</w:p>", with: "\n\n").replacingOccurrences(of: "<w:tab/>", with: " ")
        let text = decodeEntities(xml.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        guard text.contains(where: \.isLetter) else { throw ExtractError.empty }
        return ExtractedText(title: fallbackTitle, source: "Word document", text: text)
    }

    // MARK: helpers

    static func stripMarkdown(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\*\\*|__|~~|`", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*[-*+>]\\s+", with: "", options: .regularExpression)
        return t
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let attr = try? NSAttributedString(data: Data(s.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        return attr?.string ?? s
    }
}

extension String {
    /// First capture group of the first match, or nil.
    func firstMatch(of pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []), let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
        return Range(r, in: self).map { String(self[$0]) }
    }
    /// Whole-match strings of every match.
    func matches(of pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        return re.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { Range($0.range, in: self).map { String(self[$0]) } }
    }
}
