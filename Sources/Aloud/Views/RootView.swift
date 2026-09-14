import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: SpeechEngine
    @EnvironmentObject private var session: ReadingSession
    @State private var webAddress = ""
    @State private var pasteText = ""
    @State private var pasteTitle = ""
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if let doc = session.current {
                    ReaderView(doc: doc)
                } else {
                    EmptyLibraryView()
                }
                PlayerBar()
            }
            .toolbar { toolbar }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { urls.append(url) }; group.leave() }
            }
            group.notify(queue: .main) { session.importFiles(urls, library: library) }
            return true
        }
        .overlay { if dropTargeted { DropHint() } }
        .sheet(isPresented: $session.showWebSheet) { webSheet }
        .sheet(isPresented: $session.showPasteSheet) { pasteSheet }
        .alert("Couldn't add that", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .onChange(of: library.documents.first?.id) { _, _ in
            // auto-open the document that was just added
            if let d = library.documents.first, session.current?.id != d.id, session.current == nil || d.addedAt > Date().addingTimeInterval(-3) {
                session.open(d, library: library, engine: engine)
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { session.current?.id }, set: { id in if let d = library.documents.first(where: { $0.id == id }) { session.open(d, library: library, engine: engine) } })) {
            Section("Library") {
                ForEach(library.documents) { d in
                    LibraryRow(item: d, isCurrent: session.current?.id == d.id)
                        .tag(d.id)
                        .contextMenu {
                            Button("Remove from Library", role: .destructive) { removeItem(d) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .safeAreaInset(edge: .bottom) { ModelStatusFooter() }
    }

    private func removeItem(_ d: LibraryItem) {
        if session.current?.id == d.id { engine.stop(); session.current = nil }
        library.remove(d)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if session.importing { ProgressView().controlSize(.small) }
            Menu {
                Button("Open File…") { session.openFilePanel(library: library) }
                Button("Web Page…") { session.showWebSheet = true }
                Button("Pasted Text…") { pasteText = NSPasteboard.general.string(forType: .string) ?? ""; session.showPasteSheet = true }
            } label: { Label("Add", systemImage: "plus") } primaryAction: { session.openFilePanel(library: library) }
            if session.current != nil { ExportButton() }
        }
    }

    private var webSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read a web page").font(.title3.weight(.semibold))
            TextField("https://example.com/article", text: $webAddress).textFieldStyle(.roundedBorder).onSubmit { submitWeb() }
            Text("Aloud fetches the page and keeps the article text. Nothing else leaves your Mac.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { session.showWebSheet = false }.keyboardShortcut(.cancelAction); Button("Add") { submitWeb() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(20).frame(width: 460)
    }

    private func submitWeb() { session.importWeb(webAddress, library: library); session.showWebSheet = false; webAddress = "" }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read pasted text").font(.title3.weight(.semibold))
            TextField("Title (optional)", text: $pasteTitle).textFieldStyle(.roundedBorder)
            TextEditor(text: $pasteText).font(.body).frame(height: 240).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack { Spacer(); Button("Cancel") { session.showPasteSheet = false }.keyboardShortcut(.cancelAction); Button("Add") { session.importText(pasteText, title: pasteTitle, library: library); session.showPasteSheet = false; pasteText = ""; pasteTitle = "" }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(20).frame(width: 560)
    }
}

struct LibraryRow: View {
    let item: LibraryItem
    let isCurrent: Bool
    private var subtitle: String {
        var parts = [item.sourceDescription, "\(item.estimatedMinutes) min"]
        if item.position > 0, item.sentenceCount > 0 {
            let pct = Int(Double(item.position) / Double(item.sentenceCount) * 100)
            parts.append("\(pct)%")
        }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).lineLimit(1).fontWeight(isCurrent ? .semibold : .regular)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct DropHint: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc").font(.system(size: 40, weight: .light))
                Text("Drop to add").font(.title3.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var session: ReadingSession
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic").font(.system(size: 48, weight: .light)).foregroundStyle(.tertiary)
            Text("Drop a PDF, EPUB, or article here").font(.title2.weight(.semibold))
            Text("Aloud reads it in a natural voice, entirely on your Mac. Nothing is uploaded.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Open File…") { session.openFilePanel(library: library) }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Web Page…") { session.showWebSheet = true }.controlSize(.large)
                Button("Paste Text…") { session.showPasteSheet = true }.controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ModelStatusFooter: View {
    @EnvironmentObject private var engine: SpeechEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            switch engine.modelState {
            case .notLoaded, .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing voice…").font(.caption) }
                Text("First launch downloads the 90 MB Kokoro voice model once.").font(.caption2).foregroundStyle(.secondary)
            case .ready:
                Label("Kokoro ready · on-device", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            case .failed(let m):
                Label("Voice model failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                Text(m).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry") { Task { await engine.loadModelIfNeeded() } }.controlSize(.small)
            }
        }
        .padding(10)
    }
}

struct ExportButton: View {
    @EnvironmentObject private var engine: SpeechEngine
    @EnvironmentObject private var session: ReadingSession
    var body: some View {
        if let p = engine.exportProgress {
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.caption.monospacedDigit())
                Button { engine.cancelExport() } label: { Image(systemName: "xmark.circle") }.help("Cancel export")
            }
        } else {
            Button { export() } label: { Label("Export Audio", systemImage: "square.and.arrow.up") }
                .disabled(engine.modelState != .ready)
                .help("Save the whole document as an M4A audiobook")
        }
    }
    private func export() {
        guard let doc = session.current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = doc.title + ".m4a"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.exportAudio(to: url, title: doc.title)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var engine: SpeechEngine
    var body: some View {
        Form {
            Picker("Voice", selection: $engine.voice) {
                ForEach(engine.voices.map(VoiceInfo.init), id: \.id) { v in Text(v.label).tag(v.id) }
            }
            Slider(value: $engine.speed, in: 0.5...3, step: 0.1) { Text("Speed \(engine.speed, specifier: "%.1f")×") }
            Text("Kokoro runs on the Neural Engine. The model lives in ~/.cache/fluidaudio and can be deleted any time.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 440)
    }
}
