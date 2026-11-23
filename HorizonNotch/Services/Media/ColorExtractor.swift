import AppKit

enum ColorExtractor {
    /// The cover's dominant colour, made bright enough to read on black.
    ///
    /// Pixels are grouped by hue; each group counts its area, with chroma
    /// breaking ties, so a large beige photo beats a small white logo or a
    /// thin coloured caption. Near-white, near-black and grey pixels are
    /// ignored unless the whole cover is grey. The result keeps the cover's
    /// own saturation (only nudged), so beige stays beige instead of turning
    /// orange.
    static func vibrantColor(of image: NSImage) -> NSColor {
        let side = 40
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return .white }

        let bucketCount = 24
        var weights = [CGFloat](repeating: 0, count: bucketCount)
        var sums = [(r: CGFloat, g: CGFloat, b: CGFloat, n: CGFloat)](repeating: (0, 0, 0, 0), count: bucketCount)
        var grey = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), n: CGFloat(0))

        for i in 0..<(side * side) {
            let r = CGFloat(data[i * 4]) / 255, g = CGFloat(data[i * 4 + 1]) / 255, b = CGFloat(data[i * 4 + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            let v = high
            let s = high > 0 ? (high - low) / high : 0
            // Near-black and near-white (logos, borders, text) say nothing.
            guard v > 0.18, !(v > 0.9 && s < 0.12) else { continue }
            if s < 0.12 {
                grey = (grey.r + r, grey.g + g, grey.b + b, grey.n + 1)
                continue
            }
            var h: CGFloat = 0, hs: CGFloat = 0, hv: CGFloat = 0, a: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &hs, brightness: &hv, alpha: &a)
            let bucket = min(Int(h * CGFloat(bucketCount)), bucketCount - 1)
            // Area counts most; chroma (colourfulness) breaks ties.
            weights[bucket] += 0.6 + 0.4 * min(1, (high - low) * 2)
            sums[bucket] = (sums[bucket].r + r, sums[bucket].g + g, sums[bucket].b + b, sums[bucket].n + 1)
        }

        // Neighbouring hue buckets belong together (e.g. beige / light brown).
        var bestBucket = -1
        var bestWeight: CGFloat = 0
        for i in 0..<bucketCount {
            let total = weights[i] + 0.5 * (weights[(i + 1) % bucketCount] + weights[(i + bucketCount - 1) % bucketCount])
            if total > bestWeight { bestWeight = total; bestBucket = i }
        }

        let pixels = CGFloat(side * side)
        // Colour must cover a real share of the cover, or the grey wins.
        guard bestBucket >= 0, bestWeight > max(pixels * 0.05, grey.n * 0.35) else {
            guard grey.n > 0 else { return .white }
            return lift(NSColor(srgbRed: grey.r / grey.n, green: grey.g / grey.n, blue: grey.b / grey.n, alpha: 1),
                        saturationBoost: 1)
        }
        // Average the winning bucket with its neighbours, weighted by count.
        var sum = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), n: CGFloat(0))
        for offset in [-1, 0, 1] {
            let bucket = sums[(bestBucket + offset + bucketCount) % bucketCount]
            let factor: CGFloat = offset == 0 ? 1 : 0.5
            sum = (sum.r + bucket.r * factor, sum.g + bucket.g * factor, sum.b + bucket.b * factor, sum.n + bucket.n * factor)
        }
        let average = NSColor(srgbRed: sum.r / sum.n, green: sum.g / sum.n, blue: sum.b / sum.n, alpha: 1)
        return lift(average, saturationBoost: 1.25)
    }

    /// Brightens dark colours for use on black and gently strengthens pale
    /// ones, staying close to the cover's own saturation.
    private static func lift(_ color: NSColor, saturationBoost: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let saturation = min(s * saturationBoost, 0.75)
        return NSColor(hue: h, saturation: saturation, brightness: min(max(v * 1.15, 0.82), 1), alpha: 1)
    }

    /// Up to four of the cover's main colours, the most covering first, for
    /// a background made of them. Greys only when the cover has no colour.
    static func palette(of image: NSImage, count: Int = 4) -> [NSColor] {
        let side = 32
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let buckets = 18
        var weights = [CGFloat](repeating: 0, count: buckets)
        var sums = [(r: CGFloat, g: CGFloat, b: CGFloat, n: CGFloat)](repeating: (0, 0, 0, 0), count: buckets)
        var grey = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), n: CGFloat(0))
        for i in 0..<(side * side) {
            let r = CGFloat(data[i * 4]) / 255, g = CGFloat(data[i * 4 + 1]) / 255, b = CGFloat(data[i * 4 + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            let s = high > 0 ? (high - low) / high : 0
            guard high > 0.12 else { continue }
            if s < 0.15 { grey = (grey.r + r, grey.g + g, grey.b + b, grey.n + 1); continue }
            var h: CGFloat = 0, hs: CGFloat = 0, hv: CGFloat = 0, a: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &hs, brightness: &hv, alpha: &a)
            let bucket = min(Int(h * CGFloat(buckets)), buckets - 1)
            weights[bucket] += 0.5 + s
            sums[bucket] = (sums[bucket].r + r, sums[bucket].g + g, sums[bucket].b + b, sums[bucket].n + 1)
        }
        var chosen: [Int] = []
        for bucket in weights.indices.sorted(by: { weights[$0] > weights[$1] }) where weights[bucket] > 6 {
            // Skip direct neighbours of a colour already taken.
            if chosen.contains(where: { min(abs($0 - bucket), buckets - abs($0 - bucket)) < 2 }) { continue }
            chosen.append(bucket)
            if chosen.count == count { break }
        }
        var colors: [NSColor] = chosen.map { bucket in
            let sum = sums[bucket]
            return NSColor(srgbRed: sum.r / sum.n, green: sum.g / sum.n, blue: sum.b / sum.n, alpha: 1)
        }
        if colors.isEmpty, grey.n > 0 {
            colors = [NSColor(srgbRed: grey.r / grey.n, green: grey.g / grey.n, blue: grey.b / grey.n, alpha: 1)]
        }
        // Rich but not neon: a little more colour, brightness in a calm band.
        return colors.map { color in
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            return NSColor(hue: h, saturation: min(s * 1.25, 0.95), brightness: min(max(v, 0.45), 0.85), alpha: 1)
        }
    }
}
