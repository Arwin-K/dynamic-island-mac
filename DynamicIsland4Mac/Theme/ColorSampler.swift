import AppKit
import CoreGraphics
import ImageIO

/// Pulls a representative color out of an image (wallpaper or album art).
///
/// Images are downsampled to 32×32 with ImageIO before any pixel math, so sampling a 6K
/// wallpaper costs a few milliseconds and almost no memory.
enum ColorSampler {
    static func color(fromImageAt url: URL, style: Colors.SampleStyle) -> HexColor? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return color(from: image, style: style)
    }

    static func color(fromImageData data: Data, style: Colors.SampleStyle) -> HexColor? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return color(from: image, style: style)
    }

    static func color(from image: CGImage, style: Colors.SampleStyle) -> HexColor? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var samples: [(r: Double, g: Double, b: Double)] = []
        samples.reserveCapacity(side * side)
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
            samples.append((Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255))
        }
        guard !samples.isEmpty else { return nil }

        switch style {
        case .dominant:
            let n = Double(samples.count)
            let r = samples.reduce(0) { $0 + $1.r } / n
            let g = samples.reduce(0) { $0 + $1.g } / n
            let b = samples.reduce(0) { $0 + $1.b } / n
            return readable(HexColor(red: r, green: g, blue: b))
        case .vibrant:
            return readable(vibrant(samples))
        }
    }

    /// Buckets pixels by hue and returns the average of the bucket with the most
    /// "vibrancy" (saturation × closeness to mid brightness, summed over its pixels).
    private static func vibrant(_ samples: [(r: Double, g: Double, b: Double)]) -> HexColor {
        let bucketCount = 12
        var scores = [Double](repeating: 0, count: bucketCount)
        var sums = [(r: Double, g: Double, b: Double, w: Double)](repeating: (0, 0, 0, 0), count: bucketCount)
        for s in samples {
            let color = NSColor(srgbRed: s.r, green: s.g, blue: s.b, alpha: 1)
            var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
            let weight = Double(sat) * (1 - abs(Double(v) - 0.65) * 1.3)
            guard weight > 0.05 else { continue }
            let bucket = min(Int(Double(h) * Double(bucketCount)), bucketCount - 1)
            scores[bucket] += weight
            sums[bucket].r += s.r * weight
            sums[bucket].g += s.g * weight
            sums[bucket].b += s.b * weight
            sums[bucket].w += weight
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), sums[best].w > 0 else {
            // A grayscale image: fall back to the average.
            let n = Double(samples.count)
            return HexColor(red: samples.reduce(0) { $0 + $1.r } / n, green: samples.reduce(0) { $0 + $1.g } / n, blue: samples.reduce(0) { $0 + $1.b } / n)
        }
        let w = sums[best].w
        return HexColor(red: sums[best].r / w, green: sums[best].g / w, blue: sums[best].b / w)
    }

    /// Accents sit on a dark island: lift very dark colors so they stay visible.
    static func readable(_ color: HexColor) -> HexColor {
        let ns = color.nsColor
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let lifted = NSColor(hue: h, saturation: min(s * 1.1, 1), brightness: max(v, 0.62), alpha: 1)
        return HexColor(nsColor: lifted)
    }
}
