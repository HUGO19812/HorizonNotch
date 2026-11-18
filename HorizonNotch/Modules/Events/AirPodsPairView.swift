import AppKit
import SwiftUI

/// The two earbuds as Apple's own renders, read from macOS at run time
/// (HeadphoneAssets, the pictures System Settings shows – nothing is
/// bundled). They stand side by side, tilt gently in 3D with a sheen
/// gliding over them, over a soft shadow. Falls back to the system symbol
/// when macOS has no such pictures.
struct AirPodsPairView: View {
    /// Tilts slowly; off for small, static uses.
    var spinning = true

    var body: some View {
        if let buds = SystemBudImages.pair {
            if spinning {
                TimelineView(.animation) { context in
                    pair(buds, swing: sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 6))
                }
            } else {
                pair(buds, swing: 0)
            }
        } else {
            Image(systemName: "airpodspro")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(6)
        }
    }

    /// swing runs from -1 to 1 and back.
    private func pair(_ buds: (left: NSImage, right: NSImage), swing: Double) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let budWidth = size.width * 0.56
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: size.width * 0.7, height: size.height * 0.08)
                    .blur(radius: size.height * 0.04)
                    .offset(y: size.height * 0.46)
                // The right bud on the left, so both tips point outwards and
                // the stems meet in the middle, like the connect banner.
                bud(buds.right, width: budWidth, swing: swing, tilt: 14)
                    .offset(x: -size.width * 0.2, y: sin(swing * .pi / 2) * size.height * 0.015)
                bud(buds.left, width: budWidth, swing: swing, tilt: -14)
                    .offset(x: size.width * 0.2, y: size.height * 0.04 - sin(swing * .pi / 2) * size.height * 0.015)
            }
            .frame(width: size.width, height: size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func bud(_ image: NSImage, width: CGFloat, swing: Double, tilt: Double) -> some View {
        let picture = Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        return picture
            .frame(width: width)
            // A light band gliding across with the turn.
            .overlay {
                LinearGradient(colors: [.clear, .white.opacity(0.2), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: width * 0.35)
                    .offset(x: swing * width * 0.45)
                    // Masked over the whole bud, so the band only lights it.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mask(picture)
                    .blendMode(.plusLighter)
            }
            .rotation3DEffect(.degrees(tilt + swing * 16), axis: (x: 0.15, y: 1, z: 0), perspective: 0.55)
            .shadow(color: .black.opacity(0.35), radius: 5, y: 4)
    }
}

/// Apple's renders of the single AirPods Pro buds from the Mac's own
/// HeadphoneAssets framework, loaded once.
enum SystemBudImages {
    static let pair: (left: NSImage, right: NSImage)? = {
        let path = "/System/Library/PrivateFrameworks/HeadphoneAssets.framework"
        guard let bundle = Bundle(path: path) else { return nil }
        for (left, right) in [("airpod_left", "airpod_right"), ("B788_airpod_left", "B788_airpod_right")] {
            if let l = bundle.image(forResource: left), let r = bundle.image(forResource: right) { return (l, r) }
        }
        return nil
    }()
}
