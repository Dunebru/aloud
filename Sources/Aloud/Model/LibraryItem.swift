import Foundation
import NaturalLanguage

/// A piece of text the user wants read: a file, a web page, or pasted text.
struct LibraryItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var sourceDescription: String        // "PDF · 12 pages", "example.com", "Pasted text"
    var textFile: String                 // file name inside the library folder
    var addedAt: Date = Date()
    var position: Int = 0                // last sentence index
    var sentenceCount: Int = 0
    var wordCount: Int = 0

    var estimatedMinutes: Int { max(1, wordCount / 170) }
}

/// One unit of speech. Kokoro takes at most ~510 phonemes, so long sentences are split at clauses.
struct Sentence: Identifiable, Hashable {
    let id: Int              // index in document
    let paragraph: Int
    let text: String
    let range: Range<String.Index>   // in the paragraph text
}

struct Paragraph: Identifiable {
    let id: Int
    let text: String
    var sentences: [Sentence]
}

enum TextSplitter {
    static let maxSentenceLength = 380

    static func paragraphs(from text: String) -> [Paragraph] {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = cleaned.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Merge single line breaks inside a paragraph (PDF line wrapping), keep blank lines as breaks.
        var merged: [String] = []
        var current = ""
        for line in blocks {
            if line.isEmpty {
                if !current.isEmpty { merged.append(current); current = "" }
            } else if current.isEmpty {
                current = line
            } else if current.hasSuffix("-") {
                current.removeLast(); current += line   // hyphenated wrap
            } else {
                current += " " + line
            }
        }
        if !current.isEmpty { merged.append(current) }

        var out: [Paragraph] = []
        var sentenceIndex = 0
        for (pi, ptext) in merged.enumerated() {
            var sentences: [Sentence] = []
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = ptext
            tokenizer.enumerateTokens(in: ptext.startIndex..<ptext.endIndex) { range, _ in
                for sub in split(ptext, range) {
                    let t = ptext[sub].trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty || !t.contains(where: { $0.isLetter || $0.isNumber }) { continue }
                    sentences.append(Sentence(id: sentenceIndex, paragraph: pi, text: t, range: sub))
                    sentenceIndex += 1
                }
                return true
            }
            if !sentences.isEmpty { out.append(Paragraph(id: pi, text: ptext, sentences: sentences)) }
        }
        return out
    }

    /// Split an over-long sentence at clause boundaries (, ; : dashes), then at spaces.
    private static func split(_ text: String, _ range: Range<String.Index>) -> [Range<String.Index>] {
        if text.distance(from: range.lowerBound, to: range.upperBound) <= maxSentenceLength { return [range] }
        var result: [Range<String.Index>] = []
        var start = range.lowerBound
        var lastBreak: String.Index? = nil
        var i = range.lowerBound
        while i < range.upperBound {
            let c = text[i]
            if c == "," || c == ";" || c == ":" || c == "\u{2014}" || c == "\u{2013}" { lastBreak = text.index(after: i) }
            else if c == " " && lastBreak == nil { lastBreak = text.index(after: i) }
            if text.distance(from: start, to: i) >= maxSentenceLength {
                let cut = lastBreak ?? i
                if cut > start { result.append(start..<cut); start = cut } else { result.append(start..<i); start = i }
                lastBreak = nil
            }
            i = text.index(after: i)
        }
        if start < range.upperBound { result.append(start..<range.upperBound) }
        return result
    }
}
