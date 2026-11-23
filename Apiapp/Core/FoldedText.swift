import Foundation

/// Formatted JSON with some `{…}` and `[…]` blocks collapsed to a placeholder. Keeps the
/// full text, the text to show, and the mapping between them, in UTF-16 offsets.
struct FoldedText: Sendable {
    /// A block whose brackets sit on different lines.
    struct Region: Equatable, Sendable {
        var open: Int
        var close: Int

        /// What collapsing hides: everything between the brackets.
        var hidden: NSRange { NSRange(location: open + 1, length: close - open - 1) }
    }

    /// One line of the shown text.
    struct Line: Equatable, Sendable {
        /// The line's number in the full text, from 1.
        var number: Int
        var region: Region?
        var isCollapsed: Bool
    }

    /// A collapsed block, and where its placeholder sits in the shown text.
    struct Elision: Equatable, Sendable {
        var region: Region
        var placeholder: NSRange
    }

    struct Edit: Equatable, Sendable {
        var range: NSRange
        var replacement: String
    }

    static let placeholder = " … "
    private static let placeholderUnits = Array(placeholder.utf16)

    let regions: [Region]
    private let units: [UInt16]
    private let lineStarts: [Int]
    /// The outermost block opening on each line of the full text.
    private let regionOnLine: [Region?]
    private var collapsed: Set<Int> = []
    private var shownUnits: [UInt16]
    private(set) var elisions: [Elision] = []
    private(set) var lines: [Line] = []

    init(_ text: String) {
        units = Array(text.utf16)
        shownUnits = units
        (regions, lineStarts) = Self.scan(units)
        var regionOnLine = [Region?](repeating: nil, count: lineStarts.count)
        for region in regions {
            let line = Self.index(of: region.open, in: lineStarts)
            if regionOnLine[line] == nil { regionOnLine[line] = region }
        }
        self.regionOnLine = regionOnLine
        render()
    }

    var shown: String { String(decoding: shownUnits, as: UTF16.self) }

    func isCollapsed(_ region: Region) -> Bool { collapsed.contains(region.open) }

    /// Collapses or expands one block, and returns the change to make to the shown text.
    /// Returns nil for a block hidden inside a collapsed one.
    mutating func toggle(_ region: Region) -> Edit? {
        guard isVisible(region.open) else { return nil }
        let start = shownLocation(of: region.open) + 1
        let oldEnd = shownLocation(of: region.close)
        if collapsed.remove(region.open) == nil { collapsed.insert(region.open) }
        render()
        let newEnd = shownLocation(of: region.close)
        return Edit(
            range: NSRange(location: start, length: oldEnd - start),
            replacement: String(decoding: shownUnits[start..<newEnd], as: UTF16.self)
        )
    }

    /// The collapsed block whose placeholder covers this offset in the shown text.
    func elision(at shownOffset: Int) -> Elision? {
        elisions.first { NSLocationInRange(shownOffset, $0.placeholder) }
    }

    /// The full text behind a range of the shown text. A placeholder that is even partly
    /// selected brings everything it hides.
    func fullText(for shownRange: NSRange) -> String {
        let start = fullOffset(for: shownRange.location) { $0.hidden.location }
        let end = max(start, fullOffset(for: NSMaxRange(shownRange)) { NSMaxRange($0.hidden) })
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    /// An offset inside a placeholder has no single match in the full text, so the caller
    /// picks which end of the hidden text it means.
    private func fullOffset(for shownOffset: Int, insidePlaceholder: (Region) -> Int) -> Int {
        var delta = 0
        for elision in elisions {
            if shownOffset <= elision.placeholder.location { break }
            if shownOffset < NSMaxRange(elision.placeholder) { return insidePlaceholder(elision.region) }
            delta += elision.region.hidden.length - elision.placeholder.length
        }
        return min(shownOffset + delta, units.count)
    }

    /// Where a visible offset of the full text sits in the shown text.
    private func shownLocation(of fullOffset: Int) -> Int {
        var delta = 0
        for elision in elisions where elision.region.close <= fullOffset {
            delta += elision.region.hidden.length - elision.placeholder.length
        }
        return fullOffset - delta
    }

    private func isVisible(_ fullOffset: Int) -> Bool {
        !elisions.contains { NSLocationInRange(fullOffset, $0.region.hidden) }
    }

    private mutating func render() {
        var shown: [UInt16] = []
        shown.reserveCapacity(units.count)
        var elisions: [Elision] = []
        var cursor = 0
        for region in regions where collapsed.contains(region.open) && region.open >= cursor {
            shown.append(contentsOf: units[cursor...region.open])
            elisions.append(Elision(region: region, placeholder: NSRange(location: shown.count, length: Self.placeholderUnits.count)))
            shown.append(contentsOf: Self.placeholderUnits)
            cursor = region.close
        }
        shown.append(contentsOf: units[cursor...])
        shownUnits = shown
        self.elisions = elisions

        // A line is hidden when it starts inside a collapsed block. The block's closing
        // line counts too: its bracket now follows the placeholder.
        var lines: [Line] = []
        var next = 0
        for (index, start) in lineStarts.enumerated() {
            while next < elisions.count, elisions[next].region.close < start { next += 1 }
            if next < elisions.count, elisions[next].region.open < start { continue }
            let region = regionOnLine[index]
            lines.append(Line(number: index + 1, region: region, isCollapsed: region.map { collapsed.contains($0.open) } ?? false))
        }
        self.lines = lines
    }

    /// Finds every multi-line block and where each line starts. Skips brackets inside
    /// strings and `{{variables}}`.
    private static func scan(_ units: [UInt16]) -> (regions: [Region], lineStarts: [Int]) {
        var regions: [Region] = []
        var lineStarts = [0]
        var opened: [(offset: Int, line: Int)] = []
        var index = 0
        let count = units.count

        while index < count {
            switch units[index] {
            case newline:
                lineStarts.append(index + 1)
                index += 1
            case quote:
                index += 1
                while index < count, units[index] != quote, units[index] != newline {
                    let escapes = units[index] == backslash && index + 1 < count && units[index + 1] != newline
                    index += escapes ? 2 : 1
                }
                if index < count, units[index] == quote { index += 1 }
            case openBrace where index + 1 < count && units[index + 1] == openBrace:
                index += 2
                while index < count, units[index] != newline {
                    if units[index] == closeBrace, index + 1 < count, units[index + 1] == closeBrace {
                        index += 2
                        break
                    }
                    index += 1
                }
            case openBrace, openBracket:
                opened.append((index, lineStarts.count - 1))
                index += 1
            case closeBrace, closeBracket:
                if let open = opened.popLast(), open.line != lineStarts.count - 1 {
                    regions.append(Region(open: open.offset, close: index))
                }
                index += 1
            default:
                index += 1
            }
        }
        regions.sort { $0.open < $1.open }
        return (regions, lineStarts)
    }

    private static func index(of offset: Int, in lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private static let quote: UInt16 = 0x22
    private static let backslash: UInt16 = 0x5C
    private static let newline: UInt16 = 0x0A
    private static let openBrace: UInt16 = 0x7B
    private static let closeBrace: UInt16 = 0x7D
    private static let openBracket: UInt16 = 0x5B
    private static let closeBracket: UInt16 = 0x5D
}
