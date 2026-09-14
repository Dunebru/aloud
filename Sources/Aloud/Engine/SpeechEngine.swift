import AVFoundation
import FluidAudio
import Foundation

/// Reads a document aloud with Kokoro running on the Neural Engine.
///
/// Sentences are synthesized a few ahead of playback on a background task and scheduled on an
/// AVAudioPlayerNode, so playback never waits on the model once it has warmed up.
@MainActor
final class SpeechEngine: ObservableObject {
    enum ModelState: Equatable { case notLoaded, loading, ready, failed(String) }

    @Published private(set) var modelState: ModelState = .notLoaded
    @Published private(set) var isPlaying = false
    @Published private(set) var currentIndex: Int = 0
    @Published var voice: String = UserDefaults.standard.string(forKey: "voice") ?? "af_heart" { didSet { UserDefaults.standard.set(voice, forKey: "voice"); invalidateCache() } }
    @Published var speed: Double = UserDefaults.standard.object(forKey: "speed") as? Double ?? 1.0 { didSet { UserDefaults.standard.set(speed, forKey: "speed"); invalidateCache() } }
    @Published private(set) var sentences: [Sentence] = []
    @Published private(set) var isBuffering = false
    @Published private(set) var exportProgress: Double? = nil
    var onSentenceChange: ((Int) -> Void)?

    private var manager: KokoroAneManager?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var cache: [Int: [Float]] = [:]
    private var inflight: Set<Int> = []
    private var prefetchTask: Task<Void, Never>?
    private var generation = 0            // bumps on seek/stop so stale completions are ignored
    private var exportTask: Task<Void, Never>?

    static let prefetchAhead = 3

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    // MARK: model

    func loadModelIfNeeded() async {
        guard modelState == .notLoaded || { if case .failed = modelState { return true }; return false }() else { return }
        modelState = .loading
        do {
            let m = KokoroAneManager(variant: .english)
            try await m.initialize()
            manager = m
            modelState = .ready
            fputs("[aloud] Kokoro ready\n", stderr)
        } catch {
            modelState = .failed(error.localizedDescription)
            fputs("[aloud] model load failed: \(error)\n", stderr)
        }
    }

    var voices: [String] { KokoroAneConstants.englishVoices }

    // MARK: document

    func load(sentences: [Sentence], startAt index: Int) {
        stop()
        self.sentences = sentences
        currentIndex = min(max(0, index), max(0, sentences.count - 1))
        cache.removeAll(); inflight.removeAll()
    }

    // MARK: transport

    func play() {
        guard !sentences.isEmpty, modelState == .ready else { return }
        if !engine.isRunning { try? engine.start() }
        isPlaying = true
        generation += 1
        scheduleCurrent(generation: generation)
    }

    func pause() {
        isPlaying = false
        generation += 1
        player.stop()
        prefetchTask?.cancel()
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        pause()
        engine.stop()
    }

    func seek(to index: Int) {
        guard sentences.indices.contains(index) else { return }
        let wasPlaying = isPlaying
        pause()
        currentIndex = index
        onSentenceChange?(index)
        if wasPlaying { play() }
    }

    func next() { seek(to: currentIndex + 1) }
    func previous() { seek(to: max(0, currentIndex - 1)) }

    // MARK: pipeline

