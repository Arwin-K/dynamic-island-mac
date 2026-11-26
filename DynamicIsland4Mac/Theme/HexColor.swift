import AppKit
import SwiftUI

/// A color stored as a human-readable hex string (`"#RRGGBB"` or `"#RRGGBBAA"`) in theme JSON.
struct HexColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// Components are quantized to 8-bit steps, so a color always survives a round trip
    /// through its hex string unchanged (and equality stays meaningful).
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.quantize(red); self.green = Self.quantize(green)
        self.blue = Self.quantize(blue); self.alpha = Self.quantize(alpha)
    }

    private static func quantize(_ v: Double) -> Double {
        (min(max(v, 0), 1) * 255).rounded() / 255
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        }
    }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? NSColor.white
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent),
                  blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }

    init(_ color: Color) { self.init(nsColor: NSColor(color)) }

    var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        if alpha >= 0.999 {
            return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        }
        return String(format: "#%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// Relative luminance (WCAG), used to pick readable foregrounds on sampled accents.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let parsed = HexColor(hex: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected #RRGGBB or #RRGGBBAA, got \(string)")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    static let white = HexColor(red: 1, green: 1, blue: 1)
    static let black = HexColor(red: 0, green: 0, blue: 0)
}
