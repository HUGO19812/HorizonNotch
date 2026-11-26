import AppKit
import CoreImage
import SwiftUI

/// The large lock screen player in the look of Spicetify's Spicy Lyrics –
/// one view for the large cover and for cover + lyrics, so switching
/// between them moves things instead of swapping screens. Everything sits
/// below the clock, over a slowly moving wash of the cover's colours that
/// swells with the music.
///
/// - Still cover: a card with the player under it – centred without
///   lyrics, on the left with lyrics.
/// - Moving cover (Apple Music's motion artwork): the video fills the
///   screen without lyrics and the left half with lyrics, the player in the
///   lower left.
/// The lyrics, on the right, light up word by word; a click on the cover
/// goes back to the small player.
struct SpicyLockScreen: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var motion: MotionArtwork
    @ObservedObject private var settings = AppSettings.shared
    let info: NowPlayingInfo
    let size: CGSize
    /// A sharper copy of the cover, if one was found.
    var artwork: NSImage?
    let showLyrics: Bool
    /// False when the song has no synced lyrics (the button is greyed out).
    let lyricsAvailable: Bool
    /// Shared with the small player, so the cover flies between them.
    let namespace: Namespace.ID
    let toggleLyrics: () -> Void
    /// Back to the small player.
    let minimize: () -> Void
    /// Shown as an ordinary window (opened from the notch): a faint close
    /// button in the corner, only while the pointer moves.
    var close: (() -> Void)?

    /// The layout for a moving cover; follows `motion.ready`, animated.
    @State private var moving = false
    /// The video over the still cover; fades in once the still cover has
    /// grown to the video's size, so the video never shows inside the card.
    @State private var videoVisible = false
    @State private var palette: [Color] = []
    @State private var controlsVisible = true
    @State private var lastMouse = NSEvent.mouseLocation
    @State private var hideWork: DispatchWorkItem?
    /// The panel above the lock screen gets no mouse-moved events, so the
    /// pointer is looked at a few times a second instead.
    private let mouseTick = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    /// Now and then the player's exact position, so the lyrics stay in step.
    private let positionTick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private enum Mode { case card, cardLyrics, motion, motionLyrics }

    /// Everything starts below the clock; behind the clock is only the
    /// background (or the moving cover, darkened there).
    private var top: CGFloat { size.height * 0.27 }
    private var lineSize: CGFloat { max(28, size.height * 0.045) }
    private var image: NSImage? { artwork ?? nowPlaying.artwork }
    private var mode: Mode {
        switch (moving, showLyrics) {
        case (false, false): return .card
        case (false, true): return .cardLyrics
        case (true, false): return .motion
        case (true, true): return .motionLyrics
        }
    }
    /// Room the player takes under a card.
    private let playerHeight: CGFloat = 150

    /// Where the cover sits and how large it is.
    private var coverRect: CGRect {
        switch mode {
        case .card:
            // Centred, ending above the password field.
            let side = min(size.height * 0.355, size.width * 0.3)
            let blockTop = top + max(0, (size.height * 0.8 - top - side - playerHeight) / 2)
            return CGRect(x: size.width / 2 - side / 2, y: blockTop, width: side, height: side)
        case .cardLyrics:
            let side = min(size.height * 0.42, size.width * 0.27)
            let blockTop = top + max(0, (size.height * 0.96 - top - side - playerHeight) / 2)
            return CGRect(x: size.width * 0.25 - side / 2, y: blockTop, width: side, height: side)
        case .motion:
            return CGRect(origin: .zero, size: size)
        case .motionLyrics:
            return CGRect(x: 0, y: 0, width: size.width * 0.53, height: size.height)
        }
    }

    /// The player: under the card, or in the lower left over a moving cover.
    private var playerRect: CGRect {
        switch mode {
        case .card, .cardLyrics:
            let cover = coverRect
            let width = max(cover.width, 320)
            return CGRect(x: cover.midX - width / 2, y: cover.maxY + 20, width: width, height: playerHeight - 20)
        case .motion, .motionLyrics:
            let width = min(size.width * 0.3, 420)
            // Centred under a full-screen moving cover; in the lower left
            // beside the lyrics.
            let x = mode == .motion ? (size.width - width) / 2 : size.width * 0.035
            return CGRect(x: x, y: size.height - 40 - 130, width: width, height: 130)
        }
    }

    private var lyricsRect: CGRect {
        let left = size.width * (mode == .motionLyrics ? 0.55 : 0.5)
        let y = top - size.height * 0.01
        // Ends above the password field's height, so nothing runs under it.
        let bottom = size.height * 0.82
        return CGRect(x: left, y: y, width: size.width * 0.96 - left, height: bottom - y)
    }

    var body: some View {
        let current = nowPlaying.info ?? info
        let player = playerRect
        let words = lyricsRect
        ZStack(alignment: .topLeading) {
            Group {
                if settings.lockScreenBackground == .cover {
                    CoverBackdrop(image: image, playing: current.isPlaying, paused: mode == .motion, size: size)
                } else {
                    ReactiveBackdrop(palette: palette, playing: current.isPlaying, paused: mode == .motion, size: size)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: settings.lockScreenBackground)
            cover(coverRect)
            // Over a moving cover: darker at the top for the clock and at the
            // bottom for the player.
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: size.height * 0.38)
                .opacity(moving ? 1 : 0)
                .allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: size.height * 0.45)
                .offset(y: size.height * 0.55)
                .opacity(moving ? 1 : 0)
                .allowsHitTesting(false)
            if showLyrics {
                SpicyLyrics(lyrics: lyrics, info: current, fontSize: lineSize) { nowPlaying.seek(to: $0) }
                    .frame(width: words.width, height: words.height)
                    .position(x: words.midX, y: words.midY)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 48)),
                                            removal: .opacity.combined(with: .offset(x: 24))))
            }
            LockPlayerBlock(nowPlaying: nowPlaying, info: current, centered: !moving, lyricsOn: showLyrics,
                            lyricsAvailable: lyricsAvailable, controlsVisible: controlsVisible,
                            toggleLyrics: toggleLyrics)
                .frame(width: player.width, height: player.height, alignment: moving ? .bottomLeading : .top)
                .position(x: player.midX, y: player.midY)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .opacity(controlsVisible ? 0.55 : 0)
                .allowsHitTesting(controlsVisible)
                .position(x: 30, y: 30)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            // A video already buffered (back from the small player): large
            // straight away.
            moving = motion.ready
            videoVisible = false
            updatePalette()
            scheduleHide()
        }
        .onChange(of: image) { _, _ in updatePalette() }
        .onChange(of: motion.ready) { _, ready in
            if ready {
                // First the still cover grows from its card to the video's
                // size, then the video fades in over it.
                withAnimation(.spring(response: 0.85, dampingFraction: 0.9)) { moving = true }
                withAnimation(.easeInOut(duration: 0.6).delay(0.55)) { videoVisible = true }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { videoVisible = false }
                withAnimation(.spring(response: 0.8, dampingFraction: 0.9)) { moving = false }
            }
        }
        .onReceive(positionTick) { _ in if showLyrics { nowPlaying.syncPosition() } }
        .onReceive(mouseTick) { _ in
            let mouse = NSEvent.mouseLocation
            guard mouse != lastMouse else { return }
            lastMouse = mouse
            if !controlsVisible { withAnimation(.easeOut(duration: 0.25)) { controlsVisible = true } }
            scheduleHide()
        }
    }

    /// The cover – a card, or the moving cover large – one view throughout,
    /// so it glides between the layouts and the video never restarts.
    private func cover(_ rect: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: moving ? 0 : 16, style: .continuous)
        return ZStack {
            // A new song's cover fades in over the old one.
            ZStack {
                CoverArt(image: image, cornerRadius: 0)
                    .id(image.map(ObjectIdentifier.init))
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.7), value: image.map(ObjectIdentifier.init))
            // Buffering under the still cover, invisible until the cover has
            // grown to the large layout: never seen inside the card.
            if let video = motion.player {
                LoopingVideo(player: video) {
                    motion.markReady(video)
                    // Back from the small player: the layout is already
                    // large, the video only needs to come in.
                    if moving, !videoVisible { withAnimation(.easeInOut(duration: 0.5)) { videoVisible = true } }
                }
                .opacity(videoVisible ? 1 : 0)
            }
        }
        .matchedGeometryEffect(id: "cover", in: namespace)
        .frame(width: rect.width, height: rect.height)
        .clipShape(shape)
        .mask(SideFade(fade: mode == .motionLyrics ? 1 : 0))
        .shadow(color: .black.opacity(moving ? 0 : 0.4), radius: 30, y: 14)
        .contentShape(shape)
        .onTapGesture(perform: minimize)
        .help(L("Zurück zum kleinen Player", "Back to the small player"))
        .position(x: rect.midX, y: rect.midY)
    }

    private func updatePalette() {
        guard let image else { palette = []; return }
        let colors = ColorExtractor.palette(of: image).map { Color(nsColor: $0) }
        withAnimation(.easeInOut(duration: 1.2)) { palette = colors }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.6)) { controlsVisible = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// Lets the moving cover run out to the right into the lyrics' background;
/// animatable, so it fades in and out with the layout.
private struct SideFade: View, Animatable {
    var fade: Double
    var animatableData: Double {
        get { fade }
        set { fade = newValue }
    }

    var body: some View {
        LinearGradient(stops: [.init(color: .black, location: 0),
                               .init(color: .black, location: 1 - 0.45 * fade),
                               .init(color: .black.opacity(1 - fade), location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// The same player in every layout: progress, title and artist (centred
/// under a card; title first in the lower left over a moving cover), and
/// the buttons, which fade out while the pointer rests.
private struct LockPlayerBlock: View {
    @ObservedObject var nowPlaying: NowPlayingService
    let info: NowPlayingInfo
    let centered: Bool
    let lyricsOn: Bool
    /// False when the song has no synced lyrics: the button is greyed out.
    let lyricsAvailable: Bool
    let controlsVisible: Bool
    let toggleLyrics: () -> Void

    var body: some View {
        // Always the same three views in the same order – only their places
        // change – so the whole block glides as one between the layouts.
        PlayerStack(progressFirst: centered) {
            LockProgress(service: nowPlaying, info: info)
            titles
            controls
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }

    private var titles: some View {
        // A new song's title and artist fade over the old ones.
        ZStack {
            titleText
                .id(info.title + "|" + info.artist)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.5), value: info.title + "|" + info.artist)
    }

    private var titleText: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(info.title)
                .font(.system(size: centered ? 26 : 22, weight: .heavy))
                .lineLimit(1)
            Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                .font(.system(size: centered ? 17 : 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if nowPlaying.canLike {
                let pending = nowPlaying.likePending
                LockButton(symbol: nowPlaying.liked || pending ? "heart.fill" : "heart", size: 15) { nowPlaying.toggleLike() }
                    .foregroundStyle(nowPlaying.liked || pending ? Color(red: 0.98, green: 0.33, blue: 0.47) : .white)
                    .opacity(pending ? 0.6 : 1)
                    .symbolEffect(.bounce, value: nowPlaying.likePulse)
                    .help(nowPlaying.likeDeferred
                          ? L("Wird nach dem Entsperren an Spotify gesendet", "Sent to Spotify once you unlock")
                          : L("Lieblingssong", "Favourite"))
            }
            LockButton(symbol: "backward.fill", size: 17) { nowPlaying.send(.previous) }
            LockButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 24) {
                nowPlaying.send(.togglePlayPause)
            }
            LockButton(symbol: "forward.fill", size: 17) { nowPlaying.send(.next) }
            // Both symbols are always there and only fade.
            // Later, like LockButton: so this button moves with the others.
            Button(action: { DispatchQueue.main.async(execute: toggleLyrics) }) {
                ZStack {
                    Image(systemName: "quote.bubble").opacity(lyricsOn ? 0 : 1)
                    Image(systemName: "quote.bubble.fill").opacity(lyricsOn ? 1 : 0)
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .opacity(lyricsAvailable ? (lyricsOn ? 1 : 0.75) : 0.3)
            .disabled(!lyricsAvailable)
            .help(!lyricsAvailable ? L("Kein synchronisierter Songtext", "No synced lyrics")
                  : (lyricsOn ? L("Songtext ausblenden", "Hide lyrics") : L("Songtext", "Lyrics")))
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
    }
}

/// Progress, titles and buttons, top to bottom – or titles before progress
/// (over a moving cover); titles and buttons centred on the bar. One layout for both orders, so switching moves
/// the views instead of replacing them.
private struct PlayerStack: Layout {
    var progressFirst: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let frames = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in arrange(width: bounds.width, subviews: subviews).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    /// Frames of progress, titles and buttons (in that subview order).
    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 3 else { return subviews.map { _ in .zero } }
        let progress = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let titles = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let buttons = subviews[2].sizeThatFits(.unspecified)
        // Centred on the progress bar in both orders.
        func x(_ w: CGFloat) -> CGFloat { (width - w) / 2 }
        let first = progressFirst ? progress : titles
        let second = progressFirst ? titles : progress
        let secondY = first.height + (progressFirst ? 14 : 12)
        let buttonsY = secondY + second.height + 8
        let firstRect = CGRect(x: 0, y: 0, width: width, height: first.height)
        let secondRect = CGRect(x: 0, y: secondY, width: width, height: second.height)
        let progressRect = progressFirst ? firstRect : secondRect
        let titlesRect = progressFirst ? secondRect : firstRect
        return [progressRect,
                CGRect(x: x(min(titles.width, width)), y: titlesRect.minY, width: min(titles.width, width), height: titles.height),
                CGRect(x: x(buttons.width), y: buttonsY, width: buttons.width, height: buttons.height)]
    }
}

// MARK: - Background

/// Soft blobs in the cover's colours drifting slowly over a deeper base;
/// they swell a little on each beat while music plays (when the audio
/// level is available). Radial gradients, no blur, so it stays light.
private struct ReactiveBackdrop: View {
    let palette: [Color]
    let playing: Bool
    /// Hidden behind a full-screen moving cover: no need to animate.
    var paused = false
    let size: CGSize

    /// A new song's colours blend in from the old ones over a few seconds
    /// instead of switching at once (also when a sharper cover follows).
    @State private var from: [SIMD3<Double>] = []
    @State private var to: [SIMD3<Double>] = []
    @State private var changedAt = Date.distantPast
    private static let blend = 2.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let colors = mixed(at: context.date).map { Color(red: $0.x, green: $0.y, blue: $0.z) }
            let levels = AudioLevelMeter.shared.levels
            let live = playing && levels.hasSignal
            let beat = live ? Double(levels.beat) : 0
            ZStack {
                colors[0].brightness(-0.32)
                ForEach(0..<5, id: \.self) { i in
                    let color = colors[i % colors.count]
                    // Each blob listens a little to its own band too.
                    let band = live && levels.bands.count == 4 ? Double(levels.bands[i % 4]) : 0
                    let speed = playing ? 1.0 : 0.35
                    let x = 0.5 + 0.42 * sin(t * 0.045 * speed * Double(i + 1) + Double(i) * 1.9)
                    let y = 0.5 + 0.42 * cos(t * 0.037 * speed * Double(i + 2) + Double(i) * 2.7)
                    let radius = max(size.width, size.height) * (0.36 + 0.06 * sin(t * 0.09 + Double(i)))
                        * (1 + 0.16 * beat + 0.05 * band)
                    // A fuller core with a soft edge: the blobs stand out more.
                    RadialGradient(stops: [.init(color: color.opacity(0.95), location: 0),
                                           .init(color: color.opacity(0.7), location: 0.45),
                                           .init(color: color.opacity(0), location: 1)],
                                   center: UnitPoint(x: x, y: y), startRadius: 0, endRadius: radius)
                }
                // A faint brightening on each beat.
                Color.white.opacity(0.035 * beat).blendMode(.plusLighter)
                Color.black.opacity(0.12)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            AudioLevelMeter.shared.acquire()
            to = Self.rgb(palette)
            from = to
        }
        .onDisappear { AudioLevelMeter.shared.release() }
        .onChange(of: palette) { _, new in
            let now = Date()
            from = mixed(at: now)
            to = Self.rgb(new)
            changedAt = now
        }
        .allowsHitTesting(false)
    }

    /// The five blob colours at this moment of the blend.
    private func mixed(at date: Date) -> [SIMD3<Double>] {
        guard !to.isEmpty else { return Self.rgb([]) }
        let linear = min(max(date.timeIntervalSince(changedAt) / Self.blend, 0), 1)
        let f = linear * linear * (3 - 2 * linear)
        guard f < 1, from.count == to.count else { return to }
        return zip(from, to).map { $0 + ($1 - $0) * f }
    }

    /// Always five colours (the palette repeated), so blob i blends into
    /// blob i.
    private static func rgb(_ palette: [Color]) -> [SIMD3<Double>] {
        let colors = palette.isEmpty ? [Color(white: 0.25), Color(white: 0.15)] : palette
        return (0..<5).map { i in
            let c = NSColor(colors[i % colors.count]).usingColorSpace(.sRGB) ?? .gray
            return SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
    }
}

/// Like Spicetify's: the cover itself, hugely blurred, as soft bubbles
/// that slowly drift and turn over a large turning copy – calm, not to the
/// beat. The blur is done once per cover on a small copy (cheap). A new
/// cover fades in over the old one, which stays fully visible underneath,
/// so nothing turns dark in between.
private struct CoverBackdrop: View {
    let image: NSImage?
    let playing: Bool
    var paused = false
    let size: CGSize

    /// Shown fully underneath.
    @State private var base: CGImage?
    /// Fading in over `base` after a song change.
    @State private var top: CGImage?
    @State private var topShown = false
    @State private var change = 0

    var body: some View {
        ZStack {
            Color.black
            if let base {
                CoverLayers(image: base, playing: playing, paused: paused, size: size)
            }
            if let top {
                CoverLayers(image: top, playing: playing, paused: paused, size: size)
                    .opacity(topShown ? 1 : 0)
                    .scaleEffect(topShown ? 1 : 1.1)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onAppear { base = image.flatMap(Self.blurred) }
        .onChange(of: image) { old, new in
            let next = new.flatMap(Self.blurred)
            // The same cover in a sharper copy: no new blend.
            if let old, let new, HiResArtwork.looksAlike(old, new) {
                if top != nil { top = next } else { base = next }
                return
            }
            // What shows now becomes the base, the new cover grows in.
            if let top, topShown { base = top }
            top = next
            topShown = false
            change += 1
            let mine = change
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 3.5)) { topShown = true }
            }
            // Once it is fully in, it becomes the base.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) {
                guard mine == change else { return }
                base = top
                top = nil
                topShown = false
            }
        }
        .allowsHitTesting(false)
    }

    /// The cover at 160 px with a wide Gaussian blur: stretched over the
    /// screen it stays smooth.
    static func blurred(_ image: NSImage) -> CGImage? {
        let side = 160
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = context.makeImage() else { return nil }
        let input = CIImage(cgImage: small)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return small }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(14, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return small }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent) ?? small
    }
}

/// One large turning copy fills the screen; on it four bubbles of the
/// cover drift on slow loops, each turning its own way.
private struct CoverLayers: View {
    let image: CGImage
    let playing: Bool
    let paused: Bool
    let size: CGSize

    /// Size (× the screen's longer side), loop speed, turn speed, phase.
    private static let bubbles: [(size: Double, speed: Double, turn: Double, phase: Double)] = [
        (0.95, 0.031, 3.5, 0.0), (0.8, 0.024, -4.2, 2.1), (0.7, 0.037, 5.0, 4.0), (0.6, 0.028, -3.0, 5.3),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * (playing ? 1 : 0.4)
            let side = max(size.width, size.height)
            ZStack {
                layer(side * 1.9, angle: t * 2.4, x: 0.5, y: 0.5)
                ForEach(0..<Self.bubbles.count, id: \.self) { i in
                    let bubble = Self.bubbles[i]
                    let x = 0.5 + 0.38 * sin(t * bubble.speed + bubble.phase)
                    let y = 0.5 + 0.36 * cos(t * bubble.speed * 1.3 + bubble.phase * 1.7)
                    layer(side * bubble.size, angle: t * bubble.turn + bubble.phase * 60, x: x, y: y)
                        .opacity(0.85)
                }
                // Dark enough for white text.
                Color.black.opacity(0.3)
            }
            .saturation(1.25)
        }
    }

    private func layer(_ side: CGFloat, angle: Double, x: Double, y: Double) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            // A soft round edge: each copy is a bubble without corners.
            .mask(RadialGradient(colors: [.black, .black, .clear], center: .center,
                                 startRadius: 0, endRadius: side * 0.5))
            .rotationEffect(.degrees(angle))
            .position(x: size.width * x, y: size.height * y)
    }
}

// MARK: - Lyrics

private struct SpicyLyrics: View {
    @ObservedObject var lyrics: LyricsService
    let info: NowPlayingInfo
    let fontSize: CGFloat
    let onSeek: (Double) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            switch lyrics.state {
            case .loaded:
                // Which line is current changes a few times a second at most;
                // the letters of that line animate on their own (SpicyActiveLine).
                TimelineView(.periodic(from: .now, by: info.isPlaying ? 0.1 : 3600)) { context in
                    let position = info.elapsed(at: context.date) + settings.lyricsOffset
                    SpicyScroller(lyrics: lyrics, current: lyrics.index(at: position), info: info,
                                  fontSize: fontSize, onSeek: onSeek)
                }
            case .loading:
                status(L("Songtext wird geladen …", "Loading lyrics …"))
            case .unavailable, .idle:
                status(L("Kein synchronisierter Songtext", "No synced lyrics"))
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct SpicyScroller: View {
    @ObservedObject var lyrics: LyricsService
    let current: Int?
    let info: NowPlayingInfo
    let fontSize: CGFloat
    let onSeek: (Double) -> Void
    @State private var hovered: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: fontSize * 0.3) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        row(index, line)
                            .id(index)
                    }
                }
                .padding(.vertical, fontSize * 8)
            }
            .scrollDisabled(true)
            // Soft edges, wider at the top where the clock is.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                         .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear { proxy.scrollTo(current ?? 0, anchor: UnitPoint(x: 0, y: 0.42)) }
            .onChange(of: current) { _, index in
                withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                    proxy.scrollTo(index ?? 0, anchor: UnitPoint(x: 0, y: 0.42))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ line: LyricsService.Line) -> some View {
        let isCurrent = index == current
        let distance = current.map { abs(index - $0) } ?? 3
        let isHovered = hovered == index && !isCurrent
        let isPast = current.map { index < $0 } ?? false
        Group {
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                InterludeDots(size: fontSize, active: isCurrent && info.isPlaying)
            } else if isCurrent {
                SpicyActiveLine(lyrics: lyrics, index: index, info: info, fontSize: fontSize)
            } else {
                SpicyStillLine(line: line, fontSize: fontSize, opacity: isHovered ? 0.85 : (isPast ? 0.38 : 0.45))
            }
        }
        .blur(radius: isCurrent || isHovered ? 0 : min(3, Double(max(distance - 1, 0)) * 0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, fontSize * 0.35)
        .padding(.vertical, fontSize * 0.15)
        // Hovering a line lays a light pane under it.
        .background(RoundedRectangle(cornerRadius: fontSize * 0.35, style: .continuous)
            .fill(Color.white.opacity(isHovered ? 0.1 : 0)))
        .padding(.horizontal, -fontSize * 0.35)
        .contentShape(Rectangle())
        // Click a line to jump there.
        .onTapGesture { onSeek(line.time) }
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        // Quick, so the line is bright as its first word is sung.
        .animation(.easeOut(duration: 0.2), value: isCurrent)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// The words of a line, split into the sung part and the background vocals
/// in brackets, each with its place among all the line's characters.
private struct LyricWords {
    struct Word: Identifiable {
        let id: Int
        let text: String
        /// Characters before this word in the whole line (spaces count).
        let offset: Double
        let length: Double
    }

    var main: [Word] = []
    var background: [Word] = []

    init(_ line: LyricsService.Line) {
        var offset = 0.0
        var inBrackets = false
        for (index, raw) in line.words.enumerated() {
            if raw.hasPrefix("(") { inBrackets = true }
            let shown = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let word = Word(id: index, text: shown, offset: offset, length: Double(raw.count))
            if !shown.isEmpty {
                if inBrackets { background.append(word) } else { main.append(word) }
            }
            if raw.hasSuffix(")") { inBrackets = false }
            offset += Double(raw.count + 1)
        }
    }

    /// How far a word is lit (whole lines light up at once).
    func fill(_ word: Word, sung: Double) -> Double {
        guard word.length > 0 else { return 0 }
        return min(max((sung - word.offset) / word.length, 0), 1)
    }
}

/// The line being sung: every word fills with white letter by letter, the
/// word being sung glows and rises a little.
private struct SpicyActiveLine: View {
    @ObservedObject var lyrics: LyricsService
    let index: Int
    let info: NowPlayingInfo
    let fontSize: CGFloat

    var body: some View {
        // On a song change the old index can outlive the old lines for one
        // update: then there is nothing to draw (reading it crashed).
        let words = LyricWords(lyrics.lines.indices.contains(index) ? lyrics.lines[index]
                               : LyricsService.Line(time: 0, text: ""))
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !info.isPlaying)) { context in
            let position = info.elapsed(at: context.date) + AppSettings.shared.lyricsOffset
            let sung = lyrics.lines.indices.contains(index) ? lyrics.sungCharacters(in: index, at: position) : 0
            VStack(alignment: .leading, spacing: fontSize * 0.1) {
                WordFlow(spacing: fontSize * 0.27, lineSpacing: fontSize * 0.06) {
                    ForEach(words.main) { word in
                        SpicyWord(text: word.text, fill: words.fill(word, sung: sung), size: fontSize)
                    }
                }
                if !words.background.isEmpty {
                    WordFlow(spacing: fontSize * 0.2, lineSpacing: 0) {
                        ForEach(words.background) { word in
                            SpicyWord(text: word.text, fill: words.fill(word, sung: sung), size: fontSize * 0.55)
                        }
                    }
                }
            }
        }
    }
}

