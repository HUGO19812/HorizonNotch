import Combine
import SwiftUI

/// Now Playing: compact cover + visualizer, expanded player with controls,
/// and a sneak peek when playback starts, the track changes or the user
/// skips within a track.
final class MediaModule: NotchModule {
    enum Peek: Equatable {
        case started, track, seekForward(Int), seekBackward(Int)
    }

    let id = "media"
    var title: String { L("Musik", "Now Playing") }
    let symbol = "music.note"
    let hasExpandedContent = true

    let service: NowPlayingService
    let lyrics = LyricsService()
    @Published private(set) var peek: Peek?

    private let settings = AppSettings.shared
    private var subscriptions = Set<AnyCancellable>()
    private var lastInfo: NowPlayingInfo?
    private var peekWork: DispatchWorkItem?
    private var launchedAt = Date()

    init(service: NowPlayingService) {
        self.service = service
        service.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        service.$info.sink { [weak self] info in self?.infoChanged(to: info) }.store(in: &subscriptions)
        settings.$albumTint.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        service.userSeeked.sink { [weak self] delta in self?.seeked(by: delta) }.store(in: &subscriptions)
    }

    /// A peek is a short notification, so it outranks the timer for its
    /// few seconds; otherwise music has the lowest priority.
    var priority: Int { peek != nil ? ModulePriority.notification - 1 : ModulePriority.media }

    /// The live activity stays while media is paused; only the
    /// visualizer stops moving.
    var isActive: Bool { service.info != nil || peek != nil }

    private var peekInline: Bool { peek != nil && settings.sneakPeekStyle == .inline }
    /// Standard style: a line with the song below the notch.
    var isPeeking: Bool { peek != nil && settings.sneakPeekStyle == .standard }
    let peekHeight: CGFloat = 24
    /// Inline style widens the wings to fit title and artist.
    var compactWingWidth: CGFloat { peekInline ? 150 : 40 }

    // MARK: - Sneak peek

    private func infoChanged(to new: NowPlayingInfo?) {
        defer { lastInfo = new }
        // No peek for whatever is already playing when the app starts.
        guard settings.sneakPeek, let new, new.isPlaying, Date().timeIntervalSince(launchedAt) > 3 else { return }
        guard let old = lastInfo else {
            showPeek(.started)
            return
        }
        if old.title != new.title || old.artist != new.artist {
            showPeek(.track)
        } else if !old.isPlaying {
            showPeek(.started)
        }
    }

    private func seeked(by delta: Double) {
        guard settings.sneakPeek, settings.sneakPeekOnSeek, abs(delta) >= 2 else { return }
        let seconds = Int(abs(delta).rounded())
        showPeek(delta > 0 ? .seekForward(seconds) : .seekBackward(seconds))
    }

    private func showPeek(_ kind: Peek) {
        peek = kind
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.peek = nil }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1.5, settings.sneakPeekDuration), execute: work)
    }

    #if DEBUG
    func debugPeek() { showPeek(.track) }
    #endif

    func compactLeading() -> AnyView {
        guard peekInline else { return AnyView(MediaCompactCover(service: service)) }
        return AnyView(HStack(spacing: 8) {
            MediaCompactCover(service: service)
            MarqueeText(text: service.info?.title ?? "", font: .system(size: 11, weight: .semibold),
                        color: peekColor)
        }
        .padding(.leading, 8))
    }

    func compactTrailing() -> AnyView {
        guard peekInline else { return AnyView(MediaCompactVisualizer(service: service)) }
        return AnyView(HStack(spacing: 8) {
            Text(peekDetail ?? service.info?.artist ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(peekColor.opacity(0.8))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            MediaCompactVisualizer(service: service)
        }
        .padding(.trailing, 8))
    }

    /// Album colour when tinting is on, else grey – like the rest of the island.
    var peekColor: Color { settings.albumTint ? service.accent : Color(white: 0.7) }

    /// "+15 s" / "−10 s" after a seek, nil otherwise.
    var peekDetail: String? {
        switch peek {
        case .seekForward(let seconds): return "+\(seconds) s"
        case .seekBackward(let seconds): return "−\(seconds) s"
        default: return nil
        }
    }
    func expandedView() -> AnyView { AnyView(MediaExpandedView(service: service, lyrics: lyrics)) }
    func peekView() -> AnyView { AnyView(MediaPeekView(module: self)) }
}

/// Standard sneak peek: one line below the notch with a note symbol and
/// "Title – Artist" scrolling if it is too long.
private struct MediaPeekView: View {
    @ObservedObject var module: MediaModule

    var body: some View {
        let info = module.service.info
        let song = [info?.title ?? "", info?.artist ?? ""].filter { !$0.isEmpty }.joined(separator: " – ")
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(module.peekColor)
            MarqueeText(text: [module.peekDetail, song].compactMap { $0 }.joined(separator: "  ·  "),
                        font: .system(size: 11, weight: .medium), color: module.peekColor)
        }
        .padding(.top, 1)
    }

    private var symbol: String {
        switch module.peek {
        case .seekForward: return "goforward"
        case .seekBackward: return "gobackward"
        default: return "music.note"
        }
    }
}
