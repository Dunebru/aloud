import XCTest
@testable import Aloud

final class AloudTests: XCTestCase {
    func testSplitterMergesWrappedLinesAndSplitsSentences() {
        let text = "First line of a para-\ngraph continues here. Second sentence!\n\nNew paragraph? Yes."
        let p = TextSplitter.paragraphs(from: text)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].sentences.map(\.text), ["First line of a paragraph continues here.", "Second sentence!"])
        XCTAssertEqual(p[1].sentences.map(\.text), ["New paragraph?", "Yes."])
        XCTAssertEqual(p[1].sentences[0].id, 2)
    }

    func testLongSentencesAreSplitAtClauses() {
        let clause = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let text = clause + ", " + clause + ", " + clause + "."
        let p = TextSplitter.paragraphs(from: text)
        XCTAssertGreaterThan(p[0].sentences.count, 1)
        XCTAssertTrue(p[0].sentences.allSatisfy { $0.text.count <= TextSplitter.maxSentenceLength + 5 })
    }

    func testReadableHTMLPrefersArticle() {
        let html = "<html><head><title>T &amp; U</title></head><body><nav>Menu Menu Menu</nav><article><p>" + String(repeating: "Body text. ", count: 80) + "</p></article><footer>foot</footer></body></html>"
        let r = TextExtractor.readableText(fromHTML: Data(html.utf8))
        XCTAssertEqual(r.title, "T & U")
        XCTAssertFalse(r.text.contains("Menu"))
        XCTAssertTrue(r.text.contains("Body text."))
    }

    func testVoiceInfo() {
        let v = VoiceInfo(id: "bm_george")
        XCTAssertEqual(v.name, "George"); XCTAssertEqual(v.accent, "British"); XCTAssertEqual(v.gender, "Male")
    }

    func testTrimSilence() {
        let s = [Float](repeating: 0, count: 5000) + [Float](repeating: 0.5, count: 100) + [Float](repeating: 0, count: 20000)
        let t = SpeechEngine.trimSilence(s)
        XCTAssertLessThan(t.count, 5000)
        XCTAssertGreaterThan(t.count, 100)
    }
}