    private func scheduleCurrent(generation gen: Int) {
        guard isPlaying, gen == generation, sentences.indices.contains(currentIndex) else {
            if currentIndex >= sentences.count { isPlaying = false }
            return
        }
        let index = currentIndex
        onSentenceChange?(index)
        if ProcessInfo.processInfo.arguments.contains("--verbose") { fputs("[aloud] speaking \(index)/\(sentences.count)\n", stderr) }
        prefetch(from: index)
        Task { [weak self] in
            guard let self else { return }
            let samples = await self.samples(for: index)
            guard gen == self.generation, self.isPlaying else { return }
            guard let samples, let buffer = self.buffer(from: samples) else { self.currentIndex += 1; self.scheduleCurrent(generation: gen); return }
            self.isBuffering = false
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation, self.isPlaying else { return }
                    self.cache[index] = nil
                    self.currentIndex = index + 1
                    self.scheduleCurrent(generation: gen)
                }
            }
            if !self.player.isPlaying { self.player.play() }
        }
    }

    private func prefetch(from index: Int) {
        prefetchTask?.cancel()
        let targets = (index...(index + Self.prefetchAhead)).filter { sentences.indices.contains($0) && cache[$0] == nil && !inflight.contains($0) }
        guard !targets.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            for i in targets {
                if Task.isCancelled { return }
                _ = await self?.samples(for: i)
            }
        }
    }

    /// Synthesize (or fetch from cache) one sentence. Serialized through the manager.
    private func samples(for index: Int) async -> [Float]? {
        if let c = cache[index] { return c }
        guard let manager, sentences.indices.contains(index) else { return nil }
        if inflight.contains(index) {
            // wait for the other task
            while inflight.contains(index) { try? await Task.sleep(nanoseconds: 20_000_000) }
            return cache[index]
        }
        inflight.insert(index)
        if index == currentIndex { isBuffering = true }
        defer { inflight.remove(index) }
        let text = sentences[index].text
        let voice = self.voice, speed = Float(self.speed)
        do {
            let out = try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed).samples
            let trimmed = Self.trimSilence(out)
            cache[index] = trimmed
            if cache.count > 12 { for k in cache.keys where k < currentIndex - 1 { cache[k] = nil } }
            return trimmed
        } catch {
            fputs("[aloud] synth failed for sentence \(index): \(error)\n", stderr)
            cache[index] = []
            return []
        }
    }

    private func invalidateCache() {
        cache.removeAll()
        if isPlaying { let i = currentIndex; pause(); currentIndex = i; play() }
    }

    private func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        return buf
    }

    /// Kokoro pads utterances with silence; trim to ~120 ms tail so sentences flow naturally.
    nonisolated static func trimSilence(_ s: [Float], threshold: Float = 0.004, keep: Int = 2_900) -> [Float] {
        guard let last = s.lastIndex(where: { abs($0) > threshold }) else { return s }
        let end = min(s.count, last + keep)
        var head = 0
        if let first = s.firstIndex(where: { abs($0) > threshold }) { head = max(0, first - 600) }
        return Array(s[head..<end])
    }

    // MARK: export

    func exportAudio(to url: URL, title: String) {
        guard let manager, !sentences.isEmpty else { return }
        exportProgress = 0
        let all = sentences
        let voice = self.voice, speed = Float(self.speed)
        exportTask = Task { [weak self] in
            do {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
                let file = try AVAudioFile(forWriting: url, settings: settings)
                let fmt = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
                let gap = [Float](repeating: 0, count: 24_000 / 3)   // 330 ms between sentences
                for (i, s) in all.enumerated() {
                    if Task.isCancelled { break }
                    let out = (try? await manager.synthesizeDetailed(text: s.text, voice: voice, speed: speed).samples) ?? []
                    let samples = Self.trimSilence(out) + gap
                    if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) {
                        buf.frameLength = AVAudioFrameCount(samples.count)
                        samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
                        try file.write(from: buf)
                    }
                    await MainActor.run { self?.exportProgress = Double(i + 1) / Double(all.count) }
                }
            } catch {
                await MainActor.run { self?.exportProgress = nil }
            }
            await MainActor.run { self?.exportProgress = nil }
        }
    }

    func cancelExport() { exportTask?.cancel(); exportProgress = nil }

    // MARK: preview

    func preview(voice: String) {
        guard let manager, modelState == .ready else { return }
        if !engine.isRunning { try? engine.start() }
        pause()
        let name = VoiceInfo(id: voice).name
        Task { [weak self] in
            guard let self else { return }
            let out = (try? await manager.synthesizeDetailed(text: "Hi, I'm \(name). This is how I sound.", voice: voice, speed: Float(self.speed)).samples) ?? []
            guard let buf = self.buffer(from: Self.trimSilence(out)) else { return }
            self.player.scheduleBuffer(buf, completionHandler: nil)
            self.player.play()
        }
    }
}

/// Kokoro voice IDs look like "af_heart": a = American, b = British; f/m = gender; then the name.
struct VoiceInfo: Identifiable, Hashable {
    let id: String
    var accent: String { id.hasPrefix("b") ? "British" : "American" }
    var gender: String { id.dropFirst().hasPrefix("f") ? "Female" : "Male" }
    var name: String { id.split(separator: "_").dropFirst().joined(separator: " ").capitalized }
    var label: String { "\(name) · \(accent) \(gender.lowercased())" }
}
