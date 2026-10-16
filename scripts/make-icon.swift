// Renders the Horizon Notch app icon into the asset catalog.
// Usage: swift scripts/make-icon.swift
//
// Motif: a dusk sky over a glowing horizon line, with the black island
// hanging from the top edge like the notch it lives in.
import AppKit

let output = "HorizonNotch/Resources/Assets.xcassets/AppIcon.appiconset"

func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824pt body centred in 1024 with ~185pt corner radius.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Sky: deep night at the top fading into a warm dusk near the horizon.
    let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.20, alpha: 1).cgColor,
        NSColor(srgbRed: 0.20, green: 0.16, blue: 0.45, alpha: 1).cgColor,
        NSColor(srgbRed: 0.93, green: 0.42, blue: 0.38, alpha: 1).cgColor,
        NSColor(srgbRed: 1.00, green: 0.74, blue: 0.42, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.45, 0.82, 1])!
    let horizonY = 330 * s
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: horizonY), options: [.drawsAfterEndLocation])

    // Glow of the sun just below the horizon.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 0.95).cgColor,
        NSColor(srgbRed: 1, green: 0.55, blue: 0.4, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512 * s, y: horizonY), startRadius: 0,
                           endCenter: CGPoint(x: 512 * s, y: horizonY), endRadius: 330 * s, options: [])

    // Ground below the horizon: a dark, slightly curved planet edge.
    let ground = CGMutablePath()
    ground.move(to: CGPoint(x: body.minX - 20 * s, y: horizonY - 18 * s))
    ground.addQuadCurve(to: CGPoint(x: body.maxX + 20 * s, y: horizonY - 18 * s),
                        control: CGPoint(x: 512 * s, y: horizonY + 46 * s))
    ground.addLine(to: CGPoint(x: body.maxX + 20 * s, y: body.minY - 20 * s))
    ground.addLine(to: CGPoint(x: body.minX - 20 * s, y: body.minY - 20 * s))
    ground.closeSubpath()
    ctx.addPath(ground)
    ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.04, blue: 0.09, alpha: 1).cgColor)
    ctx.fillPath()

    // Bright rim on the planet edge.
    let rim = CGMutablePath()
    rim.move(to: CGPoint(x: body.minX - 20 * s, y: horizonY - 18 * s))
    rim.addQuadCurve(to: CGPoint(x: body.maxX + 20 * s, y: horizonY - 18 * s),
                     control: CGPoint(x: 512 * s, y: horizonY + 46 * s))
    ctx.addPath(rim)
    ctx.setStrokeColor(NSColor(srgbRed: 1, green: 0.88, blue: 0.7, alpha: 1).cgColor)
    ctx.setLineWidth(9 * s)
    ctx.setShadow(offset: .zero, blur: 24 * s, color: NSColor(srgbRed: 1, green: 0.7, blue: 0.45, alpha: 1).cgColor)
    ctx.strokePath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // The island, hanging from the top edge with concave ears.
    let w: CGFloat = 400 * s, h: CGFloat = 150 * s, ear: CGFloat = 34 * s, r: CGFloat = 75 * s
    let left = 512 * s - w / 2 - ear, right = 512 * s + w / 2 + ear, top = body.maxY
    let island = CGMutablePath()
    island.move(to: CGPoint(x: left, y: top))
    island.addQuadCurve(to: CGPoint(x: left + ear, y: top - ear), control: CGPoint(x: left + ear, y: top))
    island.addLine(to: CGPoint(x: left + ear, y: top - h + r))
    island.addQuadCurve(to: CGPoint(x: left + ear + r, y: top - h), control: CGPoint(x: left + ear, y: top - h))
    island.addLine(to: CGPoint(x: right - ear - r, y: top - h))
    island.addQuadCurve(to: CGPoint(x: right - ear, y: top - h + r), control: CGPoint(x: right - ear, y: top - h))
    island.addLine(to: CGPoint(x: right - ear, y: top - ear))
    island.addQuadCurve(to: CGPoint(x: right, y: top), control: CGPoint(x: right - ear, y: top))
    island.closeSubpath()
    ctx.addPath(island)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()

    // Live activity inside the island: a small dot and three level bars.
    let midY = top - h / 2 - 8 * s
    ctx.setFillColor(NSColor(srgbRed: 1, green: 0.7, blue: 0.45, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: 512 * s - w / 2 + 52 * s, y: midY - 22 * s, width: 44 * s, height: 44 * s))
    let heights: [CGFloat] = [46, 70, 34]
    for (i, bh) in heights.enumerated() {
        let x = 512 * s + w / 2 - 122 * s + CGFloat(i) * 30 * s
        let bar = CGPath(roundedRect: CGRect(x: x, y: midY - bh * s / 2, width: 16 * s, height: bh * s),
                         cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil)
        ctx.addPath(bar)
        ctx.fillPath()
    }

    // A few stars.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    for (x, y, d) in [(230, 640, 9), (760, 700, 7), (650, 560, 6), (330, 520, 5), (820, 540, 8), (180, 760, 6)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.fillEllipse(in: CGRect(x: x * s, y: y * s, width: d * s, height: d * s))
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let url = URL(fileURLWithPath: "\(output)/icon_\(size).png")
    try! render(size: CGFloat(size)).write(to: url)
}
print("icons written to \(output)")
