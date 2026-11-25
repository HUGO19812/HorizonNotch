import AVFoundation
import AppKit
import SwiftUI

/// The moving album cover Apple Music shows for some albums ("motion
/// artwork", e.g. Coldplay's Parachutes). Found without any account: the
/// song is looked up in the iTunes catalogue, and the album's public page on
/// music.apple.com names the square video ("motionDetailSquare") as an HLS
/// stream. Only taken when artist and title match.
@MainActor
final class MotionArtwork: ObservableObject {
    @Published private(set) var url: URL? {
        didSet { if url != oldValue { discardPlayer() } }
    }
    /// The video is buffered and playing: it can be shown at once.
    @Published private(set) var ready = false
    /// Prepared before it is shown (see `prepare`), muted, looping.
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var key = ""
    private static var cache: [String: URL?] = [:]

    func load(for info: NowPlayingInfo?) async {
        guard let info, !info.title.isEmpty else { url = nil; key = ""; return }
        let key = info.artist + "|" + info.title
        guard key != self.key else { return }
        self.key = key
        if let cached = Self.cache[key] { url = cached; return }
        url = nil
        let found = await Self.find(artist: info.artist, title: info.title)
        guard key == self.key else { return }
        Self.cache[key] = found
        url = found
    }

    /// Starts buffering the video in the background, so the large player
    /// can switch to it in one smooth step once `ready`. Starts on a low
    /// bitrate (quicker first frames), then lets the stream pick the best.
    func prepare() {
        guard let url, player == nil else { return }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let template = AVPlayerItem(url: url)
        template.preferredForwardBufferDuration = 2
        let looper = AVPlayerLooper(player: player, templateItem: template)
        for item in looper.loopingPlayerItems { item.preferredPeakBitRate = 2_500_000 }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            DispatchQueue.main.async {
                guard let self, self.player === player, !self.ready else { return }
                self.ready = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, self.player === player else { return }
                    for item in self.looper?.loopingPlayerItems ?? [] { item.preferredPeakBitRate = 0 }
                }
            }
        }
        self.player = player
        self.looper = looper
        player.play()
    }

    private func discardPlayer() {
        statusObservation = nil
        player?.pause()
        looper = nil
        player = nil
        if ready { ready = false }
    }

    private static func find(artist: String, title: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(HiResArtwork.normalized(title))"),
                                 URLQueryItem(name: "entity", value: "song"),
                                 URLQueryItem(name: "limit", value: "10")]
        guard let searchURL = components.url,
              let (data, _) = try? await URLSession.shared.data(from: searchURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let wantedArtist = HiResArtwork.normalized(artist), wantedTitle = HiResArtwork.normalized(title)
        let hit = results.first { result in
            let hitArtist = HiResArtwork.normalized(result["artistName"] as? String ?? "")
            let hitTitle = HiResArtwork.normalized(result["trackName"] as? String ?? "")
            return !hitArtist.isEmpty && (hitArtist.contains(wantedArtist) || wantedArtist.contains(hitArtist))
                && hitTitle == wantedTitle
        }
        guard let album = hit?["collectionId"] as? Int,
              let page = URL(string: "https://music.apple.com/us/album/\(album)") else { return nil }
        var request = URLRequest(url: page)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (html, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: html, encoding: .utf8) else { return nil }
        return videoURL(in: text)
    }

    /// The first "video" after "motionDetailSquare" in the page's data.
    static func videoURL(in page: String) -> URL? {
        let text = page.replacingOccurrences(of: "\\u002F", with: "/")
        guard let start = text.range(of: "\"motionDetailSquare\"") else { return nil }
        let rest = text[start.upperBound...].prefix(4000)
        guard let video = rest.range(of: "\"video\":\"") else { return nil }
        let tail = rest[video.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let link = String(tail[..<end])
        return link.hasPrefix("https://") && link.contains(".m3u8") ? URL(string: link) : nil
    }
}

/// A muted video playing in an endless loop, filling its frame. The player
/// comes buffered from MotionArtwork, so the first frame is there at once.
struct LoopingVideo: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer?.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        guard view.playerLayer?.player !== player else { return }
        view.playerLayer?.player = player
        player.play()
    }

    /// Not shown (back to the small player): no need to keep decoding.
    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer?.player?.pause()
        view.playerLayer?.player = nil
    }

    final class PlayerView: NSView {
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        /// The video layer is the view's own layer, so it always has the
        /// view's frame – a sublayer would follow a resize with its own
        /// implicit animation, growing out of the lower left corner.
        override func makeBackingLayer() -> CALayer {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspectFill
            return layer
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
