import AppKit
import SwiftUI

/// The text area for request and response bodies: line numbers, syntax colours and
/// find, with every automatic text "fix" turned off so JSON isn't altered.
struct CodeEditor: NSViewRepresentable {
    /// Past this many characters, colouring would slow typing down too much.
    static let highlightLimit = 1_000_000
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let lineHeight: CGFloat = 20

    @Binding var text: String
    var language: CodeLanguage
    var isEditable = true

    private var allowsFolding: Bool { !isEditable && language == .json }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language, allowsFolding: allowsFolding)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = isEditable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.drawsBackground = false
        textView.insertionPointColor = Palette.ink
        textView.font = Self.font
        textView.typingAttributes = Coordinator.baseAttributes
        textView.delegate = context.coordinator
        layoutManager.allowsNonContiguousLayout = true

        let scrollView = EditorScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        context.coordinator.replaceAll(in: textView, with: text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        textView.isEditable = isEditable
        let foldingChanged = coordinator.allowsFolding != allowsFolding
        coordinator.allowsFolding = allowsFolding

        if coordinator.language != language {
            coordinator.language = language
            coordinator.highlight(textView)
        }
        guard text != coordinator.lastText || foldingChanged else { return }

        // Going through shouldChangeText keeps Format JSON undoable with ⌘Z.
        if isEditable, !foldingChanged {
            let everything = NSRange(location: 0, length: (textView.string as NSString).length)
            guard textView.shouldChangeText(in: everything, replacementString: text) else { return }
            textView.textStorage?.replaceCharacters(in: everything, with: NSAttributedString(string: text, attributes: Coordinator.baseAttributes))
            textView.didChangeText()
        } else {
            coordinator.replaceAll(in: textView, with: text)
            textView.scroll(.zero)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let baseAttributes: [NSAttributedString.Key: Any] = {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = CodeEditor.lineHeight
            style.maximumLineHeight = CodeEditor.lineHeight
            return [
                .font: CodeEditor.font,
                .foregroundColor: Palette.ink,
                .paragraphStyle: style,
                .baselineOffset: 3,
            ]
        }()

        var text: Binding<String>
        var language: CodeLanguage
        var allowsFolding: Bool
        /// The full text, which differs from what the view shows while blocks are collapsed.
        var lastText = ""
        private(set) var folds: FoldedText?
        weak var ruler: LineNumberRuler?
        /// The text that the next change replaces, noted before it happens, so that only
        /// that part of the document needs colouring again afterwards.
        private var pendingEdits: [(range: NSRange, replacementLength: Int)] = []
        private var isWholeDocumentColoured = false
        /// Whether the last colouring pass covered only the lines around an edit.
        private(set) var lastPassWasPartial = false

        init(text: Binding<String>, language: CodeLanguage, allowsFolding: Bool = false) {
            self.text = text
            self.language = language
            self.allowsFolding = allowsFolding
        }

        func replaceAll(in textView: NSTextView, with newText: String) {
            let folds = allowsFolding ? FoldedText(newText) : nil
            self.folds = folds?.regions.isEmpty == false ? folds : nil
            textView.textStorage?.setAttributedString(NSAttributedString(string: newText, attributes: Self.baseAttributes))
            lastText = newText
            textView.typingAttributes = Self.baseAttributes
            highlight(textView)
            ruler?.showsFoldColumn = self.folds != nil
            ruler?.textDidChange()
        }

        func toggleFold(onLine index: Int, in textView: NSTextView) {
            guard let lines = folds?.lines, index < lines.count, let region = lines[index].region else { return }
            toggle(region, in: textView)
        }

        /// Returns false when the character isn't part of a collapsed block's placeholder.
        func expandFold(at characterIndex: Int, in textView: NSTextView) -> Bool {
            guard let elision = folds?.elision(at: characterIndex) else { return false }
            toggle(elision.region, in: textView)
            return true
        }

        /// The full text behind the selection, or nil when nothing is collapsed.
        func unfoldedText(for ranges: [NSRange]) -> String? {
            guard let folds, !folds.elisions.isEmpty else { return nil }
            return ranges.map { folds.fullText(for: $0) }.joined(separator: "\n")
        }

        private func toggle(_ region: FoldedText.Region, in textView: NSTextView) {
            guard let edit = folds?.toggle(region), let storage = textView.textStorage else { return }
            storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: Self.baseAttributes))
            let length = (edit.replacement as NSString).length
            highlight(textView, around: NSRange(location: edit.range.location, length: length))
            ruler?.textDidChange(replacing: edit.range, withLength: length)
        }

        /// Colours the whole document.
        func highlight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            defer { markPlaceholders(in: layoutManager) }
            let length = (textView.string as NSString).length
            let everything = NSRange(location: 0, length: length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: everything)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: everything)
            lastPassWasPartial = false
            isWholeDocumentColoured = length <= CodeEditor.highlightLimit
            guard isWholeDocumentColoured else { return }
            apply(SyntaxHighlighter.tokens(in: textView.string, language: language), offset: 0, to: layoutManager)
        }

        /// Colours only the lines around one edit, which is all that can have changed: no
        /// token crosses a line, except that a key is known by the colon after it, which may
        /// sit on the next line. One extra line each way covers that.
        func highlight(_ textView: NSTextView, around changed: NSRange) {
            guard let layoutManager = textView.layoutManager else { return }
            let string = textView.string as NSString
            guard isWholeDocumentColoured, string.length <= CodeEditor.highlightLimit else {
                highlight(textView)
                return
            }
            let location = min(changed.location, string.length)
            let edited = string.paragraphRange(for: NSRange(location: location, length: min(changed.length, string.length - location)))
            let start = max(edited.location - 1, 0)
            let end = min(NSMaxRange(edited) + 1, string.length)
            let range = string.paragraphRange(for: NSRange(location: start, length: end - start))
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            apply(SyntaxHighlighter.tokens(in: string.substring(with: range), language: language), offset: range.location, to: layoutManager)
            markPlaceholders(in: layoutManager)
            lastPassWasPartial = true
        }

        private func markPlaceholders(in layoutManager: NSLayoutManager) {
            for elision in folds?.elisions ?? [] {
                layoutManager.addTemporaryAttributes(
                    [.foregroundColor: Palette.secondary, .backgroundColor: Palette.track],
                    forCharacterRange: elision.placeholder
                )
            }
        }

        private func apply(_ tokens: [SyntaxToken], offset: Int, to layoutManager: NSLayoutManager) {
            for token in tokens {
                let range = NSRange(location: token.range.location + offset, length: token.range.length)
                layoutManager.addTemporaryAttribute(.foregroundColor, value: Self.color(for: token.kind), forCharacterRange: range)
            }
        }

        private static func color(for kind: TokenKind) -> NSColor {
            switch kind {
            case .key: Palette.jsonKey
            case .string: Palette.jsonString
            case .number, .literal: Palette.jsonNumber
            case .punctuation: Palette.jsonPunctuation
            case .variable: Palette.variable
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let replacementString {
                pendingEdits.append((affectedCharRange, (replacementString as NSString).length))
            }
            return true
        }

        func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
            if let replacementStrings {
                for (range, string) in zip(affectedRanges, replacementStrings) {
                    pendingEdits.append((range.rangeValue, (string as NSString).length))
                }
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let edits = pendingEdits
            pendingEdits = []
            let oldLength = lastText.utf16.count
            let newText = textView.string
            lastText = newText
            if text.wrappedValue != newText { text.wrappedValue = newText }
            // One edit that accounts for the whole change in length can be handled on its
            // own. Anything else, which is rare, gets a full pass.
            if edits.count == 1, newText.utf16.count - oldLength == edits[0].replacementLength - edits[0].range.length {
                let edit = edits[0]
                highlight(textView, around: NSRange(location: edit.range.location, length: edit.replacementLength))
                ruler?.textDidChange(replacing: edit.range, withLength: edit.replacementLength)
            } else {
                highlight(textView)
                ruler?.textDidChange()
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard textView.isEditable, language == .json else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                insertIndentedNewline(in: textView)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }

        /// Keeps the current indent, and goes one deeper after `{` or `[`.
        private func insertIndentedNewline(in textView: NSTextView) {
            let string = textView.string as NSString
            let selection = textView.selectedRange()
            let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let line = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let opensBlock = line.hasSuffix("{") || line.hasSuffix("[")
            let inner = opensBlock ? indent + "  " : indent

            let after = NSMaxRange(selection)
            let next = after < string.length ? string.substring(with: NSRange(location: after, length: 1)) : ""
            if opensBlock, next == "}" || next == "]" {
                textView.insertText("\n\(inner)\n\(indent)", replacementRange: selection)
                textView.setSelectedRange(NSRange(location: selection.location + 1 + (inner as NSString).length, length: 0))
            } else {
                textView.insertText("\n\(inner)", replacementRange: selection)
            }
        }
    }
}

