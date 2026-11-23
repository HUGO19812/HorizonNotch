import AppKit
import SwiftUI

/// A colour field to drag across, right where it's needed (the island can't
/// show the system colour panel): hue from left to right, saturation from
/// the bottom (white) to the top (full colour).
struct SpectrumPicker: View {
    /// Hue and saturation, 0…1.
    @Binding var hue: Double
    @Binding var saturation: Double
    var cornerRadius: CGFloat = 12
    /// Called while dragging.
    var onChange: (NSColor) -> Void = { _ in }

    static func color(hue: Double, saturation: Double) -> NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1)
    }

    /// Hue and saturation of a colour, for starting the picker on it.
    static func components(of color: NSColor) -> (hue: Double, saturation: Double) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
                    Color(hue: $0, saturation: 1, brightness: 1)
                }, startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(Color(nsColor: Self.color(hue: hue, saturation: saturation)))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: size.width * hue - 10, y: size.height * (1 - saturation) - 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    hue = min(max(drag.location.x / size.width, 0), 0.999)
                    saturation = min(max(1 - drag.location.y / size.height, 0), 1)
                    onChange(Self.color(hue: hue, saturation: saturation))
                })
        }
    }
}
