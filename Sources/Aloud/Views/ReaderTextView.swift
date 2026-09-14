import AppKit
import SwiftUI

/// The reading surface: a real NSTextView so text flows like a page, the spoken sentence is
/// highlighted, and a click on any sentence starts reading there.
struct ReaderTextView: NSViewRepresentable {
    let title: String
    let paragraphs: [Paragraph]
    let current: Int
    let fontSize: Double
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let tv = ClickableTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 48, height: 40)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.onClickCharacter = { [weak coord = context.coordinator] idx in coord?.clicked(at: idx) }
        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        let key = "\(title)|\(paragraphs.count)|\(fontSize)|\(paragraphs.first?.sentences.first?.id ?? -1)|\(paragraphs.last?.sentences.last?.id ?? -1)"
        if c.layoutKey != key {
            c.layoutKey = key
            c.build(title: title, paragraphs: paragraphs, fontSize: fontSize)
        }
        c.highlight(sentence: current)
    }

    @MainActor
    final class Coordinator {
        var onSelect: (Int) -> Void
        weak var textView: NSTextView?
        var layoutKey = ""
        private var ranges: [Int: NSRange] = [:]      // sentence id → range in the storage
        private var lastHighlighted: Int? = nil
        private var textColor: NSColor = .textColor

        init(onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }

        func build(title: String, paragraphs: [Paragraph], fontSize: Double) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            ranges.removeAll(); lastHighlighted = nil
            let serifDescriptor = NSFont.systemFont(ofSize: fontSize).fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: fontSize).fontDescriptor
            let serif = NSFont(descriptor: serifDescriptor, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            let titleFont = NSFont.systemFont(ofSize: fontSize * 1.6, weight: .bold)
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.lineHeightMultiple = 1.35
            paraStyle.paragraphSpacing = fontSize * 0.9
            let result = NSMutableAttributedString()
            result.append(NSAttributedString(string: title + "\n", attributes: [.font: titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: { let s = NSMutableParagraphStyle(); s.paragraphSpacing = fontSize * 1.2; return s }()]))
            for p in paragraphs {
                for (i, s) in p.sentences.enumerated() {
                    let text = s.text + (i == p.sentences.count - 1 ? "" : " ")
                    let start = result.length
                    result.append(NSAttributedString(string: text, attributes: [.font: serif, .foregroundColor: NSColor.labelColor, .paragraphStyle: paraStyle]))
                    ranges[s.id] = NSRange(location: start, length: (s.text as NSString).length)
                }
                result.append(NSAttributedString(string: "\n", attributes: [.font: serif, .paragraphStyle: paraStyle]))
            }
            storage.setAttributedString(result)
            textColor = .labelColor
        }

        func highlight(sentence id: Int) {
            guard let tv = textView, let storage = tv.textStorage, lastHighlighted != id else { return }
            if let old = lastHighlighted, let r = ranges[old], NSMaxRange(r) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: r)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            }
            // everything before the current sentence reads as "done"
            if let r = ranges[id], NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22), range: r)
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r)
                for (sid, rr) in ranges where sid < id && NSMaxRange(rr) <= storage.length {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: rr)
                }
                for (sid, rr) in ranges where sid > id && NSMaxRange(rr) <= storage.length {
                    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: rr)
                }
                tv.scrollRangeToVisible(r)
                centerRange(r, in: tv)
            }
            lastHighlighted = id
        }

        private func centerRange(_ r: NSRange, in tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer, let scroll = tv.enclosingScrollView else { return }
            let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            rect.origin.y += tv.textContainerInset.height
            let visible = scroll.contentView.bounds
            let targetY = max(0, rect.midY - visible.height / 2)
            if abs(targetY - visible.origin.y) > visible.height * 0.25 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3
                    scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
                }
            }
        }

        func clicked(at index: Int) {
            if let (id, _) = ranges.first(where: { NSLocationInRange(index, $0.value) }) { onSelect(id) }
        }
    }
}

/// NSTextView that reports single clicks as character indexes (drag-selection still works).
final class ClickableTextView: NSTextView {
    var onClickCharacter: ((Int) -> Void)?
    private var downPoint: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) < 4, selectedRange().length == 0 else { return }
        let idx = characterIndexForInsertion(at: p)
        if idx < (string as NSString).length { onClickCharacter?(idx) }
    }
}
