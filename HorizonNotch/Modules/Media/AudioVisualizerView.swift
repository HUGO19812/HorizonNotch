import AppKit
import SwiftUI

/// Decorative level bars. Animated with Core Animation on the render
/// server, so they cost (almost) no CPU while music plays.
struct AudioVisualizerView: NSViewRepresentable {
    var color: NSColor
    var isPlaying: Bool
    var barCount = 4

    func makeNSView(context: Context) -> VisualizerNSView {
        VisualizerNSView(barCount: barCount)
    }

    func updateNSView(_ view: VisualizerNSView, context: Context) {
        view.update(color: color, playing: isPlaying)
    }
}

final class VisualizerNSView: NSView {
    private var bars: [CALayer] = []
    private var playing: Bool?

    init(barCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width: CGFloat = 3
        let spacing: CGFloat = 2.5
        let total = CGFloat(bars.count) * width + CGFloat(bars.count - 1) * spacing
        var x = (bounds.width - total) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: x + width / 2, y: bounds.midY)
            x += width + spacing
        }
        CATransaction.commit()
    }

    /// Resting height while paused: every bar equally short.
    private static let restScale: CGFloat = 0.3
    private static let pausedColor = NSColor(white: 0.45, alpha: 1)

    func update(color: NSColor, playing: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        bars.forEach { $0.backgroundColor = (playing ? color : Self.pausedColor).cgColor }
        CATransaction.commit()
        guard playing != self.playing else { return }
        self.playing = playing
        for (index, bar) in bars.enumerated() {
            if playing {
                let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                animation.values = (0..<6).map { _ in CGFloat.random(in: 0.25...1.0) } + [0.35]
                animation.duration = Double.random(in: 0.9...1.4)
                animation.calculationMode = .cubic
                animation.repeatCount = .infinity
                animation.autoreverses = true
                animation.beginTime = CACurrentMediaTime() + Double(index) * 0.07
                bar.add(animation, forKey: "level")
            } else {
                // Glide from wherever the bar is into its resting height.
                let current = (bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat) ?? 1
                bar.removeAnimation(forKey: "level")
                let rest = Self.restScale
                let settle = CABasicAnimation(keyPath: "transform.scale.y")
                settle.fromValue = current
                settle.toValue = rest
                settle.duration = 0.3
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.transform = CATransform3DMakeScale(1, rest, 1)
                bar.add(settle, forKey: "settle")
            }
        }
    }
}
