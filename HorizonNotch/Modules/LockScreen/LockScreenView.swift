import SwiftUI

/// The lock screen shows one thing: the music player, like on the iPhone.
/// Centred between the system clock (top) and the password field (bottom);
/// nothing at all while nothing plays.
struct LockScreenView: View {
    @ObservedObject var nowPlaying: NowPlayingService

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let info = nowPlaying.info {
                    LockPlayer(service: nowPlaying, info: info)
                        .frame(width: 380)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            // Slightly below the middle: the clock needs the top third.
            .position(x: proxy.size.width / 2, y: proxy.size.height * 0.56)
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: nowPlaying.info == nil)
    }
}

/// Translucent card: Liquid Glass on macOS 26+, material before.
private struct LockCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let padded = content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        if #available(macOS 26.0, *) {
            padded.glassEffect(.regular.tint(.black.opacity(0.2)), in: shape)
        } else {
            padded.background(shape.fill(.ultraThinMaterial))
                .background(shape.fill(Color.black.opacity(0.25)))
        }
    }
}

/// Cover and title, progress with times, the three buttons and volume.
private struct LockPlayer: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var output = AudioOutput.shared
    let info: NowPlayingInfo

    var body: some View {
        LockCard {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    CoverArt(image: service.artwork, cornerRadius: 10)
                        .frame(width: 56, height: 56)
                        .background { if AppSettings.shared.albumTint { AlbumGlow(image: service.artwork, cornerRadius: 10) } }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: output.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .help(output.deviceName)
                }

                LockProgress(info: info)

                HStack {
                    Spacer()
                    LockButton(symbol: "backward.fill", size: 24) { service.send(.previous) }
                    Spacer()
                    LockButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 34) {
                        service.send(.togglePlayPause)
                    }
                    .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    LockButton(symbol: "forward.fill", size: 24) { service.send(.next) }
                    Spacer()
                }

                LockVolume()
            }
        }
    }
}

/// Thin progress bar with elapsed time left and remaining time right.
private struct LockProgress: View {
    let info: NowPlayingInfo

    var body: some View {
        TimelineView(.periodic(from: .now, by: info.isPlaying ? 0.5 : 3600)) { context in
            let position = info.elapsed(at: context.date)
            let fraction = info.duration > 0 ? min(position / info.duration, 1) : 0
            VStack(spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white.opacity(0.85))
                            .frame(width: proxy.size.width * CGFloat(fraction))
                    }
                }
                .frame(height: 5)
                HStack {
                    Text(time(position))
                    Spacer()
                    Text("-" + time(max(0, info.duration - position)))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Volume slider between a quiet and a loud speaker.
private struct LockVolume: View {
    private let output = AudioOutput.shared
    @State private var level: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: proxy.size.width * level)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    level = min(max(drag.location.x / proxy.size.width, 0), 1)
                    output.volume = Float(level)
                    if output.isMuted && level > 0 { output.isMuted = false }
                })
            }
            .frame(height: 5)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.5))
        .opacity(output.canSetVolume ? 1 : 0)
        .onAppear { level = Double(output.isMuted ? 0 : output.volume) }
    }
}

private struct LockButton: View {
    let symbol: String
    var size: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 60, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
