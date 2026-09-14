import Foundation

/// Persists documents as plain text files plus an index, under ~/Library/Application Support/Aloud.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var documents: [LibraryItem] = []

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("texts"), withIntermediateDirectories: true)
        return base
    }()
    private var index: URL { Self.folder.appendingPathComponent("library.json") }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: index), let docs = try? JSONDecoder().decode([LibraryItem].self, from: data) else { return }
        documents = docs.sorted { $0.addedAt > $1.addedAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(documents) { try? data.write(to: index, options: .atomic) }
    }

    func text(for doc: LibraryItem) -> String {
        (try? String(contentsOf: Self.folder.appendingPathComponent("texts/" + doc.textFile), encoding: .utf8)) ?? ""
    }

    @discardableResult
    func add(title: String, source: String, text: String) -> LibraryItem {
        let file = UUID().uuidString + ".txt"
        try? text.write(to: Self.folder.appendingPathComponent("texts/" + file), atomically: true, encoding: .utf8)
        let paragraphs = TextSplitter.paragraphs(from: text)
        var doc = LibraryItem(title: title, sourceDescription: source, textFile: file)
        doc.sentenceCount = paragraphs.reduce(0) { $0 + $1.sentences.count }
        doc.wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        documents.insert(doc, at: 0)
        save()
        return doc
    }

    func remove(_ doc: LibraryItem) {
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("texts/" + doc.textFile))
        documents.removeAll { $0.id == doc.id }
        save()
    }

    func updatePosition(_ doc: LibraryItem, sentence: Int) {
        guard let i = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents[i].position = sentence
        save()
    }

    func rename(_ doc: LibraryItem, to title: String) {
        guard let i = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents[i].title = title
        save()
    }
}
