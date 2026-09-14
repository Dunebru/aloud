import SwiftUI

struct AloudApp: App {
    @StateObject private var library = Library()
    @StateObject private var engine = SpeechEngine()
    @StateObject private var session = ReadingSession()

    var body: some Scene {
        WindowGroup("Aloud") {
            RootView()
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(session)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await engine.loadModelIfNeeded()
                    // Launch arguments for scripting: --open <file or URL> [--play]
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--open"), args.count > i + 1 {
                        let target = args[i + 1]
                        if target.hasPrefix("http") { session.importWeb(target, library: library) }
                        else { session.importFiles([URL(fileURLWithPath: target)], library: library) }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if args.contains("--play") { engine.play() }
                        if let e = args.firstIndex(of: "--export"), args.count > e + 1 {
                            engine.exportAudio(to: URL(fileURLWithPath: args[e + 1]), title: "export")
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { session.openFilePanel(library: library) }.keyboardShortcut("o")
                Button("Add Web Page…") { session.showWebSheet = true }.keyboardShortcut("l")
                Button("Add Pasted Text") { session.showPasteSheet = true }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button(engine.isPlaying ? "Pause" : "Play") { engine.toggle() }.keyboardShortcut(.space, modifiers: [])
                Button("Next Sentence") { engine.next() }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Previous Sentence") { engine.previous() }.keyboardShortcut(.leftArrow, modifiers: [])
                Divider()
                Button("Faster") { engine.speed = min(3, engine.speed + 0.1) }.keyboardShortcut("]")
                Button("Slower") { engine.speed = max(0.5, engine.speed - 0.1) }.keyboardShortcut("[")
            }
        }
        Settings { SettingsView().environmentObject(engine) }
    }
}

/// UI state that is not the engine's business: which document is open, sheets, errors.
@MainActor
final class ReadingSession: ObservableObject {
    @Published var current: LibraryItem?
    @Published var paragraphs: [Paragraph] = []
    @Published var showWebSheet = false
    @Published var showPasteSheet = false
    @Published var importing = false
    @Published var error: String?

    func open(_ doc: LibraryItem, library: Library, engine: SpeechEngine) {
        current = doc
        let text = library.text(for: doc)
        paragraphs = TextSplitter.paragraphs(from: text)
        let sentences = paragraphs.flatMap(\.sentences)
        engine.load(sentences: sentences, startAt: doc.position)
        engine.onSentenceChange = { [weak library] i in
            library?.updatePosition(doc, sentence: i)
        }
    }

    func openFilePanel(library: Library) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = TextExtractor.readableTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDF, EPUB, text, Markdown, RTF, Word or HTML files"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, library: library)
    }

    func importFiles(_ urls: [URL], library: Library) {
        importing = true
        Task.detached { [weak self] in
            var results: [ExtractedText] = []
            var failures: [String] = []
            for u in urls {
                do { results.append(try TextExtractor.extract(from: u)) } catch { failures.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            }
            let done = results, fails = failures
            await MainActor.run {
                for r in done { library.add(title: r.title, source: r.source, text: r.text) }
                self?.importing = false
                if !fails.isEmpty { self?.error = fails.joined(separator: "\n") }
            }
        }
    }

    func importWeb(_ string: String, library: Library) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else { error = "That doesn't look like a web address."; return }
        importing = true
        Task { [weak self] in
            do {
                let r = try await TextExtractor.extract(webURL: url)
                library.add(title: r.title, source: r.source, text: r.text)
            } catch { self?.error = error.localizedDescription }
            self?.importing = false
        }
    }

    func importText(_ text: String, title: String, library: Library) {
        guard text.contains(where: \.isLetter) else { error = "Nothing to read."; return }
        let t = title.trimmingCharacters(in: .whitespaces)
        library.add(title: t.isEmpty ? String(text.prefix(48)).replacingOccurrences(of: "\n", with: " ") : t, source: "Pasted text", text: text)
    }
}