/// One word: dim underneath, bright on top up to how far it is sung, with a
/// soft edge; glowing while it is being sung.
private struct SpicyWord: View {
    let text: String
    /// 0 = not yet, 1 = sung.
    let fill: Double
    let size: CGFloat

    var body: some View {
        let label = Text(text).font(.system(size: size, weight: .bold))
        // Strongest in the middle of the word, gone once it is sung.
        let glow = fill > 0 && fill < 1 ? sin(fill * .pi) : 0
        let soft = 0.25
        label
            .foregroundStyle(.white.opacity(0.3))
            .overlay(alignment: .leading) {
                label
                    .foregroundStyle(.white)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: min(max(fill * (1 + soft) - soft, 0), 1)),
                                                 .init(color: .clear, location: min(max(fill * (1 + soft), 0.0001), 1))],
                                         startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .white.opacity(0.75 * glow), radius: size * 0.28)
            }
            .offset(y: -size * 0.045 * min(fill * 1.6, 1))
    }
}

/// A line that isn't being sung: plain, dim, background vocals small below.
private struct SpicyStillLine: View {
    let line: LyricsService.Line
    let fontSize: CGFloat
    let opacity: Double

    var body: some View {
        let words = LyricWords(line)
        VStack(alignment: .leading, spacing: fontSize * 0.1) {
            if !words.main.isEmpty {
                Text(words.main.map(\.text).joined(separator: " "))
                    .font(.system(size: fontSize, weight: .bold))
            }
            if !words.background.isEmpty {
                Text(words.background.map(\.text).joined(separator: " "))
                    .font(.system(size: fontSize * 0.55, weight: .bold))
            }
        }
        .foregroundStyle(.white.opacity(opacity))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Three dots breathing one after another during an instrumental part.
private struct InterludeDots: View {
    let size: CGFloat
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.22) {
                ForEach(0..<3, id: \.self) { dot in
                    let wave = active ? (sin(t * 3 - Double(dot) * 0.8) + 1) / 2 : 0
                    Circle()
                        .fill(Color.white.opacity(active ? 0.7 + 0.3 * wave : 0.45))
                        .frame(width: size * 0.42, height: size * 0.42)
                        .scaleEffect(active ? 0.85 + 0.2 * wave : 0.85)
                        .shadow(color: .white.opacity(active ? 0.6 * wave : 0), radius: size * 0.25)
                }
            }
            .frame(height: size)
        }
    }
}

/// Lays words out left to right and wraps them like text.
private struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height)), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
