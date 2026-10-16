import SwiftUI

/// The lock screen shows one thing: the music player, in one of three
/// styles (Settings → Lock Screen, or click the cover to switch):
/// - compact: a small glass card above the password field,
/// - artwork: a large cover below the clock with the card under it,
/// - lyrics: cover and card on the left, synced lyrics on the right.
/// Nothing at all while nothing plays.
struct LockScreenView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let info = nowPlaying.info {
                    let style = effectiveStyle
                    if style != .compact {
                        CoverBackdrop(image: nowPlaying.artwork)
                            .transition(.opacity)
                    }
                    content(info: info, style: style, size: proxy.size)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.coverTint, nowPlaying.artwork != nil ? nowPlaying.accent : .white)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: nowPlaying.info == nil)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: effectiveStyle)
        .onAppear { loadLyrics() }
        .onChange(of: nowPlaying.info?.title) { _, _ in loadLyrics() }
        .onChange(of: settings.lockScreenStyle) { _, _ in loadLyrics() }
    }

    /// The lyrics style falls back to the large cover without synced lyrics.
    private var effectiveStyle: LockScreenStyle {
        if settings.lockScreenStyle == .lyrics && lyrics.state != .loaded && lyrics.state != .loading {
            return .artwork
        }
        return settings.lockScreenStyle
    }

    private func loadLyrics() {
        guard settings.lockScreenStyle == .lyrics, let info = nowPlaying.info else { return }
        lyrics.load(for: info)
    }

    /// Click on the cover: compact → large cover → lyrics → compact.
    private func nextStyle() {
        let all = LockScreenStyle.allCases
        let index = all.firstIndex(of: settings.lockScreenStyle) ?? 0
        settings.lockScreenStyle = all[(index + 1) % all.count]
    }

    @ViewBuilder
    private func content(info: NowPlayingInfo, style: LockScreenStyle, size: CGSize) -> some View {
        let cover = min(280, size.height * 0.3)
        switch style {
        case .compact:
            LockControls(service: nowPlaying, info: info, showsCover: true, onCoverTap: nextStyle)
                .frame(width: 300)
                // Above "Touch ID or Enter Password".
                .position(x: size.width / 2, y: size.height * 0.68)
        case .artwork:
            VStack(spacing: 18) {
                LargeCover(image: nowPlaying.artwork, size: cover, onTap: nextStyle)
                LockControls(service: nowPlaying, info: info, showsCover: false, onCoverTap: nextStyle)
                    .frame(width: cover + 20)
            }
            // Just below the clock.
            .position(x: size.width / 2, y: size.height * 0.27 + (cover + 140) / 2)
        case .lyrics:
            HStack(alignment: .center, spacing: 70) {
                VStack(spacing: 18) {
                    LargeCover(image: nowPlaying.artwork, size: cover * 0.85, onTap: nextStyle)
                    LockControls(service: nowPlaying, info: info, showsCover: false, onCoverTap: nextStyle)
                        .frame(width: cover * 0.85 + 20)
                }
                LyricsPanel(lyrics: lyrics, info: info, large: true, fontSize: 24) { nowPlaying.seek(to: $0) }
                    .frame(width: 420, height: cover * 0.85 + 140)
            }
            .position(x: size.width / 2, y: size.height * 0.27 + (cover * 0.85 + 140) / 2)
        }
    }
}

/// The cover's colours, hugely blurred, darken the wallpaper behind the
/// large styles – like the tinted background in Apple Music.
private struct CoverBackdrop: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 120)
                    .opacity(0.55)
                    .saturation(1.2)
            }
            Color.black.opacity(0.2)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .clipped()
    }
}

private struct LargeCover: View {
    let image: NSImage?
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        CoverArt(image: image, cornerRadius: 16)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .onTapGesture(perform: onTap)
    }
}

/// Glass card: optional small cover with title, progress with times, then
/// shuffle, back, play/pause, forward and repeat.
private struct LockControls: View {
    @ObservedObject var service: NowPlayingService
    let info: NowPlayingInfo
    let showsCover: Bool
    let onCoverTap: () -> Void

    var body: some View {
        GlassCard {
            VStack(spacing: 10) {
                if showsCover {
                    HStack(spacing: 10) {
                        CoverArt(image: service.artwork, cornerRadius: 6)
                            .frame(width: 38, height: 38)
                            .onTapGesture(perform: onCoverTap)
                        titles(alignment: .leading)
                        Spacer(minLength: 0)
                    }
                } else {
                    titles(alignment: .center)
                        .frame(maxWidth: .infinity)
                }
                LockProgress(service: service, info: info)
                HStack(spacing: 0) {
                    small("shuffle", active: info.isShuffling) { service.toggleShuffle() }
                    Spacer(minLength: 0)
                    LockButton(symbol: "backward.fill", size: 17) { service.send(.previous) }
                    Spacer(minLength: 0)
                    LockButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                        service.send(.togglePlayPause)
                    }
                    Spacer(minLength: 0)
                    LockButton(symbol: "forward.fill", size: 17) { service.send(.next) }
                    Spacer(minLength: 0)
                    small(info.repeatMode == 2 ? "repeat.1" : "repeat", active: info.repeatMode > 1) { service.cycleRepeat() }
                }
            }
        }
    }

    private func titles(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(info.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func small(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        LockButton(symbol: symbol, size: 11, action: action)
            .foregroundStyle(active ? .white : .white.opacity(0.45))
            .opacity(service.usingFallback ? 0.3 : 1)
    }
}

/// Translucent, lightly outlined card: Liquid Glass on macOS 26+.
private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let padded = content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        Group {
            if #available(macOS 26.0, *) {
                padded.glassEffect(.regular.tint(.black.opacity(0.15)), in: shape)
            } else {
                padded.background(shape.fill(.ultraThinMaterial))
                    .background(shape.fill(Color.black.opacity(0.2)))
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

/// Draggable progress bar with elapsed time left and remaining time right.
private struct LockProgress: View {
    @ObservedObject var service: NowPlayingService
    let info: NowPlayingInfo
    @State private var dragValue: Double?

    var body: some View {
        let info = service.info ?? self.info
        TimelineView(.periodic(from: .now, by: info.isPlaying && dragValue == nil ? 0.5 : 3600)) { context in
            let position = dragValue ?? info.elapsed(at: context.date)
            let fraction = info.duration > 0 ? min(max(position / info.duration, 0), 1) : 0
            HStack(spacing: 8) {
                Text(time(position))
                    .frame(width: 34, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: proxy.size.width * CGFloat(fraction))
                    }
                    .frame(height: dragValue == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard info.duration > 0 else { return }
                            dragValue = Double(min(max(drag.location.x / proxy.size.width, 0), 1)) * info.duration
                        }
                        .onEnded { _ in
                            if let value = dragValue { service.seek(to: value) }
                            dragValue = nil
                        })
                }
                .frame(height: 12)
                Text("-" + time(max(0, info.duration - position)))
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LockButton: View {
    let symbol: String
    var size: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
