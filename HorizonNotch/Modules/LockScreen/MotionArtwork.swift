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
    @Published private(set) var url: URL?
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

/// A muted video playing in an endless loop, filling its frame; reports
/// when the first frame is ready so the still cover can fade over to it.
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    @Binding var ready: Bool

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url) { ready = true }
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        if view.url != url {
            ready = false
            view.play(url) { ready = true }
        }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: NSView {
        private(set) var url: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var observation: NSKeyValueObservation?
        private let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func play(_ url: URL, ready: @escaping () -> Void) {
            stop()
            self.url = url
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            observation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { layer, _ in
                if layer.isReadyForDisplay { DispatchQueue.main.async(execute: ready) }
            }
            player.play()
            self.player = player
        }

        func stop() {
            observation = nil
            player?.pause()
            looper = nil
            player = nil
            playerLayer.player = nil
        }
    }
}
