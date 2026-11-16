import AppKit
import Combine
import SwiftUI

/// A Bluetooth device that connected or disconnected, with its battery.
struct DeviceCard: Equatable {
    var name: String
    var symbol: String
    var connected: Bool
    /// Percentages, nil when the device does not report them.
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// Devices with one battery (headphones, keyboards …).
    var single: Int?
}

/// Like Pro Notch: when headphones connect, the island opens downwards into
/// a card – the device large on the left with a soft glow, its name and
/// "Connected", and a battery ring for each bud and the case.
final class DeviceCardModule: NotchModule {
    let id = "devices"
    var title: String { L("Geräte verbinden", "Device connections") }
    let symbol = "airpodspro"
    let priority = ModulePriority.notification + 1
    let compactWingWidth: CGFloat = 112

    @Published private(set) var card: DeviceCard?
    private var hideWork: DispatchWorkItem?

    var isActive: Bool { card != nil }
    var isPeeking: Bool { card != nil }
    var peekHeight: CGFloat { card?.connected == true ? 116 : 60 }

    /// Shows the card, or updates it in place (battery arriving later).
    func show(_ card: DeviceCard) {
        guard AppSettings.shared.isEnabled("connectivity") else { return }
        let same = self.card?.name == card.name && self.card?.connected == card.connected
        self.card = card
        if same, hideWork != nil { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.card = nil
            self?.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (card.connected ? 4.5 : 2.5), execute: work)
    }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func peekView() -> AnyView { AnyView(DeviceCardView(module: self)) }
    func transientView() -> AnyView { AnyView(DeviceCardView(module: self, inline: true)) }
}

private struct DeviceCardView: View {
    @ObservedObject var module: DeviceCardModule
    /// Inside the open island: covers the page instead of reaching up
    /// beside the notch.
    var inline = false

    var body: some View {
        if let card = module.card {
            HStack(alignment: .center, spacing: 26) {
                DeviceImage(card: card)
                    .frame(width: card.connected ? (inline ? 104 : 118) : 70,
                           height: card.connected ? (inline ? 104 : 118) : 60)
                    // Reaches up beside the notch, like Pro Notch's picture.
                    .offset(y: inline ? 0 : (card.connected ? -16 : -8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(card.connected ? L("Verbunden", "Connected") : L("Getrennt", "Disconnected"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    if card.connected {
                        HStack(spacing: 14) {
                            if let left = card.left { BatteryRing(label: "L", percent: left) }
                            if let right = card.right { BatteryRing(label: "R", percent: right) }
                            if let box = card.caseLevel { BatteryRing(symbol: "rectangle.portrait.fill", percent: box) }
                            if card.left == nil, card.right == nil, let single = card.single {
                                BatteryRing(symbol: "battery.100", percent: single)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: card)
        }
    }
}

/// The device large and light grey with depth, on a soft violet glow.
private struct DeviceImage: View {
    let card: DeviceCard

    /// The charging case for AirPods (like the photo), else the device.
    private var symbol: String {
        let candidates: [String]
        let name = card.name.lowercased()
        if name.contains("airpods pro") {
            candidates = ["airpods.pro.chargingcase.wireless.fill", "airpodspro.chargingcase.wireless.fill", card.symbol]
        } else if name.contains("airpods max") {
            candidates = ["airpods.max", "airpodsmax", card.symbol]
        } else if name.contains("airpods") {
            candidates = ["airpods.chargingcase.wireless.fill", "airpods.chargingcase.fill", card.symbol]
        } else {
            candidates = [card.symbol]
        }
        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "headphones"
    }

    /// A photo-real product picture: one added to the asset catalogue
    /// (AirPodsPro, AirPodsMax, AirPods, Headphones), else the 3D render
    /// macOS itself ships for the device (as in System Settings).
    private var photo: NSImage? { DevicePhotos.image(for: card.name) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.5, green: 0.36, blue: 1).opacity(card.connected ? 0.38 : 0.12))
                .blur(radius: 26)
                .scaleEffect(0.85)
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .shadow(color: Color(red: 0.55, green: 0.4, blue: 1).opacity(0.45), radius: 14)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 6)
                    .padding(4)
                    .opacity(card.connected ? 1 : 0.55)
            } else {
                symbolView
            }
        }
    }

    private var symbolView: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.72)],
                                            startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.5), radius: 8, y: 5)
            .padding(10)
            .opacity(card.connected ? 1 : 0.55)
    }
}

