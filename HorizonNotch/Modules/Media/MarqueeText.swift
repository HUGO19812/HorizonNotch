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
    @State private var offset: CGFloat = 0

    private let gap: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            let overflow = textWidth > proxy.size.width
            HStack(spacing: gap) {
                label
                if overflow { label }
            }
            .offset(x: overflow ? offset : 0)
            .frame(width: proxy.size.width, alignment: overflow ? .leading : .center)
            .clipped()
            .mask(edgeFade(enabled: overflow))
            .onChange(of: overflow, initial: true) { _, scrolls in restart(scrolls) }
            .onChange(of: text) { _, _ in restart(overflow) }
        }
        .frame(height: 16)
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

    private func restart(_ scrolls: Bool) {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { offset = 0 }
        guard scrolls, textWidth > 0 else { return }
        let distance = textWidth + gap
        withAnimation(.linear(duration: distance / speed).delay(1).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }

    private func edgeFade(enabled: Bool) -> some View {
        LinearGradient(stops: enabled ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
                                      : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }
}
