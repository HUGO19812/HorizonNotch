import SwiftUI

/// Single-line text that scrolls sideways when it does not fit, pausing
/// briefly at the start of every pass.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .medium)
    var color: Color = .white
    /// Points per second.
    var speed: Double = 30

    @State private var textWidth: CGFloat = 0
    /// When the current pass started. The offset is computed from the time
    /// instead of a repeating animation: such an animation could get stuck
    /// mid-way when the text or the island's size changed, leaving the line
    /// scrolled out of sight (only the note showed in the sneak peek).
    @State private var start = Date()

    private let gap: CGFloat = 36
    private let pause: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let overflow = textWidth > proxy.size.width + 0.5
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !overflow)) { context in
                HStack(spacing: gap) {
                    label
                    if overflow { label }
                }
                .offset(x: overflow ? offset(at: context.date) : 0)
                .frame(width: proxy.size.width, alignment: overflow ? .leading : .center)
            }
            .clipped()
            .mask(edgeFade(enabled: overflow))
            .onChange(of: overflow) { _, _ in start = Date() }
            .onChange(of: text) { _, _ in start = Date() }
        }
        .frame(height: 16)
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = Double(textWidth + gap)
        guard distance > 0, speed > 0 else { return 0 }
        let cycle = pause + distance / speed
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
        return t < pause ? 0 : -CGFloat((t - pause) * speed)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.onAppear { textWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in textWidth = width }
            })
    }

    private func edgeFade(enabled: Bool) -> some View {
        LinearGradient(stops: enabled ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
                                      : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }
}