/// A ring that fills with the battery level, a letter or symbol inside and
/// the percentage below.
private struct BatteryRing: View {
    var label: String?
    var symbol: String?
    let percent: Int

    init(label: String, percent: Int) {
        self.label = label
        self.percent = percent
    }

    init(symbol: String, percent: Int) {
        self.symbol = symbol
        self.percent = percent
    }

    private var color: Color {
        percent <= 20 ? .red : (percent <= 40 ? .orange : Color(red: 0.45, green: 0.8, blue: 0.45))
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let label {
                    Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 34, height: 34)
            Text("\(percent)%")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// Finds a 3D product picture for a Bluetooth device. Nothing is bundled
/// from Apple: the pictures come from the Mac's own CoreTypes bundle (the
/// renders System Settings and Finder use), unless the asset catalogue has
/// one of its own.
enum DevicePhotos {
    private enum Kind { case pro, max, regular, beats, other }
    private static var cache: [String: NSImage?] = [:]
    private static let coreTypes = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"

    static func image(for deviceName: String) -> NSImage? {
        let kind = kind(of: deviceName)
        let key = "\(kind)"
        if let cached = cache[key] { return cached }
        let found = assetImage(kind) ?? systemImage(kind)
        cache[key] = found
        return found
    }

    private static func kind(of name: String) -> Kind {
        let name = name.lowercased()
        if name.contains("airpods pro") { return .pro }
        if name.contains("airpods max") { return .max }
        if name.contains("airpods") { return .regular }
        if name.contains("beats") || name.contains("powerbeats") { return .beats }
        return .other
    }

    private static func assetImage(_ kind: Kind) -> NSImage? {
        let names: [String]
        switch kind {
        case .pro: names = ["AirPodsPro", "AirPods"]
        case .max: names = ["AirPodsMax"]
        case .regular: names = ["AirPods", "AirPodsPro"]
        case .beats: names = ["Headphones"]
        case .other: names = []
        }
        return names.lazy.compactMap { NSImage(named: $0) }.first
    }

    /// The device's type identifier first, then any CoreTypes file whose
    /// name fits (Apple renames them between macOS versions).
    private static func systemImage(_ kind: Kind) -> NSImage? {
        let identifiers: [String]
        let words: [String]
        let avoid: [String]
        switch kind {
        case .pro:
            identifiers = ["com.apple.airpods-pro-2-usbc", "com.apple.airpods-pro-2", "com.apple.airpods-pro"]
            words = ["airpods", "pro"]
            avoid = ["max"]
        case .max:
            identifiers = ["com.apple.airpods-max"]
            words = ["airpods", "max"]
            avoid = []
        case .regular:
            identifiers = ["com.apple.airpods-4", "com.apple.airpods-3", "com.apple.airpods-2", "com.apple.airpods"]
            words = ["airpods"]
            avoid = ["pro", "max"]
        case .beats, .other:
            return nil
        }
        for identifier in identifiers {
            if let file = try? FileManager.default.contentsOfDirectory(atPath: coreTypes)
                .first(where: { $0 == identifier + ".icns" }),
               let image = NSImage(contentsOfFile: coreTypes + "/" + file) {
                return image
            }
        }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: coreTypes) else { return nil }
        let matches = files.filter { file in
            let lower = file.lowercased()
            return lower.hasSuffix(".icns") && words.allSatisfy { lower.contains($0) }
                && !avoid.contains { lower.contains($0) }
        }
        // Prefer the case (like Pro Notch's picture), then the shortest name.
        let sorted = matches.sorted { a, b in
            let ca = a.lowercased().contains("case"), cb = b.lowercased().contains("case")
            return ca != cb ? ca : a.count < b.count
        }
        return sorted.lazy.compactMap { NSImage(contentsOfFile: coreTypes + "/" + $0) }.first
    }
}
