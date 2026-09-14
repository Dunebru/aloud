import SwiftUI

/// The text, one paragraph per row, with the sentence being spoken highlighted and kept in view.
struct ReaderView: View {
    let doc: LibraryItem
    @EnvironmentObject private var engine: SpeechEngine
    @EnvironmentObject private var session: ReadingSession
    @AppStorage("fontSize") private var fontSize: Double = 18

    var body: some View {
        ReaderTextView(title: doc.title, paragraphs: session.paragraphs, current: engine.currentIndex, fontSize: fontSize) { id in engine.seek(to: id) }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Smaller") { fontSize = max(12, fontSize - 2) }
                        Button("Larger") { fontSize = min(32, fontSize + 2) }
                    } label: { Image(systemName: "textformat.size") }
                }
            }
    }
}

struct PlayerBar: View {
    @EnvironmentObject private var engine: SpeechEngine
    @EnvironmentObject private var session: ReadingSession
    @State private var showVoices = false

    private var progress: Double { engine.sentences.isEmpty ? 0 : Double(engine.currentIndex) / Double(max(1, engine.sentences.count - 1)) }
    private var remaining: String {
        guard let doc = session.current, doc.sentenceCount > 0 else { return "" }
        let words = Double(doc.wordCount) * (1 - progress)
        let minutes = Int(words / (170 * engine.speed))
        return minutes < 1 ? "under a minute left" : "\(minutes) min left"
    }

    var body: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { progress }, set: { v in engine.seek(to: Int(v * Double(max(0, engine.sentences.count - 1)))) }), in: 0...1)
                .disabled(engine.sentences.isEmpty)
                .controlSize(.small)
            HStack(spacing: 14) {
                Button { showVoices.toggle() } label: {
                    Label(VoiceInfo(id: engine.voice).name, systemImage: "person.wave.2")
                }
                .popover(isPresented: $showVoices, arrowEdge: .top) { VoicePicker() }
                .disabled(engine.modelState != .ready)

                Menu {
                    ForEach([0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.5, 1.7, 2.0, 2.5], id: \.self) { s in
                        Button { engine.speed = s } label: { HStack { Text(String(format: "%.1f×", s)); if abs(engine.speed - s) < 0.01 { Image(systemName: "checkmark") } } }
                    }
                } label: { Text(String(format: "%.1f×", engine.speed)).monospacedDigit() }
                .frame(width: 70)

                Spacer()
                Button { engine.previous() } label: { Image(systemName: "backward.fill") }.keyboardShortcut(.leftArrow, modifiers: []).disabled(engine.sentences.isEmpty)
                Button { engine.toggle() } label: {
                    ZStack {
                        Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
                        if engine.isBuffering && engine.isPlaying { ProgressView().controlSize(.small).offset(y: 30) }
                    }
                }
                .buttonStyle(.plain).foregroundStyle(engine.modelState == .ready && !engine.sentences.isEmpty ? Color.accentColor : Color.secondary)
                .disabled(engine.modelState != .ready || engine.sentences.isEmpty)
                Button { engine.next() } label: { Image(systemName: "forward.fill") }.keyboardShortcut(.rightArrow, modifiers: []).disabled(engine.sentences.isEmpty)
                Spacer()
                Text(remaining).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct VoicePicker: View {
    @EnvironmentObject private var engine: SpeechEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Voices").font(.headline).padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(engine.voices.map(VoiceInfo.init), id: \.id) { v in
                        HStack {
                            Image(systemName: v.id == engine.voice ? "checkmark.circle.fill" : "circle").foregroundStyle(v.id == engine.voice ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name).font(.callout.weight(.medium))
                                Text("\(v.accent) · \(v.gender)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { engine.preview(voice: v.id) } label: { Image(systemName: "speaker.wave.2") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Preview")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { engine.voice = v.id }
                        .background(v.id == engine.voice ? Color.accentColor.opacity(0.08) : Color.clear)
                    }
                }
            }
            .frame(width: 280, height: 360)
        }
    }
}
