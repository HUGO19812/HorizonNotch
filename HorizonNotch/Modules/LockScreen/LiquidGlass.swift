import AppKit
import CoreImage
import SwiftUI

/// Clear Liquid Glass over the desktop picture, like macOS Tahoe: no tint,
/// no blur – the middle shows the picture sharp, a thick convex bevel along
/// the rim bends it like a lens (pulling in what lies outside, squeezing it
/// into streaks along the edges, strongest in the round corners) with faint
/// colour fringes, a 1 pt polished rim catches the light top left and
/// bottom right, and a soft shadow lets it float.
///
/// System glass cannot see the lock screen's wallpaper (another process
/// draws it), so the refraction is computed here: the piece of the picture
/// behind the glass plus a margin is drawn into a bitmap and every pixel in
/// the bevel samples it shifted along the edge normal. Done once per
/// position on a background thread; no shaders needed.
///
/// Like Pro Notch, only the rim is drawn: the middle stays transparent and
/// shows the real lock screen, so moving and dynamic wallpapers keep
/// moving; towards the inside the rim fades out where its bend is gone.
struct LiquidGlassView: View {
    let cornerRadius: CGFloat
    /// Width of the curved rim, in points.
    var bevel: CGFloat = 28
    @ObservedObject private var wallpaper = Wallpaper.shared
    @State private var rendered: (key: String, image: CGImage)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let key = Self.key(frame: frame, radius: cornerRadius, wallpaper: wallpaper.image)
            ZStack {
                if let rendered {
                    Image(decorative: rendered.image, scale: 2)
                        .resizable()
                }
            }
            .task(id: key) {
                guard let source = wallpaper.cgImage, frame.width > 1, frame.height > 1 else { return }
                let screen = wallpaper.screenSize
                let radius = cornerRadius, bevel = bevel
                let image = await Task.detached(priority: .userInitiated) {
                    LiquidGlassRenderer.render(frame: frame, cornerRadius: radius, bevel: bevel,
                                               scale: 2, wallpaper: source, screenSize: screen)
                }.value
                guard !Task.isCancelled, let image else { return }
                rendered = (key, image)
            }
        }
        .clipShape(shape)
        .overlay {
            // The polished edge: brighter top left and bottom right.
            shape.strokeBorder(
                LinearGradient(stops: [.init(color: .white.opacity(0.9), location: 0),
                                       .init(color: .white.opacity(0.22), location: 0.35),
                                       .init(color: .white.opacity(0.12), location: 0.5),
                                       .init(color: .white.opacity(0.22), location: 0.65),
                                       .init(color: .white.opacity(0.75), location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1)
        }
    }

    private static func key(frame: CGRect, radius: CGFloat, wallpaper: NSImage?) -> String {
        let id = wallpaper.map { ObjectIdentifier($0).hashValue } ?? 0
        return "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)),\(radius),\(id)"
    }
}

/// The refraction itself, in plain Swift on a bitmap.
enum LiquidGlassRenderer {
    /// - frame: the glass on the screen, in points, origin top left.
    /// - Returns: the glass picture at `scale` pixels per point.
    static func render(frame: CGRect, cornerRadius: CGFloat, bevel: CGFloat, scale: CGFloat,
                       wallpaper: CGImage, screenSize: CGSize) -> CGImage? {
        let width = Int((frame.width * scale).rounded(.up))
        let height = Int((frame.height * scale).rounded(.up))
        // The bevel pulls in picture from outside the glass: keep a margin.
        let margin = Int((bevel * scale * 2.4).rounded(.up))
        let sourceWidth = width + 2 * margin, sourceHeight = height + 2 * margin
        guard width > 0, height > 0, screenSize.width > 0,
              let source = CGContext(data: nil, width: sourceWidth, height: sourceHeight, bitsPerComponent: 8,
                                     bytesPerRow: sourceWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let output = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // The picture as the desktop shows it (aspect fill, centred), moved
        // so that the bitmap starts `margin` pixels above-left of the glass.
        source.interpolationQuality = .high
        source.translateBy(x: 0, y: CGFloat(sourceHeight))
        source.scaleBy(x: 1, y: -1)
        source.scaleBy(x: scale, y: scale)
        source.translateBy(x: -(frame.minX - CGFloat(margin) / scale), y: -(frame.minY - CGFloat(margin) / scale))
        let fill = max(screenSize.width / CGFloat(wallpaper.width), screenSize.height / CGFloat(wallpaper.height))
        let drawn = CGSize(width: CGFloat(wallpaper.width) * fill, height: CGFloat(wallpaper.height) * fill)
        let origin = CGPoint(x: (screenSize.width - drawn.width) / 2, y: (screenSize.height - drawn.height) / 2)
        source.translateBy(x: origin.x, y: origin.y + drawn.height)
        source.scaleBy(x: 1, y: -1)
        source.draw(wallpaper, in: CGRect(origin: .zero, size: drawn))
        // Softened a little: the rim is bent from a still picture, and over
        // a moving wallpaper a soft rim stands out much less than a sharp one.
        if let sharp = source.makeImage(),
           let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: CIImage(cgImage: sharp),
                                                                     kCIInputRadiusKey: 2.2 * scale]),
           let blurred = blur.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)),
           let soft = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: blurred.extent) {
            source.saveGState()
            source.resetClip()
            source.concatenate(source.ctm.inverted())
            source.draw(soft, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
            source.restoreGState()
        }

        guard let input = source.data?.assumingMemoryBound(to: UInt8.self),
              let out = output.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let radius = Float(cornerRadius * scale)
        let bevelPx = Float(bevel * scale)
        let halfW = Float(width) / 2, halfH = Float(height) / 2
        let innerW = halfW - radius, innerH = halfH - radius
        let m = Float(margin)

        /// Bilinear sample of one channel at a pixel position in the glass's
        /// coordinates (the source is offset by the margin).
        func sample(_ x: Float, _ y: Float, _ channel: Int) -> Float {
            let sx = min(max(x + m - 0.5, 0), Float(sourceWidth - 1))
            let sy = min(max(y + m - 0.5, 0), Float(sourceHeight - 1))
            let x0 = Int(sx), y0 = Int(sy)
            let x1 = min(x0 + 1, sourceWidth - 1), y1 = min(y0 + 1, sourceHeight - 1)
            let fx = sx - Float(x0), fy = sy - Float(y0)
            let a = Float(input[(y0 * sourceWidth + x0) * 4 + channel])
            let b = Float(input[(y0 * sourceWidth + x1) * 4 + channel])
            let c = Float(input[(y1 * sourceWidth + x0) * 4 + channel])
            let d = Float(input[(y1 * sourceWidth + x1) * 4 + channel])
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }

        for y in 0..<height {
            for x in 0..<width {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let dx = px - halfW, dy = py - halfH
                let qx = abs(dx) - innerW, qy = abs(dy) - innerH
                // Distance to the rounded rectangle's edge and its outward normal.
                var nx: Float, ny: Float, edge: Float
                if qx > 0 && qy > 0 {
                    let length = (qx * qx + qy * qy).squareRoot()
                    edge = radius - length
                    nx = qx / length
                    ny = qy / length
                } else if qx > qy {
                    edge = radius - qx
                    nx = 1; ny = 0
                } else {
                    edge = radius - qy
                    nx = 0; ny = 1
                }
                if dx < 0 { nx = -nx }
                if dy < 0 { ny = -ny }

                let index = (y * width + x) * 4
                let coverage = min(max(edge + 0.5, 0), 1)
                if coverage <= 0 {
                    out[index] = 0; out[index + 1] = 0; out[index + 2] = 0; out[index + 3] = 0
                    continue
                }
                var r: Float, g: Float, b: Float
                let zx = px, zy = py
                // The middle: nothing drawn, the real lock screen shows.
                var alpha = coverage
                if edge >= bevelPx {
                    out[index] = 0; out[index + 1] = 0; out[index + 2] = 0; out[index + 3] = 0
                    continue
                } else {
                    // 1 at the very edge, 0 where the bevel ends; the curve
                    // keeps the inside calm and bends hard near the rim.
                    let t = 1 - edge / bevelPx
                    let bend = bevelPx * 1.5 * t * t * (0.3 + 0.7 * t)
                    // Look further outwards: picture from beyond the edge is
                    // drawn in, squeezed into streaks along it. Red bends a
                    // little more than blue for the colour fringe.
                    r = sample(zx + nx * bend * 1.14, zy + ny * bend * 1.14, 0)
                    g = sample(zx + nx * bend, zy + ny * bend, 1)
                    b = sample(zx + nx * bend * 0.86, zy + ny * bend * 0.86, 2)
                    // The curved glass catches a touch more light, and the
                    // light from the top left glints along the rim there
                    // (fainter bottom right).
                    let lift: Float = 1.03 + 0.06 * t
                    let towardsLight = max(0, -(nx + ny) * 0.7071)
                    let away = max(0, (nx + ny) * 0.7071)
                    let glint = (pow(towardsLight, 4) * 120 + pow(away, 4) * 60) * t * t
                    r = r * lift + glint; g = g * lift + glint; b = b * lift + glint
                    // Fades out towards the inside, where the bend is gone
                    // and the still picture would equal the live one anyway.
                    let fade = min(1, t * 2.2)
                    alpha *= 0.82 * fade * fade * (3 - 2 * fade)
                }
                out[index] = UInt8(min(255, r * alpha))
                out[index + 1] = UInt8(min(255, g * alpha))
                out[index + 2] = UInt8(min(255, b * alpha))
                out[index + 3] = UInt8(min(255, 255 * alpha))
            }
        }
        return output.makeImage()
    }
}
