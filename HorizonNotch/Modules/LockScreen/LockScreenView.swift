import SwiftUI

/// Widgets on the lock screen: a column on the left so it stays clear of
/// the system clock (top) and the password field (bottom centre).
struct LockScreenView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var weather: WeatherService
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 14) {
                ClockCard()
                if let report = weather.report { WeatherCard(report: report, place: weather.placeName) }
                if let info = nowPlaying.info {
                    PlayerCard(service: nowPlaying, lyrics: lyrics, info: info, showLyrics: settings.showLyrics)
                }
            }
            .frame(width: 340)
            .padding(.leading, 64)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: nowPlaying.info?.title)
    }
}

/// Translucent card: Liquid Glass on macOS 26+, material before.
private struct LockCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let padded = content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        if #available(macOS 26.0, *) {
            padded.glassEffect(.regular.tint(.black.opacity(0.2)), in: shape)
        } else {
            padded.background(shape.fill(.ultraThinMaterial))
                .background(shape.fill(Color.black.opacity(0.25)))
        }
    }
}

private struct ClockCard: View {
    var body: some View {
        LockCard {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 58, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)
                        .locale(Locale(identifier: AppSettings.shared.isGerman ? "de_AT" : "en_US"))))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }
}

private struct WeatherCard: View {
    let report: WeatherService.Report
    let place: String

    var body: some View {
        LockCard {
            HStack(spacing: 14) {
                Image(systemName: WeatherCode.symbol(report.code, isDay: report.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(report.temperature.rounded()))°  \(WeatherCode.text(report.code))")
                        .font(.system(size: 18, weight: .semibold))
                    Text("\(place.isEmpty ? "" : place + " · ")↑\(Int(report.high.rounded()))° ↓\(Int(report.low.rounded()))°")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }
}

private struct PlayerCard: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    let info: NowPlayingInfo
    let showLyrics: Bool

    var body: some View {
        LockCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CoverArt(image: service.artwork, cornerRadius: 12)
                        .frame(width: 60, height: 60)
                        .background { if AppSettings.shared.albumTint { AlbumGlow(image: service.artwork, cornerRadius: 12) } }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(info.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                TimelineView(.periodic(from: .now, by: info.isPlaying ? 0.5 : 3600)) { context in
                    let position = info.elapsed(at: context.date)
                    VStack(alignment: .leading, spacing: 8) {
                        if showLyrics, lyrics.state == .loaded, let index = lyrics.index(at: position) {
                            Text(lyrics.lines[index].text.isEmpty ? "♪" : lyrics.lines[index].text)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(2)
                                .id(index)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                .animation(.easeInOut(duration: 0.3), value: index)
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule().fill(service.accent)
                                    .frame(width: proxy.size.width * CGFloat(info.duration > 0 ? min(position / info.duration, 1) : 0))
                            }
                        }
                        .frame(height: 4)
                    }
                }
                HStack {
                    Spacer()
                    LockButton(symbol: "backward.fill") { service.send(.previous) }
                    Spacer()
                    LockButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 24) { service.send(.togglePlayPause) }
                    Spacer()
                    LockButton(symbol: "forward.fill") { service.send(.next) }
                    Spacer()
                }
            }
        }
        .onAppear { if showLyrics { lyrics.load(for: info) } }
        .onChange(of: info.title) { _, _ in if showLyrics { lyrics.load(for: info) } }
    }
}

private struct LockButton: View {
    let symbol: String
    var size: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
