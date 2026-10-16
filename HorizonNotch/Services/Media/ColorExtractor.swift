import AppKit

enum ColorExtractor {
    /// The cover's dominant colour, made bright enough to read on black.
    ///
    /// Pixels are grouped by hue; each group counts its area weighted by
    /// saturation, so a large pale-yellow background beats a small vivid
    /// blue detail. Grey pixels only decide when the cover has no colour.
    static func vibrantColor(of image: NSImage) -> NSColor {
        let side = 24
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return .white }

        let bucketCount = 18
        var weights = [CGFloat](repeating: 0, count: bucketCount)
        var sums = [(r: CGFloat, g: CGFloat, b: CGFloat, n: CGFloat)](repeating: (0, 0, 0, 0), count: bucketCount)
        var grey = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), n: CGFloat(0))

        for i in 0..<(side * side) {
            let r = CGFloat(data[i * 4]) / 255, g = CGFloat(data[i * 4 + 1]) / 255, b = CGFloat(data[i * 4 + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            guard v > 0.25 else { continue }
            if s < 0.15 {
                grey = (grey.r + r, grey.g + g, grey.b + b, grey.n + 1)
                continue
            }
            let bucket = min(Int(h * CGFloat(bucketCount)), bucketCount - 1)
            // Area counts most; saturation and brightness break ties.
            weights[bucket] += 0.5 + s * 0.35 + v * 0.15
            sums[bucket] = (sums[bucket].r + r, sums[bucket].g + g, sums[bucket].b + b, sums[bucket].n + 1)
        }

        // Neighbouring hue buckets belong together (e.g. yellow / orange-yellow).
        var bestBucket = -1
        var bestWeight: CGFloat = 0
        for i in 0..<bucketCount {
            let total = weights[i] + 0.5 * (weights[(i + 1) % bucketCount] + weights[(i + bucketCount - 1) % bucketCount])
            if total > bestWeight { bestWeight = total; bestBucket = i }
        }

        let pixels = CGFloat(side * side)
        guard bestBucket >= 0, bestWeight > pixels * 0.04 else {
            guard grey.n > 0 else { return .white }
            return NSColor(srgbRed: grey.r / grey.n, green: grey.g / grey.n, blue: grey.b / grey.n, alpha: 1)
                .usingColorSpace(.sRGB).map { lift($0, minSaturation: 0) } ?? .white
        }
        let sum = sums[bestBucket]
        let average = NSColor(srgbRed: sum.r / sum.n, green: sum.g / sum.n, blue: sum.b / sum.n, alpha: 1)
        return lift(average, minSaturation: 0.55)
    }

    /// Strengthens pale colours and brightens dark ones for use on black.
    private static func lift(_ color: NSColor, minSaturation: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let saturation = minSaturation > 0 ? min(max(s, minSaturation), 0.9) : s
        return NSColor(hue: h, saturation: saturation, brightness: max(v, 0.85), alpha: 1)
    }
}
