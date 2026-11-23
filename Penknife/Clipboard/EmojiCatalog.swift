import CoreText
import Foundation

/// The single-symbol emojis macOS can draw, with their names, for the icon editor's search (CB-37).
/// Nothing is bundled: the list comes from the OS's Unicode properties and the Apple Color Emoji
/// font, so emojis Apple adds show up with macOS updates. Built once, on first use (~1 400 items).
enum EmojiCatalog {
    struct Emoji: Identifiable, Hashable {
        let glyph: String
        /// Lowercased Unicode name ("grinning face"), what the search matches.
        let name: String
        var id: String { glyph }
    }

    /// Faces and people first, then nature, objects, symbols: the order Unicode blocks give.
    private static let blocks: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x1F300...0x1F5FF,
        0x1F680...0x1F6FF, 0x2600...0x27BF, 0x1F000...0x1F2FF, 0x2190...0x21FF,
        0x2300...0x23FF, 0x2B00...0x2BFF, 0x3030...0x3299,
    ]

    static let all: [Emoji] = {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        var result: [Emoji] = []
        for block in blocks {
            for value in block {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let properties = scalar.properties
                guard properties.isEmoji, !properties.isEmojiModifier,
                      !(0x1F1E6...0x1F1FF).contains(value), // regional indicators (flag halves)
                      let name = properties.name else { continue }
                // Symbols shown as text by default (☀, ❤) need the emoji variation selector.
                let glyph = properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                guard drawable(scalar, in: font) else { continue }
                result.append(Emoji(glyph: glyph, name: name.lowercased()))
            }
        }
        return result
    }()

    /// Every word of the query must start a word of the name: "smil fa" finds "smiling face".
    /// Endings are dropped, as names use other forms: "smile" finds "smiling", "cats" finds "cat".
    static func search(_ query: String) -> [Emoji] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(stem)
        guard !words.isEmpty else { return all }
        return all.filter { emoji in
            let nameWords = emoji.name.split { $0 == " " || $0 == "-" }
            return words.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
        }
    }

    static func stem(_ word: Substring) -> Substring {
        for ending in ["ing", "ed", "es", "e", "s"] where word.count - ending.count >= 3 && word.hasSuffix(ending) {
            return word.dropLast(ending.count)
        }
        return word
    }

    private static func drawable(_ scalar: Unicode.Scalar, in font: CTFont) -> Bool {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) && glyphs[0] != 0 // a surrogate pair's second slot stays 0
    }
}