/// ⌘F: opens the find bar in whichever text editor has focus.
enum FindCommand {
    @MainActor static func showFindBar() {
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }
}

/// Copies the full JSON behind collapsed blocks, and expands a block when its
/// placeholder is clicked.
final class CodeTextView: NSTextView {
    private var coordinator: CodeEditor.Coordinator? { delegate as? CodeEditor.Coordinator }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let text = coordinator?.unfoldedText(for: selectedRanges.map(\.rangeValue)) else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(text, forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           let index = characterIndex(under: convert(event.locationInWindow, from: nil)),
           coordinator?.expandFold(at: index, in: self) == true {
            return
        }
        super.mouseDown(with: event)
    }

    private func characterIndex(under point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard bounds.contains(inContainer) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }
}

/// Keeps the text view at least as tall as the pane, so clicking anywhere in an
/// empty or short body puts the cursor in it.
final class EditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        if textView.frame.height < contentSize.height {
            textView.setFrameSize(NSSize(width: contentSize.width, height: contentSize.height))
        }
    }
}

/// The line-number column, plus fold arrows for collapsible JSON. Long lines wrap, so
/// only a line's first row gets a number.
final class LineNumberRuler: NSRulerView {
    private static let numberWidth: CGFloat = 36
    private static let foldWidth: CGFloat = 14
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
        .foregroundColor: Palette.lineNumber,
    ]

    private weak var textView: NSTextView?
    /// Where each line begins, as a UTF-16 offset. A start is the index just after a newline.
    private(set) var lineStarts: [Int] = [0]

    var showsFoldColumn = false {
        didSet {
            guard showsFoldColumn != oldValue else { return }
            ruleThickness = Self.numberWidth + (showsFoldColumn ? Self.foldWidth : 0)
        }
    }

    private var coordinator: CodeEditor.Coordinator? { textView?.delegate as? CodeEditor.Coordinator }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.numberWidth
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let line = foldLine(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        coordinator?.toggleFold(onLine: line, in: textView)
    }

    /// The line whose fold arrow sits at this point of the ruler.
    func foldLine(at point: NSPoint) -> Int? {
        guard showsFoldColumn, point.x >= Self.numberWidth, let textView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let lines = coordinator?.folds?.lines, layoutManager.numberOfGlyphs > 0 else { return nil }
        let inContainer = NSPoint(x: 0, y: textView.convert(point, from: self).y - textView.textContainerOrigin.y)
        var glyphs = NSRange()
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        guard inContainer.y >= fragment.minY, inContainer.y < fragment.maxY else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyphs.location)
        let line = lineNumber(at: character)
        guard lineStarts[line] == character, line < lines.count, lines[line].region != nil else { return nil }
        return line
    }

    /// Recomputes every line start.
    func textDidChange() {
        guard let textView else { return }
        let string = textView.string as NSString
        var starts = [0]
        var location = 0
        while location < string.length {
            let range = string.range(of: "\n", options: .literal, range: NSRange(location: location, length: string.length - location))
            guard range.location != NSNotFound else { break }
            location = NSMaxRange(range)
            starts.append(location)
        }
        lineStarts = starts
        needsDisplay = true
    }

    /// Updates the line starts for one edit without rescanning the rest of the text. The
    /// starts inside the replaced text go, and the ones after it move by however much the
    /// length changed.
    func textDidChange(replacing old: NSRange, withLength newLength: Int) {
        guard let textView else { return }
        let string = textView.string as NSString
        let location = min(old.location, string.length)
        let newEnd = min(location + newLength, string.length)
        let delta = newLength - old.length
        let before = lineStarts.prefix { $0 <= location }
        let after = lineStarts.drop { $0 <= NSMaxRange(old) }.map { $0 + delta }
        var inserted: [Int] = []
        var cursor = location
        while cursor < newEnd {
            let range = string.range(of: "\n", options: .literal, range: NSRange(location: cursor, length: newEnd - cursor))
            guard range.location != NSNotFound else { break }
            cursor = NSMaxRange(range)
            inserted.append(cursor)
        }
        lineStarts = Array(before) + inserted + Array(after)
        needsDisplay = true
    }

    // Draws only the numbers, so the pane's rounded background shows through.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let inset = textView.textContainerInset.height
        let originY = convert(NSPoint.zero, from: textView).y + inset

        if string.length == 0 {
            drawNumber(1, y: originY)
            return
        }

        var visible = textView.visibleRect
        visible.origin.y -= inset
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        var lineIndex = lineNumber(at: layoutManager.characterIndexForGlyph(at: glyphs.location))
        let foldLines = coordinator?.folds?.lines

        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            while lineIndex + 1 < self.lineStarts.count, self.lineStarts[lineIndex + 1] <= character { lineIndex += 1 }
            if self.lineStarts[lineIndex] == character {
                self.drawLine(lineIndex, foldLines: foldLines, y: originY + fragment.minY)
            }
        }

        // A trailing newline leaves an empty last line with no glyphs of its own.
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, string.hasSuffix("\n") {
            drawLine(lineStarts.count - 1, foldLines: foldLines, y: originY + extra.minY)
        }
    }

    /// With blocks collapsed, the shown lines keep their numbers from the full text.
    private func drawLine(_ index: Int, foldLines: [FoldedText.Line]?, y: CGFloat) {
        guard let foldLines, index < foldLines.count else {
            drawNumber(index + 1, y: y)
            return
        }
        let line = foldLines[index]
        drawNumber(line.number, y: y)
        if line.region != nil {
            drawFoldArrow(collapsed: line.isCollapsed, y: y)
        }
    }

    private func drawFoldArrow(collapsed: Bool, y: CGFloat) {
        let x = Self.numberWidth + Self.foldWidth / 2
        let middle = y + CodeEditor.lineHeight / 2
        let arm: CGFloat = 3.5
        let path = NSBezierPath()
        if collapsed {
            path.move(to: NSPoint(x: x - arm / 2, y: middle - arm))
            path.line(to: NSPoint(x: x + arm / 2, y: middle))
            path.line(to: NSPoint(x: x - arm / 2, y: middle + arm))
        } else {
            path.move(to: NSPoint(x: x - arm, y: middle - arm / 2))
            path.line(to: NSPoint(x: x, y: middle + arm / 2))
            path.line(to: NSPoint(x: x + arm, y: middle - arm / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        Palette.lineNumber.setStroke()
        path.stroke()
    }

    private func lineNumber(at character: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= character { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func drawNumber(_ number: Int, y: CGFloat) {
        let label = String(number) as NSString
        let size = label.size(withAttributes: Self.attributes)
        let origin = NSPoint(x: Self.numberWidth - size.width - 4, y: y + (CodeEditor.lineHeight - size.height) / 2)
        label.draw(at: origin, withAttributes: Self.attributes)
    }
}
