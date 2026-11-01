import AppKit
import SwiftUI

/// Colours from design direction A, with dark counterparts.
enum Palette {
    static let window = NSColor.adaptive(0xFFFFFF, 0x1E1E20)
    static let ink = NSColor.adaptive(0x1D1D1F, 0xF2F2F5)
    static let secondary = NSColor.adaptive(0x5F5F66, 0xA8A8B0)
    static let lineNumber = NSColor.adaptive(0x6E6E73, 0x8C8C94)
    static let controlBorder = NSColor.adaptive(0xDADADF, 0x48484E)
    static let urlBorder = NSColor.adaptive(0xCFCFD6, 0x55555C)
    static let divider = NSColor.adaptive(0xE3E3E8, 0x38383C)
    static let hairline = NSColor.adaptive(0xECECF0, 0x333337)
    static let editor = NSColor.adaptive(0xFBFBFD, 0x242427)
    static let track = NSColor.adaptive(0xEDEDF1, 0x38383C)
    static let thumb = NSColor.adaptive(0xFFFFFF, 0x5A5A61)
    static let hover = NSColor.adaptive(0xF4F4F7, 0x2C2C2F)
    static let selection = NSColor.adaptive(0xE2E2E8, 0x3E3E44)
    static let accent = NSColor.adaptive(0x0062CC, 0x0A84FF)

    static let jsonKey = NSColor.adaptive(0x0B4F9E, 0x8BD0FF)
    static let jsonString = NSColor.adaptive(0xA3300C, 0xF2A98C)
    static let jsonNumber = NSColor.adaptive(0x5B2BB5, 0xC9A0FF)
    static let jsonPunctuation = NSColor.adaptive(0x5F5F66, 0xA8A8B0)
    static let variable = NSColor.adaptive(0x0A7A3E, 0x7EE2A8)
}

enum Theme {
    static let window = Color(nsColor: Palette.window)
    static let ink = Color(nsColor: Palette.ink)
    static let secondary = Color(nsColor: Palette.secondary)
    static let controlBorder = Color(nsColor: Palette.controlBorder)
    static let urlBorder = Color(nsColor: Palette.urlBorder)
    static let divider = Color(nsColor: Palette.divider)
    static let hairline = Color(nsColor: Palette.hairline)
    static let editor = Color(nsColor: Palette.editor)
    static let track = Color(nsColor: Palette.track)
    static let thumb = Color(nsColor: Palette.thumb)
    static let hover = Color(nsColor: Palette.hover)
    static let selection = Color(nsColor: Palette.selection)
    static let accent = Color(nsColor: Palette.accent)

    static let body = Font.system(size: 13)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11)
    static let sectionTitle = Font.system(size: 11, weight: .semibold)
    static let methodTag = Font.system(size: 10.5, weight: .semibold)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let urlMono = Font.system(size: 13, design: .monospaced)

    static func color(for method: HTTPMethod) -> Color {
        switch method {
        case .get: Color(nsColor: .adaptive(0x0062CC, 0x6CB6FF))
        case .post: Color(nsColor: .adaptive(0x0A7A3E, 0x7EE2A8))
        case .put: Color(nsColor: .adaptive(0x9A5B00, 0xFFB454))
        case .patch: Color(nsColor: .adaptive(0x6B3FB5, 0xC9A0FF))
        case .delete: Color(nsColor: .adaptive(0xC4272B, 0xFF8A80))
        case .head, .options: secondary
        }
    }

    /// Background and text for the status pill, by kind of outcome.
    static func statusColors(for statusCode: Int) -> (background: Color, text: Color) {
        switch statusCode {
        case 200..<300: (Color(nsColor: .adaptive(0xDDF3E4, 0x173A24)), Color(nsColor: .adaptive(0x0A5E30, 0x7EE2A8)))
        case 300..<400: (Color(nsColor: .adaptive(0xDEEBFA, 0x16304D)), Color(nsColor: .adaptive(0x0B4F9E, 0x8BD0FF)))
        case 400..<500: (Color(nsColor: .adaptive(0xFBEBD3, 0x45300F)), Color(nsColor: .adaptive(0x7A4800, 0xFFC97A)))
        default: failureColors
        }
    }

    static let failureColors = (
        background: Color(nsColor: .adaptive(0xFBE3E3, 0x4A1F1F)),
        text: Color(nsColor: .adaptive(0x9E1C20, 0xFF9C94))
    )
}

extension NSColor {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Formatting {
    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 10 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 { return String(format: "%.1f KB", kilobytes) }
        return String(format: "%.1f MB", kilobytes / 1024)
    }

    /// Short age for history rows: 2m, 1h, 3d.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
